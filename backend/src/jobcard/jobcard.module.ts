import { Module } from '@nestjs/common';
import { JobCardService } from './jobcard.service.js';
import { JobCardResolver } from './jobcard.resolver.js';
import { PrismaModule } from '../prisma/prisma.module.js';

@Module({
  imports: [PrismaModule],
  providers: [JobCardService, JobCardResolver],
  exports: [JobCardService],
})
export class JobCardModule {}
