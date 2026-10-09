import { Field, ObjectType, ID } from '@nestjs/graphql';
import { CarModel } from './car.model.js';
import { AssetModel } from './asset.model.js';

@ObjectType()
export class UserConfigurationModel {
  @Field(() => ID)
  id: string;

  @Field(() => ID)
  userId: string;

  @Field(() => ID)
  carId: string;

  @Field({ nullable: true })
  name?: string;

  @Field({ nullable: true })
  shareToken?: string;

  @Field()
  status: string;

  @Field()
  createdAt: Date;

  @Field(() => CarModel, { nullable: true })
  car?: CarModel;

  @Field(() => [AssetModel])
  assets: AssetModel[];
}