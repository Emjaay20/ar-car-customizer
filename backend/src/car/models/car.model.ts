import { Field, ObjectType, Int, ID } from '@nestjs/graphql';

@ObjectType()
export class CarModel {
  @Field(() => ID)
  id: string;

  @Field()
  make: string;

  @Field()
  model: string;

  @Field(() => Int)
  year: number;

  @Field()
  baseMeshUrl: string;
}
