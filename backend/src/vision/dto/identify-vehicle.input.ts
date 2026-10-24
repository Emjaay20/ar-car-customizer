import { Field, InputType } from '@nestjs/graphql';

@InputType()
export class IdentifyVehicleInput {
  @Field()
  imageBase64: string;

  @Field({ nullable: true })
  mimeType?: string;

  @Field({ nullable: true })
  hexColor?: string;

  @Field({ nullable: true })
  finish?: string;

  @Field({ nullable: true })
  panel?: string;

  @Field({ nullable: true })
  repolishOnly?: boolean;

  @Field({ nullable: true })
  frameId?: string;

  @Field({ nullable: true })
  hdMode?: boolean;

  @Field({ nullable: true })
  fullCoverage?: boolean;
}
