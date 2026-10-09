import { NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PrismaService } from '../prisma/prisma.service.js';
import { CarService } from './car.service.js';

const userId = '11111111-1111-4111-8111-111111111111';
const carId = '22222222-2222-4222-8222-222222222222';
const assetId = '33333333-3333-4333-8333-333333333333';

const car = {
  id: carId,
  make: 'Toyota',
  model: 'Camry',
  year: 2018,
  baseMeshUrl: '/models/cesium-milk-truck.glb',
};

const paint = {
  id: assetId,
  type: 'PAINT',
  name: 'Gloss Black',
  materialBundleUrl: 'color:#111111',
  price: 150000,
};

describe('CarService.saveConfiguration', () => {
  let service: CarService;
  const prisma = {
    carModel: { findUnique: vi.fn() },
    asset: { findMany: vi.fn() },
    userConfiguration: { create: vi.fn() },
  };

  beforeEach(async () => {
    vi.clearAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        CarService,
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    service = module.get(CarService);
  });

  it('saves a configuration for the authenticated user', async () => {
    prisma.carModel.findUnique.mockResolvedValue(car);
    prisma.asset.findMany.mockResolvedValue([paint]);
    prisma.userConfiguration.create.mockImplementation(async ({ data }) => ({
      id: 'config-1',
      userId: data.userId,
      carId: data.carId,
      status: data.status,
      createdAt: new Date('2026-01-01T00:00:00.000Z'),
      car,
      assets: [{ asset: paint }],
    }));

    const result = await service.saveConfiguration(userId, {
      carId,
      assetIds: [assetId],
      status: 'DRAFT',
    });

    expect(prisma.userConfiguration.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          userId,
          carId,
          status: 'DRAFT',
          assets: {
            create: [{ asset: { connect: { id: assetId } } }],
          },
        }),
      }),
    );
    expect(result.userId).toBe(userId);
    expect(result.assets).toEqual([paint]);
  });

  it('does not save when the car does not exist', async () => {
    prisma.carModel.findUnique.mockResolvedValue(null);

    await expect(
      service.saveConfiguration(userId, {
        carId,
        assetIds: [assetId],
      }),
    ).rejects.toBeInstanceOf(NotFoundException);
    expect(prisma.userConfiguration.create).not.toHaveBeenCalled();
  });
});

describe('CarService fitment and sharing', () => {
  const prisma = {
    carModel: { findUnique: vi.fn() },
    asset: { findMany: vi.fn() },
    userConfiguration: {
      findFirst: vi.fn(),
      findUnique: vi.fn(),
      update: vi.fn(),
    },
  };
  let service: CarService;

  beforeEach(async () => {
    vi.clearAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [CarService, { provide: PrismaService, useValue: prisma }],
    }).compile();
    service = module.get(CarService);
  });

  it('returns only assets fitted to the requested car', async () => {
    prisma.carModel.findUnique.mockResolvedValue(car);
    prisma.asset.findMany.mockResolvedValue([paint]);

    await service.findAssetsForCar(carId, 'PAINT');

    expect(prisma.asset.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { type: 'PAINT', fits: { some: { carId } } },
      }),
    );
  });

  it('does not share another user configuration', async () => {
    prisma.userConfiguration.findFirst.mockResolvedValue(null);

    await expect(service.shareConfiguration(userId, 'config-1')).rejects.toBeInstanceOf(
      NotFoundException,
    );
    expect(prisma.userConfiguration.update).not.toHaveBeenCalled();
  });

  it('keeps an existing share token', async () => {
    prisma.userConfiguration.findFirst.mockResolvedValue({
      id: 'config-1',
      userId,
      shareToken: 'already-shared',
    });
    prisma.userConfiguration.update.mockResolvedValue({
      id: 'config-1',
      userId,
      shareToken: 'already-shared',
      car,
      assets: [{ asset: paint }],
    });

    const result = await service.shareConfiguration(userId, 'config-1');

    expect(prisma.userConfiguration.update).toHaveBeenCalledWith(
      expect.objectContaining({
        data: { shareToken: 'already-shared' },
      }),
    );
    expect(result.shareToken).toBe('already-shared');
  });
});
