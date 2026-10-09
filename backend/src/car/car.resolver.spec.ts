import { Test, TestingModule } from '@nestjs/testing';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { CarResolver } from './car.resolver.js';
import { CarService } from './car.service.js';

describe('CarResolver.saveConfiguration', () => {
  let resolver: CarResolver;
  const carService = {
    saveConfiguration: vi.fn(),
  };

  beforeEach(async () => {
    vi.clearAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        CarResolver,
        { provide: CarService, useValue: carService },
      ],
    }).compile();

    resolver = module.get(CarResolver);
  });

  it('saves using the authenticated user id, not a client-supplied user id', async () => {
    const input = {
      carId: '22222222-2222-4222-8222-222222222222',
      assetIds: ['33333333-3333-4333-8333-333333333333'],
      status: 'DRAFT',
    };
    carService.saveConfiguration.mockResolvedValue({ id: 'config-1' });

    await resolver.saveConfiguration(input, {
      id: '11111111-1111-4111-8111-111111111111',
      email: 'demo@arcar.com',
    });

    expect(carService.saveConfiguration).toHaveBeenCalledWith(
      '11111111-1111-4111-8111-111111111111',
      input,
    );
  });
});
