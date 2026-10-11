import { Injectable, NotFoundException } from '@nestjs/common';
import type { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service.js';
import {
  calculateRepairEstimate,
  type DamageAssessmentItem,
  type DamageType,
  type SeverityLevel,
  type RepairAction,
} from '../estimator/damage-calculator.js';
import type { CreateInspectionInput } from './dto/create-inspection.input.js';
import type { RecordDamageAssessmentInput } from './dto/record-damage.input.js';

@Injectable()
export class InspectionService {
  constructor(private readonly prisma: PrismaService) {}

  async startInspection(userId: string, input: CreateInspectionInput) {
    return this.prisma.inspectionSession.create({
      data: {
        userId,
        carId: input.carId,
        licensePlate: input.licensePlate,
        vin: input.vin,
        make: input.make,
        model: input.model,
        year: input.year,
        imageUrl: input.imageUrl,
        status: 'IN_PROGRESS',
      },
      include: {
        damages: true,
        estimate: true,
      },
    });
  }

  async recordDamageAssessment(userId: string, input: RecordDamageAssessmentInput) {
    const inspection = await this.prisma.inspectionSession.findUnique({
      where: { id: input.inspectionId },
      include: { damages: true },
    });

    if (!inspection) {
      throw new NotFoundException(`Inspection ${input.inspectionId} not found`);
    }

    // Insert new damage records
    const createdDamages = await Promise.all(
      input.damages.map((item) => {
        let parsedBoundingBox: Prisma.InputJsonValue = {};
        try {
          parsedBoundingBox = JSON.parse(item.boundingBoxJson);
        } catch {
          parsedBoundingBox = { raw: item.boundingBoxJson };
        }

        let parsedSpatialAnchor: Prisma.InputJsonValue | undefined = undefined;
        if (item.spatialAnchorJson) {
          try {
            parsedSpatialAnchor = JSON.parse(item.spatialAnchorJson);
          } catch {
            parsedSpatialAnchor = { raw: item.spatialAnchorJson };
          }
        }

        return this.prisma.damageRecord.create({
          data: {
            inspectionId: inspection.id,
            damageType: item.damageType as DamageType,
            severity: item.severity as SeverityLevel,
            confidence: item.confidence,
            affectedPanel: item.affectedPanel,
            areaPercentage: item.areaPercentage,
            boundingBox: parsedBoundingBox,
            spatialAnchor: parsedSpatialAnchor,
            maskUrl: item.maskUrl,
            recommendedAction: item.recommendedAction as RepairAction,
            estimatedLaborHours: item.estimatedLaborHours,
          },
        });
      }),
    );

    // Fetch all current damages for this inspection to compute total quote
    const allDamages = await this.prisma.damageRecord.findMany({
      where: { inspectionId: inspection.id },
    });

    const assessmentItems: DamageAssessmentItem[] = allDamages.map((d) => ({
      id: d.id,
      damageType: d.damageType as DamageType,
      severity: d.severity as SeverityLevel,
      affectedPanel: d.affectedPanel,
      areaPercentage: d.areaPercentage,
      confidence: d.confidence,
      recommendedAction: d.recommendedAction as RepairAction,
      estimatedLaborHours: d.estimatedLaborHours,
    }));

    const estimateResult = calculateRepairEstimate(assessmentItems);

    const estimate = await this.prisma.costEstimate.upsert({
      where: { inspectionId: inspection.id },
      create: {
        inspectionId: inspection.id,
        laborCost: estimateResult.laborCost,
        paintMaterialCost: estimateResult.paintMaterialCost,
        partsCost: estimateResult.partsCost,
        subtotal: estimateResult.subtotal,
        tax: estimateResult.tax,
        total: estimateResult.total,
        currency: estimateResult.currency,
        priceBandMin: estimateResult.priceBandMin,
        priceBandMax: estimateResult.priceBandMax,
      },
      update: {
        laborCost: estimateResult.laborCost,
        paintMaterialCost: estimateResult.paintMaterialCost,
        partsCost: estimateResult.partsCost,
        subtotal: estimateResult.subtotal,
        tax: estimateResult.tax,
        total: estimateResult.total,
        priceBandMin: estimateResult.priceBandMin,
        priceBandMax: estimateResult.priceBandMax,
      },
    });

    const updated = await this.prisma.inspectionSession.findUnique({
      where: { id: inspection.id },
      include: {
        damages: true,
        estimate: true,
      },
    });

    return updated!;
  }

  async findOne(id: string) {
    const inspection = await this.prisma.inspectionSession.findUnique({
      where: { id },
      include: {
        damages: true,
        estimate: true,
      },
    });

    if (!inspection) {
      throw new NotFoundException(`Inspection ${id} not found`);
    }

    return inspection;
  }

  async findUserInspections(userId: string) {
    return this.prisma.inspectionSession.findMany({
      where: { userId },
      include: {
        damages: true,
        estimate: true,
      },
      orderBy: { createdAt: 'desc' },
    });
  }
}
