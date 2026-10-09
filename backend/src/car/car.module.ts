import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module.js';
import { CarResolver } from './car.resolver.js';
import { CarService } from './car.service.js';

@Module({
  imports: [AuthModule],
  providers: [CarService, CarResolver],
})
export class CarModule {}
