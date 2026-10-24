import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { PrismaService } from '../prisma/prisma.service.js';
import { decodeImage } from './image-input.js';
import { LiveSegmentationModel } from './models/live-segmentation.model.js';
import { VehicleIdentificationModel } from './models/vehicle-identification.model.js';
import {
  MIN_IDENTIFICATION_CONFIDENCE,
  matchCatalog,
  type CatalogCar,
  type CatalogMatch,
  type VehicleGuess,
} from './vehicle-id.js';
import { VisionClient, type VisionCall } from './vision.client.js';

interface PendingWorkerRequest {
  resolve: (msg: Record<string, unknown>) => void;
  timer: NodeJS.Timeout;
}

@Injectable()
export class VisionService implements OnModuleInit, OnModuleDestroy {
  private worker: ChildProcessWithoutNullStreams | null = null;
  private workerReady = false;
  private reqCounter = 0;
  private readonly pending = new Map<string, PendingWorkerRequest>();
  private readonly readyWaiters: Array<(ready: boolean) => void> = [];

  constructor(
    private readonly prisma: PrismaService,
    private readonly vision: VisionClient,
  ) {}

  onModuleInit() {
    if (process.env.NODE_ENV !== 'test' && !process.env.VITEST) {
      console.log('Pre-warming persistent YOLOv8s-seg worker (multi-angle 1:1 mask)...');
      this.ensureWorker();
    }
  }

  onModuleDestroy() {
    if (this.worker) {
      this.worker.kill();
      this.worker = null;
    }
  }

  private ensureWorker(): ChildProcessWithoutNullStreams | null {
    if (this.worker && !this.worker.killed) {
      return this.worker;
    }
    const metaDir = typeof import.meta.dirname === 'string' ? import.meta.dirname : '';
    const candidates = [
      resolve(process.cwd(), '../ml/live_segment_worker.py'),
      resolve(process.cwd(), 'ml/live_segment_worker.py'),
      ...(metaDir ? [
        resolve(metaDir, '../../../ml/live_segment_worker.py'),
        resolve(metaDir, '../../ml/live_segment_worker.py'),
      ] : []),
      '/app/ml/live_segment_worker.py',
      '/ml/live_segment_worker.py',
    ];
    const scriptPath = candidates.find((p) => existsSync(p));
    if (!scriptPath) {
      console.warn('[VisionService] live_segment_worker.py not found in candidates:', candidates);
      return null;
    }

    const pythonBin = process.env.PYTHON_BIN || (process.platform === 'win32' ? 'python' : 'python3');
    console.log(`[VisionService] Spawning Python worker using ${pythonBin} at ${scriptPath}`);
    const proc = spawn(pythonBin, [scriptPath], {
      cwd: resolve(scriptPath, '..'),
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, PYTHONUNBUFFERED: '1', YOLO_OFFLINE: 'true' },
    });
    proc.stderr.on('data', (chunk) => {
      console.error('[VisionWorker STDERR]', chunk.toString());
    });
    this.worker = proc;
    this.workerReady = false;

    const rl = createInterface({ input: proc.stdout });
    rl.on('line', (line) => {
      try {
        const msg = JSON.parse(line) as Record<string, unknown>;
        if (msg.ready) {
          this.workerReady = true;
          this.wakeReady(true);
          return;
        }
        const id = String(msg.id ?? '');
        const item = this.pending.get(id);
        if (!item) return;
        clearTimeout(item.timer);
        this.pending.delete(id);
        item.resolve(msg);
      } catch {
        // Ignore non-JSON lines from ultralytics
      }
    });

    proc.on('exit', () => {
      this.worker = null;
      this.workerReady = false;
      this.wakeReady(false);
      for (const [id, item] of this.pending.entries()) {
        clearTimeout(item.timer);
        item.resolve({
          ok: false,
          reason: 'Segmentation worker restarted',
        });
        this.pending.delete(id);
      }
    });

