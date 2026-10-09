import { UseGuards } from '@nestjs/common';
import { Args, Mutation, Resolver } from '@nestjs/graphql';
import { GqlAuthGuard } from '../auth/gql-auth.guard.js';
import { IdentifyVehicleInput } from './dto/identify-vehicle.input.js';
import { VehicleIdentificationModel } from './models/vehicle-identification.model.js';
import { VisionService } from './vision.service.js';

@Resolver()
export class VisionResolver {
  constructor(private readonly visionService: VisionService) {}

  @UseGuards(GqlAuthGuard)
  @Mutation(() => VehicleIdentificationModel)
  identifyVehicle(@Args('input') input: IdentifyVehicleInput) {
    return this.visionService.identify(input.imageBase64, input.mimeType);
  }
}
