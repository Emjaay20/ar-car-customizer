import { Field, InputType } from '@nestjs/graphql';

@InputType()
export class IdentifyVehicleInput {
  @Field()
  imageBase64: string;

  @Field({ nullable: true })
  mimeType?: string;
}
