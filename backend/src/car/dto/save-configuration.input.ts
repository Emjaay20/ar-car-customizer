import { Field, ID, InputType } from '@nestjs/graphql';

@InputType()
export class SaveConfigurationInput {
  @Field(() => ID)
  carId: string;

  @Field(() => [ID])
  assetIds: string[];

  @Field({ nullable: true })
  status?: string;

  @Field({ nullable: true })
  name?: string;
}
