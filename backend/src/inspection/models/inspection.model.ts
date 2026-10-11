import { Field, ID, Int, ObjectType } from '@nestjs/graphql';
import { DamageRecordModel } from './damage-record.model.js';
import { CostEstimateModel } from './cost-estimate.model.js';

@ObjectType()
export class InspectionModel {
  @Field(() => ID)
  id: string;

  @Field(() => ID)
  userId: string;

  @Field(() => ID, { nullable: true })
  carId?: string;

  @Field({ nullable: true })
  licensePlate?: string;

  @Field({ nullable: true })
  vin?: string;

  @Field({ nullable: true })
  make?: string;

  @Field({ nullable: true })
  model?: string;

  @Field(() => Int, { nullable: true })
  year?: number;

  @Field()
  status: string;

  @Field({ nullable: true })
  imageUrl?: string;

  @Field(() => [DamageRecordModel])
  damages: DamageRecordModel[];

  @Field(() => CostEstimateModel, { nullable: true })
  estimate?: CostEstimateModel;

  @Field()
  createdAt: Date;

  @Field()
  updatedAt: Date;
}
