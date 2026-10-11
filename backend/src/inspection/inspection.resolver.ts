import { UseGuards } from '@nestjs/common';
import { Args, ID, Mutation, Query, Resolver } from '@nestjs/graphql';
import type { AuthUser } from '../auth/auth-user.js';
import { CurrentUser } from '../auth/current-user.decorator.js';
import { GqlAuthGuard } from '../auth/gql-auth.guard.js';
import { InspectionService } from './inspection.service.js';
import { InspectionModel } from './models/inspection.model.js';
import { CreateInspectionInput } from './dto/create-inspection.input.js';
import { RecordDamageAssessmentInput } from './dto/record-damage.input.js';

function formatInspection(raw: any): InspectionModel {
  return {
    ...raw,
    damages: (raw.damages ?? []).map((d: any) => ({
      ...d,
      boundingBoxJson: JSON.stringify(d.boundingBox),
      spatialAnchorJson: d.spatialAnchor ? JSON.stringify(d.spatialAnchor) : null,
    })),
  };
}

@Resolver(() => InspectionModel)
export class InspectionResolver {
  constructor(private readonly inspectionService: InspectionService) {}

  @UseGuards(GqlAuthGuard)
  @Mutation(() => InspectionModel, { name: 'startInspection' })
  async startInspection(
    @Args('input', { type: () => CreateInspectionInput }) input: CreateInspectionInput,
    @CurrentUser() user: AuthUser,
  ) {
    const raw = await this.inspectionService.startInspection(user.id, input);
    return formatInspection(raw);
  }

  @UseGuards(GqlAuthGuard)
  @Mutation(() => InspectionModel, { name: 'recordDamageAssessment' })
  async recordDamageAssessment(
    @Args('input', { type: () => RecordDamageAssessmentInput }) input: RecordDamageAssessmentInput,
    @CurrentUser() user: AuthUser,
  ) {
    const raw = await this.inspectionService.recordDamageAssessment(user.id, input);
    return formatInspection(raw);
  }

  @Query(() => InspectionModel, { name: 'inspection' })
  async getInspection(@Args('id', { type: () => ID }) id: string) {
    const raw = await this.inspectionService.findOne(id);
    return formatInspection(raw);
  }

  @UseGuards(GqlAuthGuard)
  @Query(() => [InspectionModel], { name: 'myInspections' })
  async getMyInspections(@CurrentUser() user: AuthUser) {
    const list = await this.inspectionService.findUserInspections(user.id);
    return list.map(formatInspection);
  }
}
