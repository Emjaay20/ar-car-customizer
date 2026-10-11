import { BadRequestException, NotFoundException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { PrismaService } from '../prisma/prisma.service.js';
import { JobCardService } from './jobcard.service.js';

const userId = '11111111-1111-4111-8111-111111111111';
const inspectionId = '22222222-2222-4222-8222-222222222222';
const jobCardId = '33333333-3333-4333-8333-333333333333';

describe('JobCardService', () => {
  let service: JobCardService;
  const prisma = {
    jobCard: {
      count: vi.fn(),
      create: vi.fn(),
      findUnique: vi.fn(),
      update: vi.fn(),
      findMany: vi.fn(),
    },
    inspectionSession: {
      findUnique: vi.fn(),
    },
  };

  beforeEach(async () => {
    vi.clearAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        JobCardService,
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    service = module.get<JobCardService>(JobCardService);
  });

  it('throws NotFoundException if inspection does not exist', async () => {
    prisma.inspectionSession.findUnique.mockResolvedValue(null);

    await expect(
      service.createJobCard(userId, { inspectionId }),
    ).rejects.toThrow(NotFoundException);
  });

  it('throws BadRequestException if job card already exists for inspection', async () => {
    prisma.inspectionSession.findUnique.mockResolvedValue({ id: inspectionId });
    prisma.jobCard.findUnique.mockResolvedValue({ id: jobCardId, jobNumber: 'JOB-2026-0001' });

    await expect(
      service.createJobCard(userId, { inspectionId }),
    ).rejects.toThrow(BadRequestException);
  });

  it('generates sequential job number and creates job card', async () => {
    prisma.inspectionSession.findUnique.mockResolvedValue({ id: inspectionId });
    prisma.jobCard.findUnique.mockResolvedValue(null);
    prisma.jobCard.count.mockResolvedValue(4);

    const mockCreated = {
      id: jobCardId,
      jobNumber: 'JOB-2026-0005',
      inspectionId,
      userId,
      status: 'ESTIMATED',
      partsRequired: [],
    };
    prisma.jobCard.create.mockResolvedValue(mockCreated);

    const result = await service.createJobCard(userId, { inspectionId });
    expect(result.jobNumber).toBe('JOB-2026-0005');
    expect(prisma.jobCard.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          jobNumber: 'JOB-2026-0005',
          status: 'ESTIMATED',
        }),
      }),
    );
  });

  it('updates job card status and technician notes', async () => {
    prisma.jobCard.findUnique.mockResolvedValue({ id: jobCardId, status: 'ESTIMATED' });
    prisma.jobCard.update.mockResolvedValue({
      id: jobCardId,
      status: 'IN_PROGRESS',
      technicianName: 'Bob Mechanic',
      partsRequired: [],
    });

    const result = await service.updateJobCardStatus({
      id: jobCardId,
      status: 'IN_PROGRESS',
      technicianName: 'Bob Mechanic',
    });

    expect(result.status).toBe('IN_PROGRESS');
    expect(result.technicianName).toBe('Bob Mechanic');
  });
});
