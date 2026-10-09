import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module.js';
import { VisionClient } from './vision.client.js';
import { VisionResolver } from './vision.resolver.js';
import { VisionService } from './vision.service.js';

@Module({
  imports: [AuthModule],
  providers: [VisionClient, VisionService, VisionResolver],
})
export class VisionModule {}
