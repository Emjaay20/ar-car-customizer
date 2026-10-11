import { Injectable, Optional } from '@nestjs/common';
import { parseVehicleJson, type VehicleGuess } from './vehicle-id.js';

export type VisionCall =
  | { ok: true; guess: VehicleGuess }
  | { ok: false; reason: string };

const PROMPT =
  'Identify the vehicle in this photo. Reply with JSON only, no markdown: ' +
  '{"make":"","model":"","year":0,"confidence":0}. ' +
  'year is a four-digit number. confidence is 0 to 1. ' +
  'If you cannot see a specific make and model, use empty strings and confidence 0. Do not guess.';

@Injectable()
export class VisionClient {
  constructor(@Optional() private readonly fetchImpl: typeof fetch = fetch) {}

  async identify(image: { base64: string; mimeType: string }): Promise<VisionCall> {
    const apiKey = process.env.VISION_API_KEY?.trim();
    if (!apiKey) {
      return {
        ok: false,
        reason: 'VISION_API_KEY is not set. Please add your Groq API key to .env.',
      };
    }

    const url = process.env.VISION_API_URL?.trim() || 'https://api.groq.com/openai/v1/chat/completions';
    const model = process.env.VISION_MODEL?.trim() || 'meta-llama/llama-4-scout-17b-16e-instruct';

    let response: Response;
    try {
      response = await this.fetchImpl(url, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model,
          temperature: 0,
          max_tokens: 200,
          messages: [
            {
              role: 'user',
              content: [
                { type: 'text', text: PROMPT },
                {
                  type: 'image_url',
                  image_url: { url: `data:${image.mimeType};base64,${image.base64}` },
                },
              ],
            },
          ],
        }),
        signal: AbortSignal.timeout(20_000),
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : 'request failed';
      return { ok: false, reason: `Vision request failed: ${message}` };
    }

    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      return {
        ok: false,
        reason: `Vision request failed (${response.status}): ${detail.slice(0, 180)}`,
      };
    }

    let payload: unknown;
    try {
      payload = await response.json();
    } catch {
      return { ok: false, reason: 'Vision response was not JSON' };
    }

    const content = readContent(payload);
    if (!content) {
      return { ok: false, reason: 'Vision response had no message' };
    }

    const guess = parseVehicleJson(content);
    if (!guess) {
      return { ok: false, reason: 'Vision model did not return a vehicle' };
    }
    return { ok: true, guess };
  }
}

export function readContent(payload: unknown): string | null {
  if (!payload || typeof payload !== 'object') return null;
  const choices = (payload as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || choices.length === 0) return null;
  const message = (choices[0] as { message?: { content?: unknown } }).message;
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return null;

  return content
    .map((part) => {
      if (!part || typeof part !== 'object' || !('text' in part)) return '';
      return String((part as { text: unknown }).text);
    })
    .join('');
}
