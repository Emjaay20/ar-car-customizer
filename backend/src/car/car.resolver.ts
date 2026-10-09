import { UseGuards } from '@nestjs/common';
import { Args, ID, Mutation, Query, Resolver } from '@nestjs/graphql';
import type { AuthUser } from '../auth/auth-user.js';
import { CurrentUser } from '../auth/current-user.decorator.js';
import { GqlAuthGuard } from '../auth/gql-auth.guard.js';
import { CarService } from './car.service.js';
import { SaveConfigurationInput } from './dto/save-configuration.input.js';
import { AssetModel } from './models/asset.model.js';
import { CarModel } from './models/car.model.js';
import { SharedConfigurationModel } from './models/shared-configuration.model.js';
import { UserConfigurationModel } from './models/user-configuration.model.js';

@Resolver(() => CarModel)
export class CarResolver {
  constructor(private readonly carService: CarService) {}

  @Query(() => [CarModel], { name: 'cars' })
  getCars() {
    return this.carService.findAll();
  }

  @Query(() => CarModel, { nullable: true, name: 'car' })
  getCar(@Args('id', { type: () => ID }) id: string) {
    return this.carService.findOne(id);
  }

  @Query(() => [AssetModel], { name: 'assets' })
  getAssets(@Args('type', { nullable: true }) type?: string) {
    return this.carService.findAssets(type);
  }

  @Query(() => [AssetModel], { name: 'assetsForCar' })
  getAssetsForCar(
    @Args('carId', { type: () => ID }) carId: string,
    @Args('type', { nullable: true }) type?: string,
  ) {
    return this.carService.findAssetsForCar(carId, type);
  }

  @Query(() => SharedConfigurationModel, { name: 'sharedConfiguration' })
  getSharedConfiguration(@Args('token') token: string) {
    return this.carService.findShared(token);
  }

  @UseGuards(GqlAuthGuard)
  @Mutation(() => UserConfigurationModel, { name: 'saveConfiguration' })
  saveConfiguration(
    @Args('input') input: SaveConfigurationInput,
    @CurrentUser() user: AuthUser,
  ) {
    return this.carService.saveConfiguration(user.id, input);
  }

  @UseGuards(GqlAuthGuard)
  @Query(() => [UserConfigurationModel], { name: 'myConfigurations' })
  getMyConfigurations(@CurrentUser() user: AuthUser) {
    return this.carService.findConfigurations(user.id);
  }

  @UseGuards(GqlAuthGuard)
  @Mutation(() => UserConfigurationModel, { name: 'shareConfiguration' })
  shareConfiguration(
    @Args('id', { type: () => ID }) id: string,
    @CurrentUser() user: AuthUser,
  ) {
    return this.carService.shareConfiguration(user.id, id);
  }
}
