import { Module } from '@nestjs/common';
import { InspectionService } from './inspection.service.js';
import { InspectionResolver } from './inspection.resolver.js';
import { PrismaModule } from '../prisma/prisma.module.js';

@Module({
  imports: [PrismaModule],
  providers: [InspectionService, InspectionResolver],
  exports: [InspectionService],
})
export class InspectionModule {}
