import { BadRequestException } from '@nestjs/common';

const ALLOWED = new Set(['image/jpeg', 'image/png', 'image/webp']);
const MAX_BASE64_CHARS = 8_000_000;
const MAX_BYTES = 4_000_000;

export interface DecodedImage {
  base64: string;
  mimeType: string;
  byteLength: number;
}

export function decodeImage(imageBase64: string, mimeType?: string, maxBytes = MAX_BYTES): DecodedImage {
  let raw = imageBase64.trim().replace(/\s/g, '');
  let mime = mimeType?.trim().toLowerCase() || 'image/jpeg';
  const dataUrl = raw.match(/^data:(image\/[a-z0-9.+-]+);base64,(.+)$/i);
  if (dataUrl) {
    mime = dataUrl[1].toLowerCase();
    raw = dataUrl[2];
  }

  const maxChars = Math.max(MAX_BASE64_CHARS, Math.ceil((maxBytes * 4) / 3) + 64);
  if (!ALLOWED.has(mime)) {
    throw new BadRequestException('Image must be jpeg, png, or webp');
  }
  if (!raw || raw.length > maxChars) {
    throw new BadRequestException('Image is too large');
  }

  const bytes = Buffer.from(raw, 'base64');
  if (bytes.length === 0 || bytes.length > maxBytes) {
    throw new BadRequestException('Image is too large');
  }

  return { base64: raw, mimeType: mime, byteLength: bytes.length };
}
