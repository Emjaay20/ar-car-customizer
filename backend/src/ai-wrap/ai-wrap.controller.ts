
import { Controller, Post, Body, Get, Query } from '@nestjs/common';
import { AiWrapService } from './ai-wrap.service.js';
import { GenerateWrapDto } from './dto/generate-wrap.dto.js';

@Controller('api')
export class AiWrapController {
  constructor(private readonly aiWrapService: AiWrapService) {}

  @Post('generate-wrap')
  async generate(@Body() dto: GenerateWrapDto) {
    // dto: { prompt: "dragon sakura", make: "Toyota", panel: "body", finish: "ai_wrap" }
    return this.aiWrapService.generate(dto);
  }

  @Get('wraps/trending')
  async trending() {
    // Returns trending prompts from research (chameleon, forged, holographic)
    return {
      trending: [
        { prompt: 'chameleon lime grey twin color', finish: 'chameleon', count: 1240 },
        { prompt: 'forged carbon black gloss', finish: 'forged', count: 980 },
        { prompt: 'holographic pink yellow orange', finish: 'holographic', count: 870 },
        { prompt: 'dragon sakura porcelain', finish: 'ai_wrap', count: 760 },
        { prompt: 'crystal crackle candy red', finish: 'crystal', count: 650 },
        { prompt: 'great wave hokusai', finish: 'ai_wrap', count: 540 },
      ]
    };
  }
}
