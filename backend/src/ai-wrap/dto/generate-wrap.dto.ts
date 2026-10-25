
export class GenerateWrapDto {
  prompt: string;
  make?: string;
  panel?: string;
  finish?: string;
  maskBase64?: string;
  seed?: number;
}
export class GenerateWrapResponse {
  textureUrl: string;
  previewUrl: string;
  finish: string;
  prompt: string;
  make: string;
  generationId: string;
}
