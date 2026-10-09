import { BadRequestException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { VisionService } from './vision.service.js';
import type { VisionClient } from './vision.client.js';

const civic = {
  id: '22222222-2222-4222-8222-222222222222',
  make: 'Honda',
  model: 'Civic',
  year: 2018,
  baseMeshUrl: '/models/cesium-milk-truck.glb',
};

const rim = {
  id: '33333333-3333-4333-8333-333333333333',
  type: 'RIM',
  name: '18-inch Civic Si',
  materialBundleUrl: 'primitive:rim',
  price: 220000,
  anchor: 'wheels',
};

function serviceWith(identify: VisionClient['identify']) {
  const prisma = {
    carModel: { findMany: vi.fn().mockResolvedValue([civic]) },
    asset: { findMany: vi.fn().mockResolvedValue([rim]) },
  };
  const vision = { identify };
  return {
    prisma,
    service: new VisionService(prisma as never, vision as never),
  };
}

describe('VisionService.identify', () => {
  it('returns fitting assets only after a confident catalog match', async () => {
    const { prisma, service } = serviceWith(async () => ({
      ok: true,
      guess: { make: 'Honda', model: 'Civic', year: 2018, confidence: 0.9 },
    }));

    const result = await service.identify(Buffer.from('car').toString('base64'), 'image/jpeg');

    expect(result.identified).toBe(true);
    expect(result.carId).toBe(civic.id);
    expect(result.assets).toEqual([rim]);
    expect(prisma.asset.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { fits: { some: { carId: civic.id } } },
      }),
    );
  });

  it('does not attach parts when confidence is low', async () => {
    const { prisma, service } = serviceWith(async () => ({
      ok: true,
      guess: { make: 'Honda', model: 'Civic', year: 2018, confidence: 0.2 },
    }));

    const result = await service.identify(Buffer.from('car').toString('base64'), 'image/jpeg');

    expect(result.identified).toBe(false);
    expect(result.assets).toEqual([]);
    expect(result.car).toBeUndefined();
    expect(prisma.asset.findMany).not.toHaveBeenCalled();
  });

  it('rejects an oversized image before calling the model', async () => {
    const identify = vi.fn();
    const { service } = serviceWith(identify);
    const huge = 'a'.repeat(8_000_001);

    await expect(service.identify(huge, 'image/jpeg')).rejects.toBeInstanceOf(BadRequestException);
    expect(identify).not.toHaveBeenCalled();
  });
});
