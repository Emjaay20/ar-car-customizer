import { UseGuards } from '@nestjs/common';
import { Args, ID, Mutation, Query, Resolver } from '@nestjs/graphql';
import type { AuthUser } from '../auth/auth-user.js';
import { CurrentUser } from '../auth/current-user.decorator.js';
import { GqlAuthGuard } from '../auth/gql-auth.guard.js';
import { JobCardService } from './jobcard.service.js';
import { JobCardModel } from './models/job-card.model.js';
import { CreateJobCardInput } from './dto/create-job-card.input.js';
import { UpdateJobCardStatusInput } from './dto/update-job-card.input.js';

function formatJobCard(raw: any): JobCardModel {
  return {
    ...raw,
    partsRequired: (raw.partsRequired ?? []).map((p: any) => ({
      partId: p.partId,
      partName: p.part?.name ?? 'Unknown Part',
      quantity: p.quantity,
      unitPrice: p.unitPrice,
    })),
  };
}

@Resolver(() => JobCardModel)
export class JobCardResolver {
  constructor(private readonly jobCardService: JobCardService) {}

  @UseGuards(GqlAuthGuard)
  @Mutation(() => JobCardModel, { name: 'createJobCard' })
  async createJobCard(
    @Args('input', { type: () => CreateJobCardInput }) input: CreateJobCardInput,
    @CurrentUser() user: AuthUser,
  ) {
    const raw = await this.jobCardService.createJobCard(user.id, input);
    return formatJobCard(raw);
  }

  @UseGuards(GqlAuthGuard)
  @Mutation(() => JobCardModel, { name: 'updateJobCardStatus' })
  async updateJobCardStatus(
    @Args('input', { type: () => UpdateJobCardStatusInput }) input: UpdateJobCardStatusInput,
  ) {
    const raw = await this.jobCardService.updateJobCardStatus(input);
    return formatJobCard(raw);
  }

  @Query(() => JobCardModel, { name: 'jobCard' })
  async getJobCard(@Args('id', { type: () => ID }) id: string) {
    const raw = await this.jobCardService.findOne(id);
    return formatJobCard(raw);
  }

  @UseGuards(GqlAuthGuard)
  @Query(() => [JobCardModel], { name: 'myJobCards' })
  async getMyJobCards(@CurrentUser() user: AuthUser) {
    const list = await this.jobCardService.findUserJobCards(user.id);
    return list.map(formatJobCard);
  }

  @Query(() => [JobCardModel], { name: 'jobCards' })
  async getJobCards(@Args('status', { nullable: true }) status?: string) {
    const list = await this.jobCardService.findAll(status);
    return list.map(formatJobCard);
  }
}
