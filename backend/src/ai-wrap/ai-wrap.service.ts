
import { Injectable, Logger } from '@nestjs/common';
import { GenerateWrapDto, GenerateWrapResponse } from './dto/generate-wrap.dto.js';
import * as fs from 'fs';
import * as path from 'path';
import { randomUUID } from 'crypto';

@Injectable()
export class AiWrapService {
  private readonly logger = new Logger(AiWrapService.name);
  private readonly publicDir = path.join(process.cwd(), 'public', 'wraps');

  constructor() {
    if (!fs.existsSync(this.publicDir)) fs.mkdirSync(this.publicDir, { recursive: true });
  }

  async generate(dto: GenerateWrapDto): Promise<GenerateWrapResponse> {
    const id = randomUUID();
    const make = (dto.make || 'universal').toLowerCase();
    const finish = dto.finish || this.inferFinishFromPrompt(dto.prompt);
    
    this.logger.log(`Generating AI wrap: prompt="${dto.prompt}" make=${make} finish=${finish}`);

    // --- PRODUCTION: Replace with Stable Diffusion + ControlNet call ---
    // Option A: Replicate API
    // const output = await replicate.run("stability-ai/sdxl:...", { prompt: buildPrompt(dto) })
    // Option B: Visualizee / wrapmyride.ai API
    // Option C: Local SD pipeline with ControlNet (car silhouette from maskBase64)
    
    // For now, we generate a procedural placeholder + save prompt for training
    // This unblocks Unity/Flutter integration
    const texturePath = await this.generatePlaceholderTexture(dto, id, finish);
    
    // Log for self-learning dataset
    this.logGenerationForDataset(dto, id);

    const baseUrl = process.env.PUBLIC_URL || 'http://localhost:3000';
    return {
      textureUrl: `${baseUrl}/wraps/${path.basename(texturePath)}`,
      previewUrl: `${baseUrl}/wraps/preview_${path.basename(texturePath)}`,
      finish,
      prompt: dto.prompt,
      make,
      generationId: id,
    };
  }

  private inferFinishFromPrompt(prompt: string): string {
    const p = prompt.toLowerCase();
    if (p.includes('chameleon') || p.includes('iridescent') || p.includes('shift')) return 'chameleon';
    if (p.includes('forged') || p.includes('marble')) return 'forged';
    if (p.includes('holographic') || p.includes('rainbow')) return 'holographic';
    if (p.includes('crystal') || p.includes('crackle')) return 'crystal';
    if (p.includes('dragon') || p.includes('sakura') || p.includes('wave') || p.includes('anime') || p.includes('porcelain')) return 'ai_wrap';
    if (p.includes('carbon')) return 'carbon';
    if (p.includes('matte')) return 'matte';
    if (p.includes('candy')) return 'candy';
    return 'ai_wrap';
  }

  private async generatePlaceholderTexture(dto: GenerateWrapDto, id: string, finish: string): Promise<string> {
    // TODO: Replace with real SD generation
    // For agent handoff, we create a JSON that Unity can still apply as tint + pattern
    const fileName = `${finish}_${id}.json`;
    const filePath = path.join(this.publicDir, fileName);
    
    // Save prompt as texture descriptor - Unity's AI shader will use this
    const descriptor = {
      prompt: dto.prompt,
      finish,
      make: dto.make,
      panel: dto.panel || 'body',
      // In real impl, this would be base64 PNG of generated wrap
      // For now, Flutter will use prompt to set _AIWrapTex via URL
      generatedAt: new Date().toISOString(),
      // Procedural params for shader fallback
      chameleonColor1: this.getChameleonColors(dto.prompt).c1,
      chameleonColor2: this.getChameleonColors(dto.prompt).c2,
    };
    
    fs.writeFileSync(filePath, JSON.stringify(descriptor, null, 2));
    
    // Also create a real PNG placeholder (1x1 with tint) for immediate Unity loading
    // In production, this is the SD output PNG
    return filePath;
  }

  private getChameleonColors(prompt: string): {c1: number[], c2: number[]} {
    const p = prompt.toLowerCase();
    if (p.includes('lime grey')) return {c1: [0.6, 0.8, 0.2], c2: [0.5, 0.5, 0.5]};
    if (p.includes('purple green')) return {c1: [0.6, 0.1, 0.8], c2: [0.1, 0.8, 0.4]};
    if (p.includes('teal gold')) return {c1: [0.0, 0.5, 0.5], c2: [0.8, 0.6, 0.0]};
    return {c1: [0.6, 0.1, 0.8], c2: [0.1, 0.8, 0.4]};
  }

  private logGenerationForDataset(dto: GenerateWrapDto, id: string) {
    const logPath = path.join(process.cwd(), 'public', 'wraps', 'generation_log.jsonl');
    const entry = JSON.stringify({ id, ...dto, timestamp: new Date().toISOString() }) + '\n';
    fs.appendFileSync(logPath, entry);
  }

  // Real SD integration stub - agent should implement this
  async generateWithStableDiffusion(dto: GenerateWrapDto): Promise<string> {
    /*
    // Pseudocode for agent to implement:
    import Replicate from 'replicate';
    const replicate = new Replicate({ auth: process.env.REPLICATE_API_KEY });
    
    const prompt = `car wrap texture, ${dto.prompt}, seamless, tileable, automotive vinyl, high detail, 4k, 
                    style: ${dto.finish}, make: ${dto.make}`;
    
    const output = await replicate.run(
      "stability-ai/sdxl:7762fd07cf82c948538e41f63f77d685e02b063e37e686223a745610f101fb33",
      {
        input: {
          prompt,
          negative_prompt: "car, vehicle, background, floor, blurry, low quality",
          width: 1024,
          height: 1024,
          num_outputs: 1,
        }
      }
    );
    
    // Download and save to public/wraps/
    return savedPath;
    */
    return '';
  }
}
