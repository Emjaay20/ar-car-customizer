
import { Module } from '@nestjs/common';
import { AiWrapController } from './ai-wrap.controller.js';
import { AiWrapService } from './ai-wrap.service.js';
@Module({ controllers: [AiWrapController], providers: [AiWrapService], exports: [AiWrapService] })
export class AiWrapModule {}
