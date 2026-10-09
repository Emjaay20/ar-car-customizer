import { randomBytes } from 'node:crypto';
import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { AssetType, ConfigurationStatus } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service.js';
import { SaveConfigurationInput } from './dto/save-configuration.input.js';

const configurationInclude = {
  car: true,
  assets: {
    include: { asset: true },
  },
} as const;

@Injectable()
export class CarService {
  constructor(private prisma: PrismaService) {}

  async findAll() {
    return this.prisma.carModel.findMany({
      orderBy: [{ make: 'asc' }, { model: 'asc' }],
    });
  }

  async findOne(id: string) {
    return this.prisma.carModel.findUnique({
      where: { id },
    });
  }

  async findAssets(type?: string) {
    const assetType = type == null ? undefined : parseAssetType(type);

    return this.prisma.asset.findMany({
      where: assetType ? { type: assetType } : undefined,
      orderBy: { name: 'asc' },
    });
  }

  async findAssetsForCar(carId: string, type?: string) {
    const car = await this.prisma.carModel.findUnique({ where: { id: carId } });
    if (!car) {
      throw new NotFoundException('Car not found');
    }

    const assetType = type == null ? undefined : parseAssetType(type);
    return this.prisma.asset.findMany({
      where: {
        ...(assetType ? { type: assetType } : {}),
        fits: { some: { carId } },
      },
      orderBy: [{ type: 'asc' }, { name: 'asc' }],
    });
  }

  async saveConfiguration(userId: string, input: SaveConfigurationInput) {
    const assetIds = [...new Set(input.assetIds)];
    if (assetIds.length === 0) {
      throw new BadRequestException('Select at least one asset');
    }

    const car = await this.prisma.carModel.findUnique({
      where: { id: input.carId },
    });
    if (!car) {
      throw new NotFoundException('Car not found');
    }

    const assets = await this.prisma.asset.findMany({
      where: { id: { in: assetIds } },
    });
    if (assets.length !== assetIds.length) {
      throw new BadRequestException('One or more assets do not exist');
    }

    const name = input.name?.trim();
    const config = await this.prisma.userConfiguration.create({
      data: {
        userId,
        carId: input.carId,
        status: parseStatus(input.status),
        ...(name ? { name } : {}),
        assets: {
          create: assetIds.map((assetId) => ({
            asset: { connect: { id: assetId } },
          })),
        },
      },
      include: configurationInclude,
    });

    return mapConfiguration(config);
  }

  async findConfigurations(userId: string) {
    const configs = await this.prisma.userConfiguration.findMany({
      where: { userId },
      include: configurationInclude,
      orderBy: { createdAt: 'desc' },
    });

    return configs.map((config) => mapConfiguration(config));
  }

  async shareConfiguration(userId: string, configurationId: string) {
    const existing = await this.prisma.userConfiguration.findFirst({
      where: { id: configurationId, userId },
    });
    if (!existing) {
      throw new NotFoundException('Configuration not found');
    }

    const updated = await this.prisma.userConfiguration.update({
      where: { id: existing.id },
      data: { shareToken: existing.shareToken ?? newShareToken() },
      include: configurationInclude,
    });
    return mapConfiguration(updated);
  }

  async findShared(token: string) {
    const shareToken = token.trim();
    if (!shareToken) {
      throw new NotFoundException('Share not found');
    }

    const config = await this.prisma.userConfiguration.findUnique({
      where: { shareToken },
      include: configurationInclude,
    });
    if (!config) {
      throw new NotFoundException('Share not found');
    }

    const mapped = mapConfiguration(config);
    return {
      id: mapped.id,
      name: mapped.name,
      status: mapped.status,
      createdAt: mapped.createdAt,
      car: mapped.car,
      assets: mapped.assets,
    };
  }
}

function mapConfiguration<T extends { assets: Array<{ asset: unknown }> }>(config: T) {
  return {
    ...config,
    assets: config.assets.map((link) => link.asset),
  };
}

function newShareToken(): string {
  return randomBytes(16).toString('base64url');
}

function parseAssetType(value: string): AssetType {
  if (!Object.values(AssetType).includes(value as AssetType)) {
    throw new BadRequestException(`Unknown asset type: ${value}`);
  }
  return value as AssetType;
}

function parseStatus(status?: string): ConfigurationStatus {
  if (!status) return ConfigurationStatus.DRAFT;
  if (!Object.values(ConfigurationStatus).includes(status as ConfigurationStatus)) {
    throw new BadRequestException(`Unknown status: ${status}`);
  }
  return status as ConfigurationStatus;
}
