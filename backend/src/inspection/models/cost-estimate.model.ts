import { Field, ID, Float, ObjectType } from '@nestjs/graphql';

@ObjectType()
export class CostEstimateModel {
  @Field(() => ID)
  id: string;

  @Field(() => ID)
  inspectionId: string;

  @Field(() => Float)
  laborCost: number;

  @Field(() => Float)
  paintMaterialCost: number;

  @Field(() => Float)
  partsCost: number;

  @Field(() => Float)
  subtotal: number;

  @Field(() => Float)
  tax: number;

  @Field(() => Float)
  total: number;

  @Field()
  currency: string;

  @Field(() => Float)
  priceBandMin: number;

  @Field(() => Float)
  priceBandMax: number;

  @Field()
  createdAt: Date;
}
