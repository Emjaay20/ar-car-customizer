import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service.js';
import { decodeImage } from './image-input.js';
import { VehicleIdentificationModel } from './models/vehicle-identification.model.js';
import {
  MIN_IDENTIFICATION_CONFIDENCE,
  matchCatalog,
  type CatalogCar,
} from './vehicle-id.js';
import { VisionClient } from './vision.client.js';

@Injectable()
export class VisionService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly vision: VisionClient,
  ) {}

  async identify(imageBase64: string, mimeType?: string): Promise<VehicleIdentificationModel> {
    const image = decodeImage(imageBase64, mimeType);
    const call = await this.vision.identify(image);
    if (!call.ok) {
      return emptyResult('unavailable', call.reason);
    }

    const guess = call.guess;
    if (guess.confidence < MIN_IDENTIFICATION_CONFIDENCE) {
      return {
        identified: false,
        source: 'vlm',
        make: guess.make,
        model: guess.model,
        year: guess.year,
        confidence: guess.confidence,
        yearExact: false,
        reason: 'Vision model confidence is too low to match a catalog car.',
        assets: [],
      };
    }

    const cars = await this.prisma.carModel.findMany();
    const match = matchCatalog(guess, cars as CatalogCar[]);
    if (!match) {
      return {
        identified: true,
        source: 'vlm',
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
      source: 'vlm',
      make: guess.make,
      model: guess.model,
      year: guess.year,
      confidence: guess.confidence,
      yearExact: match.yearExact,
      reason: match.yearExact
        ? undefined
        : `Closest catalog match is ${match.car.year} ${match.car.make} ${match.car.model}`,
      carId: match.car.id,
      car: match.car,
      assets,
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
