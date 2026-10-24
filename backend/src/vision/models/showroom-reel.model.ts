import { Field, ObjectType } from '@nestjs/graphql';

@ObjectType()
export class ShowroomReelModel {
  @Field()
  ok!: boolean;

  @Field({ nullable: true })
  videoBase64?: string;

  @Field({ nullable: true })
  reason?: string;
}
