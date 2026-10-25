
import { Injectable, Logger } from '@nestjs/common';
import * as fs from 'fs';
import * as path from 'path';

@Injectable()
export class SelfLearningService {
  private readonly logger = new Logger(SelfLearningService.name);
  private readonly root = path.join(process.cwd(), 'public', 'self_learning');

  constructor() {
    if (!fs.existsSync(this.root)) fs.mkdirSync(this.root, { recursive: true });
  }

  async uploadSample(make: string, imageBase64: string, maskBase64: string, metadata: any) {
    const makeDir = path.join(this.root, make.toLowerCase());
    if (!fs.existsSync(makeDir)) fs.mkdirSync(makeDir, { recursive: true });

    const timestamp = Date.now();
    const imgPath = path.join(makeDir, `${timestamp}.png`);
    const maskPath = path.join(makeDir, `${timestamp}_mask.png`);
    const metaPath = path.join(makeDir, `${timestamp}.json`);

    // Save image from base64
    if (imageBase64) {
      const imgData = imageBase64.replace(/^data:image\/\w+;base64,/, '');
      fs.writeFileSync(imgPath, Buffer.from(imgData, 'base64'));
    }
    if (maskBase64) {
      const maskData = maskBase64.replace(/^data:image\/\w+;base64,/, '');
      fs.writeFileSync(maskPath, Buffer.from(maskData, 'base64'));
    }
    fs.writeFileSync(metaPath, JSON.stringify({ ...metadata, timestamp, make }, null, 2));

    const count = fs.readdirSync(makeDir).filter(f => f.endsWith('.png') && !f.includes('_mask')).length;
    
    this.logger.log(`Self-learning sample: ${make} -> ${count} samples total`);

    // Trigger retrain if enough samples
    let retrainTriggered = false;
    if (count >= 20 && count % 20 === 0) {
      this.logger.log(`Triggering continual learning retrain for ${make} with ${count} samples`);
      retrainTriggered = true;
      // In production: queue job to ml_train_universal_selflearning.py
    }

    return { make, count, retrainTriggered, message: count >= 20 ? `Enough data for ${make} retrain` : `Collecting ${make} samples` };
  }

  async getStats() {
    const stats: any = { totalSamples: 0, makes: {} };
    if (!fs.existsSync(this.root)) return stats;

    for (const makeDir of fs.readdirSync(this.root)) {
      const fullPath = path.join(this.root, makeDir);
      if (fs.statSync(fullPath).isDirectory()) {
        const files = fs.readdirSync(fullPath).filter(f => f.endsWith('.png') && !f.includes('_mask'));
        stats.makes[makeDir] = {
          sampleCount: files.length,
          readyForRetrain: files.length >= 20,
          avgConfidence: 0.7, // TODO: compute from metadata
        };
        stats.totalSamples += files.length;
      }
    }
    return stats;
  }

  async getMakeDataset(make: string) {
    const makeDir = path.join(this.root, make.toLowerCase());
    if (!fs.existsSync(makeDir)) return { make, samples: [] };
    const files = fs.readdirSync(makeDir).filter(f => f.endsWith('.json'));
    return {
      make,
      sampleCount: files.length,
      samples: files.slice(-10).map(f => {
        try { return JSON.parse(fs.readFileSync(path.join(makeDir, f), 'utf8')); } catch { return null; }
      }).filter(Boolean)
    };
  }

  // Called after ml training pushes new model
  async pushNewModel(modelUrl: string, version: string) {
    const modelRegistryPath = path.join(this.root, 'model_registry.json');
    let registry: any[] = [];
    if (fs.existsSync(modelRegistryPath)) {
      registry = JSON.parse(fs.readFileSync(modelRegistryPath, 'utf8'));
    }
    registry.push({ modelUrl, version, pushedAt: new Date().toISOString() });
    fs.writeFileSync(modelRegistryPath, JSON.stringify(registry, null, 2));

    this.logger.log(`New universal model pushed: ${modelUrl} v${version}`);
    return { modelUrl, version, message: 'Model pushed, Unity clients will hot-swap on next launch' };
  }
}
