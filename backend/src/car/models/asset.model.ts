import { Field, ObjectType, ID, Float } from '@nestjs/graphql';

@ObjectType()
export class AssetModel {
  @Field(() => ID)
  id: string;

  @Field()
  type: string;

  @Field()
  name: string;

  @Field()
  materialBundleUrl: string;

  @Field(() => Float)
  price: number;

  @Field(() => String, { nullable: true })
  anchor?: string | null;
}