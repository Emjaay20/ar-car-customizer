import { Field, ID, Float, ObjectType } from '@nestjs/graphql';

@ObjectType()
export class DamageRecordModel {
  @Field(() => ID)
  id: string;

  @Field(() => ID)
  inspectionId: string;

  @Field()
  damageType: string;

  @Field()
  severity: string;

  @Field(() => Float)
  confidence: number;

  @Field()
  affectedPanel: string;

  @Field(() => Float)
  areaPercentage: number;

  @Field()
  boundingBoxJson: string;

  @Field({ nullable: true })
  spatialAnchorJson?: string;

  @Field({ nullable: true })
  maskUrl?: string;

  @Field()
  recommendedAction: string;

  @Field(() => Float)
  estimatedLaborHours: number;

  @Field()
  createdAt: Date;
}
