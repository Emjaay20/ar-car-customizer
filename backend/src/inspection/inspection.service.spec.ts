import { NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PrismaService } from '../prisma/prisma.service.js';
import { InspectionService } from './inspection.service.js';

const userId = '11111111-1111-4111-8111-111111111111';
const inspectionId = '22222222-2222-4222-8222-222222222222';

describe('InspectionService', () => {
  let service: InspectionService;
  const prisma = {
    inspectionSession: {
      create: vi.fn(),
      findUnique: vi.fn(),
      findMany: vi.fn(),
    },
    damageRecord: {
      create: vi.fn(),
      findMany: vi.fn(),
    },
    costEstimate: {
      upsert: vi.fn(),
    },
  };

  beforeEach(async () => {
    vi.clearAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        InspectionService,
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    service = module.get<InspectionService>(InspectionService);
  });

  it('starts an inspection session', async () => {
    const input = {
      licensePlate: 'ABC-1234',
      make: 'Toyota',
      model: 'Camry',
      year: 2018,
    };
    const mockCreated = { id: inspectionId, userId, ...input, status: 'IN_PROGRESS' };
    prisma.inspectionSession.create.mockResolvedValue(mockCreated);

    const result = await service.startInspection(userId, input);
    expect(result).toEqual(mockCreated);
    expect(prisma.inspectionSession.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ licensePlate: 'ABC-1234', userId }),
      }),
    );
  });

  it('throws NotFoundException when recording damage on missing inspection', async () => {
    prisma.inspectionSession.findUnique.mockResolvedValue(null);

    await expect(
      service.recordDamageAssessment(userId, {
        inspectionId: 'non-existent',
        damages: [],
      }),
    ).rejects.toThrow(NotFoundException);
  });

  it('records damage, triggers cost calculation and upserts cost estimate', async () => {
    const mockSession = { id: inspectionId, userId, damages: [] };
    prisma.inspectionSession.findUnique.mockResolvedValueOnce(mockSession);

    const mockDamage = {
      id: 'damage-1',
      inspectionId,
      damageType: 'SCRATCH',
      severity: 'MINOR',
      confidence: 0.95,
      affectedPanel: 'FRONT_BUMPER',
      areaPercentage: 3.5,
      boundingBox: { x: 10, y: 20, width: 30, height: 40 },
      recommendedAction: 'BUFF',
      estimatedLaborHours: 1.0,
    };
    prisma.damageRecord.create.mockResolvedValue(mockDamage);
    prisma.damageRecord.findMany.mockResolvedValue([mockDamage]);
    prisma.costEstimate.upsert.mockResolvedValue({ id: 'est-1', inspectionId, total: 150 });
    prisma.inspectionSession.findUnique.mockResolvedValueOnce({
      ...mockSession,
      damages: [mockDamage],
      estimate: { id: 'est-1', inspectionId, total: 150 },
    });

    const result = await service.recordDamageAssessment(userId, {
      inspectionId,
      damages: [
        {
          damageType: 'SCRATCH',
          severity: 'MINOR',
          confidence: 0.95,
          affectedPanel: 'FRONT_BUMPER',
          areaPercentage: 3.5,
          boundingBoxJson: JSON.stringify({ x: 10, y: 20, width: 30, height: 40 }),
          recommendedAction: 'BUFF',
          estimatedLaborHours: 1.0,
        },
      ],
    });

    expect(result.damages).toHaveLength(1);
    expect(prisma.costEstimate.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { inspectionId },
      }),
    );
  });
});
