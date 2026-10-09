import { afterEach, describe, expect, it } from 'vitest';
import { VisionClient, readContent } from './vision.client.js';

const originalKey = process.env.VISION_API_KEY;

afterEach(() => {
  if (originalKey === undefined) delete process.env.VISION_API_KEY;
  else process.env.VISION_API_KEY = originalKey;
});

describe('VisionClient', () => {
  it('does not call the network or invent a car when the key is missing', async () => {
    delete process.env.VISION_API_KEY;
    const client = new VisionClient(async () => {
      throw new Error('fetch should not be called');
    });

    const result = await client.identify({ base64: 'aaaa', mimeType: 'image/jpeg' });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.reason).toContain('VISION_API_KEY');
    }
  });

  it('parses a vision reply without logging the image', async () => {
    process.env.VISION_API_KEY = 'test-key';
    let sawImage = false;
    const client = new VisionClient(async (_url, init) => {
      const body = init?.body;
      sawImage = typeof body === 'string' && body.includes('data:image/jpeg;base64,aaaa');
      return new Response(
        JSON.stringify({
          choices: [
            {
              message: {
                content: '{"make":"Honda","model":"Civic","year":2018,"confidence":0.91}',
              },
            },
          ],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    });

    const result = await client.identify({ base64: 'aaaa', mimeType: 'image/jpeg' });
    expect(sawImage).toBe(true);
    expect(result).toEqual({
      ok: true,
      guess: { make: 'Honda', model: 'Civic', year: 2018, confidence: 0.91 },
    });
  });
});

describe('readContent', () => {
  it('joins array message parts', () => {
    expect(
      readContent({
        choices: [{ message: { content: [{ text: '{"make":"Honda"}' }] } }],
      }),
    ).toBe('{"make":"Honda"}');
  });
});
