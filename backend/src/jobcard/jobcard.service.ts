import { Injectable, NotFoundException, BadRequestException } from '@nestjs/common';
import type { JobCardStatus, PriorityLevel } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service.js';
import type { CreateJobCardInput } from './dto/create-job-card.input.js';
import type { UpdateJobCardStatusInput } from './dto/update-job-card.input.js';

@Injectable()
export class JobCardService {
  constructor(private readonly prisma: PrismaService) {}

  private async generateJobNumber(): Promise<string> {
    const year = new Date().getFullYear();
    const count = await this.prisma.jobCard.count();
    const sequence = String(count + 1).padStart(4, '0');
    return `JOB-${year}-${sequence}`;
  }

  async createJobCard(userId: string, input: CreateJobCardInput) {
    const inspection = await this.prisma.inspectionSession.findUnique({
      where: { id: input.inspectionId },
    });

    if (!inspection) {
      throw new NotFoundException(`Inspection ${input.inspectionId} not found`);
    }

    const existingCard = await this.prisma.jobCard.findUnique({
      where: { inspectionId: input.inspectionId },
    });

    if (existingCard) {
      throw new BadRequestException(
        `Job card ${existingCard.jobNumber} already exists for this inspection`,
      );
    }

    const jobNumber = await this.generateJobNumber();

    const created = await this.prisma.jobCard.create({
      data: {
        jobNumber,
        inspectionId: input.inspectionId,
        userId,
        technicianName: input.technicianName,
        priority: (input.priority ?? 'NORMAL') as PriorityLevel,
        customerNotes: input.customerNotes,
        internalNotes: input.internalNotes,
        estimatedCompletionDate: input.estimatedCompletionDate,
        status: 'ESTIMATED',
        partsRequired: {
          create: (input.partsRequired ?? []).map((p) => ({
            partId: p.partId,
            quantity: p.quantity,
            unitPrice: p.unitPrice,
          })),
        },
      },
      include: {
        partsRequired: {
          include: { part: true },
        },
      },
    });

    return created;
  }

  async updateJobCardStatus(input: UpdateJobCardStatusInput) {
    const existing = await this.prisma.jobCard.findUnique({
      where: { id: input.id },
    });

    if (!existing) {
      throw new NotFoundException(`Job card ${input.id} not found`);
    }

    return this.prisma.jobCard.update({
      where: { id: input.id },
      data: {
        status: input.status as JobCardStatus,
        technicianName: input.technicianName ?? existing.technicianName,
        internalNotes: input.internalNotes ?? existing.internalNotes,
      },
      include: {
        partsRequired: {
          include: { part: true },
        },
      },
    });
  }

  async findOne(id: string) {
    const card = await this.prisma.jobCard.findUnique({
      where: { id },
      include: {
        partsRequired: {
          include: { part: true },
        },
      },
    });

    if (!card) {
      throw new NotFoundException(`Job card ${id} not found`);
    }

    return card;
  }

  async findUserJobCards(userId: string) {
    return this.prisma.jobCard.findMany({
      where: { userId },
      include: {
        partsRequired: {
          include: { part: true },
        },
      },
      orderBy: { createdAt: 'desc' },
    });
  }

  async findAll(status?: string) {
    return this.prisma.jobCard.findMany({
      where: status ? { status: status as JobCardStatus } : undefined,
      include: {
        partsRequired: {
          include: { part: true },
        },
      },
      orderBy: { createdAt: 'desc' },
    });
  }
}
