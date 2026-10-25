
import { Module } from '@nestjs/common';
import { SelfLearningController } from './self-learning.controller.js';
import { SelfLearningService } from './self-learning.service.js';

@Module({
  controllers: [SelfLearningController],
  providers: [SelfLearningService],
})
export class SelfLearningModule {}
