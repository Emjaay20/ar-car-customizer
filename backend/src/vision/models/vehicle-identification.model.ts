import { Field, Float, ID, Int, ObjectType } from '@nestjs/graphql';
import { AssetModel } from '../../car/models/asset.model.js';
import { CarModel } from '../../car/models/car.model.js';

@ObjectType()
export class VehicleIdentificationModel {
  @Field()
  identified: boolean;

  @Field()
  source: string;

  @Field({ nullable: true })
  make?: string;

  @Field({ nullable: true })
  model?: string;

  @Field(() => Int, { nullable: true })
  year?: number;

  @Field(() => Float, { nullable: true })
  confidence?: number;

  @Field()
  yearExact: boolean;

  @Field({ nullable: true })
  reason?: string;

  @Field(() => ID, { nullable: true })
  carId?: string;

  @Field(() => CarModel, { nullable: true })
  car?: CarModel;

  @Field(() => [AssetModel])
  assets: AssetModel[];
}
