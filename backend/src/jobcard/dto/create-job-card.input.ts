import { Field, InputType, ID, Int, Float } from '@nestjs/graphql';

@InputType()
export class JobCardPartInput {
  @Field(() => ID)
  partId: string;

  @Field(() => Int, { defaultValue: 1 })
  quantity: number;

  @Field(() => Float)
  unitPrice: number;
}

@InputType()
export class CreateJobCardInput {
  @Field(() => ID)
  inspectionId: string;

  @Field({ nullable: true })
  technicianName?: string;

  @Field({ defaultValue: 'NORMAL' })
  priority: string;

  @Field({ nullable: true })
  customerNotes?: string;

  @Field({ nullable: true })
  internalNotes?: string;

  @Field({ nullable: true })
  estimatedCompletionDate?: Date;

  @Field(() => [JobCardPartInput], { defaultValue: [] })
  partsRequired: JobCardPartInput[];
}
