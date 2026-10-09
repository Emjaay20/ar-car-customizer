import { Field, ID, ObjectType } from '@nestjs/graphql';
import { AssetModel } from './asset.model.js';
import { CarModel } from './car.model.js';

@ObjectType()
export class SharedConfigurationModel {
  @Field(() => ID)
  id: string;

  @Field({ nullable: true })
  name?: string;

  @Field()
  status: string;

  @Field()
  createdAt: Date;

  @Field(() => CarModel, { nullable: true })
  car?: CarModel;

  @Field(() => [AssetModel])
  assets: AssetModel[];
}
