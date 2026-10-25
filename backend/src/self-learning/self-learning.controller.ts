
import { Controller, Post, Body, Get, Param } from '@nestjs/common';
import { SelfLearningService } from './self-learning.service.js';

@Controller('api/self-learning')
export class SelfLearningController {
  constructor(private readonly selfLearningService: SelfLearningService) {}

  @Post('upload')
  async upload(
    @Body() body: { make: string; imageBase64: string; maskBase64?: string; metadata?: any }
  ) {
    // Flutter sends low-confidence frames here when on WiFi
    return this.selfLearningService.uploadSample(body.make, body.imageBase64, body.maskBase64 || '', body.metadata || {});
  }

  @Get('stats')
  async stats() {
    return this.selfLearningService.getStats();
  }

  @Get('dataset/:make')
  async dataset(@Param('make') make: string) {
    return this.selfLearningService.getMakeDataset(make);
  }

  @Post('models/push')
  async pushModel(@Body() body: { modelUrl: string; version: string }) {
    // Called by ml training pipeline after retraining
    return this.selfLearningService.pushNewModel(body.modelUrl, body.version);
  }
}