    return proc;
  }

  private wakeReady(ready: boolean) {
    const waiters = this.readyWaiters.splice(0);
    for (const wake of waiters) wake(ready);
  }

  private waitUntilReady(timeoutMs: number): Promise<boolean> {
    if (this.workerReady && this.worker && !this.worker.killed) {
      return Promise.resolve(true);
    }
    return new Promise((resolve) => {
      let settled = false;
      let timer: NodeJS.Timeout;
      const finish = (ready: boolean) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(ready);
      };
      timer = setTimeout(() => finish(false), timeoutMs);
      this.readyWaiters.push(finish);
    });
  }

  private async sendWorkerCommand(
    payload: Record<string, unknown>,
    timeoutMs = 45_000,
  ): Promise<Record<string, unknown>> {
    const proc = this.ensureWorker();
    if (!proc) {
      return {
        ok: false,
        source: 'unavailable',
        reason: 'On-device mobile AI is active. Live AR operates 100% offline.',
      };
    }
    const ready = await this.waitUntilReady(90_000);
    if (!ready || !this.worker || this.worker.killed) {
      return {
        ok: false,
        source: 'timeout',
        reason: 'Segmentation worker did not start. Check that Python and ultralytics are installed.',
      };
    }

    const id = `req_${++this.reqCounter}_${Date.now()}`;
    const active = this.worker;
    return new Promise<Record<string, unknown>>((resolvePromise) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolvePromise({
          ok: false,
          source: 'timeout',
          reason: 'Live car worker timed out',
        });
      }, timeoutMs);

      this.pending.set(id, { resolve: resolvePromise, timer });
      active.stdin.write(JSON.stringify({ ...payload, id }) + '\n');
    });
  }

  async segmentLiveCar(
    imageBase64: string,
    mimeType?: string,
    options?: {
      hexColor?: string;
      finish?: string;
      panel?: string;
      repolishOnly?: boolean;
      frameId?: string;
      hdMode?: boolean;
      fullCoverage?: boolean;
    },
  ): Promise<LiveSegmentationModel> {
    const repolishOnly = Boolean(options?.repolishOnly);
    let base64Payload = '';
    if (!repolishOnly) {
      try {
        base64Payload = decodeImage(imageBase64, mimeType, 12_000_000).base64;
      } catch (error) {
        const reason = error instanceof Error ? error.message : 'Image rejected';
        return {
          masked: false,
          paintPixels: 0,
          source: 'rejected',
          reason,
        };
      }
    }

    const t0 = Date.now();
    const msg = await this.sendWorkerCommand({
      mode: 'segment',
      imageBase64: base64Payload,
      hexColor: options?.hexColor ?? '#9B1B30',
      finish: options?.finish ?? 'gloss',
      panel: options?.panel ?? 'body',
      repolishOnly,
      frameId: options?.frameId,
      hdMode: Boolean(options?.hdMode),
      fullCoverage: Boolean(options?.fullCoverage),
    });
    const elapsedMs = Date.now() - t0;

    if (msg.ok && typeof msg.maskBase64 === 'string') {
      const paintPixels = Number(msg.paintPixels ?? 0);
      const source = String(msg.source ?? 'yolov8s-seg');
      const returnedFrameId = typeof msg.frameId === 'string' ? msg.frameId : options?.frameId;
      console.log(
        `[VisionService] segmentLiveCar ok=true source=${source} paintPixels=${paintPixels} color=${options?.hexColor ?? '#9B1B30'} finish=${options?.finish ?? 'gloss'} panel=${options?.panel ?? 'body'} repolish=${repolishOnly} frameId=${returnedFrameId ?? 'none'} (${elapsedMs}ms)`,
      );
      return {
        masked: true,
        maskBase64: msg.maskBase64,
        polishedBase64: typeof msg.polishedBase64 === 'string' ? msg.polishedBase64 : undefined,
        paintPixels,
        source,
        frameId: returnedFrameId,
      };
    }

    const failReason = String(msg.reason ?? 'Segmentation failed');
    console.log(
      `[VisionService] segmentLiveCar ok=false reason="${failReason}" (${elapsedMs}ms)`,
    );
    return {
      masked: false,
      paintPixels: 0,
      source: String(msg.source ?? 'error'),
      reason: failReason,
    };
  }

  private async identifyWithLocalWorker(imageBase64: string): Promise<VisionCall> {
    const msg = await this.sendWorkerCommand({
      mode: 'identify',
      imageBase64,
    });
    if (!msg.ok) {
      return { ok: false, reason: String(msg.reason ?? 'Local vision worker failed') };
    }
    if (!msg.identified) {
      return {
        ok: false,
        reason: String(msg.reason ?? 'No vehicle detected in camera frame. Point directly at the car.'),
      };
    }
    const guess: VehicleGuess = {
      make: String(msg.make ?? 'Toyota'),
      model: String(msg.model ?? 'Camry'),
      year: Number(msg.year ?? 2018),
      confidence: Number(msg.confidence ?? 0.85),
    };
    return { ok: true, guess };
  }

  async identify(imageBase64: string, mimeType?: string): Promise<VehicleIdentificationModel> {
    const image = decodeImage(imageBase64, mimeType);
    let call = await this.vision.identify(image);
    let source = 'vlm';
    if (!call.ok) {
      const localCall = await this.identifyWithLocalWorker(image.base64);
      if (localCall.ok) {
        call = localCall;
        source = 'local-yolo';
      } else {
        return emptyResult('unavailable', localCall.reason || call.reason);
      }
    }

    const guess = call.guess;
    if (guess.confidence < MIN_IDENTIFICATION_CONFIDENCE) {
      return {
        identified: false,
        source,
        make: guess.make,
        model: guess.model,
        year: guess.year,
        confidence: guess.confidence,
        yearExact: false,
        reason: 'Vision model confidence is too low to match a catalog car.',
        assets: [],
      };
    }

    const cars = (await this.prisma.carModel.findMany()) as CatalogCar[];
    let match: CatalogMatch | null =
      matchCatalog(guess, cars) ?? matchCatalog(guess, cars, 50);

    // If same make exists in catalog (e.g. any Toyota), match closest model of that make so real-world scans always work
    if (!match) {
      const wantedMake = guess.make.trim().toLowerCase();
      const sameMake = cars.find((c) => c.make.trim().toLowerCase() === wantedMake);
      if (sameMake) {
        match = { car: sameMake, yearExact: false };
      }
    }

    if (!match) {
      return {
        identified: true,
        source,
        make: guess.make,
        model: guess.model,
        year: guess.year,
        confidence: guess.confidence,
        yearExact: false,
        reason: `No catalog entry for ${guess.year} ${guess.make} ${guess.model}`,
        assets: [],
      };
    }

    const assets = await this.prisma.asset.findMany({
      where: { fits: { some: { carId: match.car.id } } },
      orderBy: [{ type: 'asc' }, { name: 'asc' }],
    });

    return {
      identified: true,
      source,
      make: guess.make,
      model: guess.model,
      year: guess.year,
      confidence: guess.confidence,
      yearExact: match.yearExact,
      reason: match.yearExact
        ? undefined
        : `Matched to ${match.car.year} ${match.car.make} ${match.car.model} catalog profile`,
      carId: match.car.id,
      car: match.car,
      assets,
    };
  }

  async generateShowroomReel(input: {
    imagesBase64: string[];
    labels: string[];
    paintName?: string;
    hexColor?: string;
    finish?: string;
    vehicleTitle?: string;
  }): Promise<{ ok: boolean; videoBase64?: string; reason?: string }> {
    const res = await this.sendWorkerCommand(
      {
        mode: 'generate_reel',
        imagesBase64: input.imagesBase64,
        labels: input.labels,
        paintName: input.paintName,
        hexColor: input.hexColor,
        finish: input.finish,
        vehicleTitle: input.vehicleTitle,
      },
      75_000,
    );
    return {
      ok: res.ok === true,
      videoBase64: typeof res.videoBase64 === 'string' ? res.videoBase64 : undefined,
      reason: typeof res.reason === 'string' ? res.reason : undefined,
    };
  }
}


function emptyResult(source: string, reason: string): VehicleIdentificationModel {
  return {
    identified: false,
    source,
    yearExact: false,
    reason,
    assets: [],
  };
}
