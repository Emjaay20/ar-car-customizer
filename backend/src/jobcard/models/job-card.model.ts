import { Field, ID, ObjectType, Int, Float } from '@nestjs/graphql';

@ObjectType()
export class JobCardPartModel {
  @Field(() => ID)
  partId: string;

  @Field()
  partName: string;

  @Field(() => Int)
  quantity: number;

  @Field(() => Float)
  unitPrice: number;
}

@ObjectType()
export class JobCardModel {
  @Field(() => ID)
  id: string;

  @Field()
  jobNumber: string;

  @Field(() => ID)
  inspectionId: string;

  @Field(() => ID)
  userId: string;

  @Field({ nullable: true })
  technicianName?: string;

  @Field()
  status: string;

  @Field()
  priority: string;

  @Field({ nullable: true })
  customerNotes?: string;

  @Field({ nullable: true })
  internalNotes?: string;

  @Field({ nullable: true })
  estimatedCompletionDate?: Date;

  @Field(() => [JobCardPartModel])
  partsRequired: JobCardPartModel[];

  @Field()
  createdAt: Date;

  @Field()
  updatedAt: Date;
}
