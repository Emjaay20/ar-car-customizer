import { Field, InputType } from '@nestjs/graphql';

@InputType()
export class GenerateShowroomReelInput {
  @Field(() => [String])
  imagesBase64!: string[];

  @Field(() => [String])
  labels!: string[];

  @Field({ nullable: true })
  paintName?: string;

  @Field({ nullable: true })
  hexColor?: string;

  @Field({ nullable: true })
  finish?: string;

  @Field({ nullable: true })
  vehicleTitle?: string;
}
