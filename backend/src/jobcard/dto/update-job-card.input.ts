import { Field, InputType, ID } from '@nestjs/graphql';

@InputType()
export class UpdateJobCardStatusInput {
  @Field(() => ID)
  id: string;

  @Field()
  status: string;

  @Field({ nullable: true })
  technicianName?: string;

  @Field({ nullable: true })
  internalNotes?: string;
}
