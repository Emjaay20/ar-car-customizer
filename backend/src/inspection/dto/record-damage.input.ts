import { Field, InputType, Float, ID } from '@nestjs/graphql';

@InputType()
export class DamageItemInput {
  @Field()
  damageType: string;

  @Field()
  severity: string;

  @Field(() => Float, { defaultValue: 0.9 })
  confidence: number;

  @Field()
  affectedPanel: string;

  @Field(() => Float, { defaultValue: 5.0 })
  areaPercentage: number;

  @Field()
  boundingBoxJson: string;

  @Field({ nullable: true })
  spatialAnchorJson?: string;

  @Field({ nullable: true })
  maskUrl?: string;

  @Field({ defaultValue: 'REPAIR' })
  recommendedAction: string;

  @Field(() => Float, { defaultValue: 1.5 })
  estimatedLaborHours: number;
}

@InputType()
export class RecordDamageAssessmentInput {
  @Field(() => ID)
  inspectionId: string;

  @Field(() => [DamageItemInput])
  damages: DamageItemInput[];
}
