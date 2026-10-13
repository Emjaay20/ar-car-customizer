import { Field, Int, ObjectType } from '@nestjs/graphql';

@ObjectType()
export class LiveSegmentationModel {
  @Field()
  masked!: boolean;

  @Field({ nullable: true })
  maskBase64?: string;

  @Field({ nullable: true })
  polishedBase64?: string;

  @Field(() => Int)
  paintPixels!: number;

  @Field()
  source!: string;

  @Field({ nullable: true })
  reason?: string;

  @Field({ nullable: true })
  frameId?: string;
}
