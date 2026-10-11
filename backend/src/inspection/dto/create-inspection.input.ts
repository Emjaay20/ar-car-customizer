import { Field, InputType, Int, ID } from '@nestjs/graphql';

@InputType()
export class CreateInspectionInput {
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

  @Field({ nullable: true })
  imageUrl?: string;
}
