import { createHmac, timingSafeEqual } from 'node:crypto';

export interface TokenPayload {
  sub: string;
  email: string;
  exp: number;
}

export function jwtSecret(): string {
  const secret = process.env.JWT_SECRET;
  if (secret) return secret;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET is required when NODE_ENV=production');
  }
  return 'dev-only-change-me';
}

export function signToken(
  payload: { sub: string; email: string },
  ttlSeconds = 60 * 60 * 24 * 7,
  secret = jwtSecret(),
): string {
  const body = Buffer.from(
    JSON.stringify({
      sub: payload.sub,
      email: payload.email,
      exp: Math.floor(Date.now() / 1000) + ttlSeconds,
    }),
  ).toString('base64url');
  const signature = createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${signature}`;
}

export function verifyToken(token: string, secret = jwtSecret()): TokenPayload {
  const [body, signature] = token.split('.');
  if (!body || !signature || token.split('.').length !== 2) {
    throw new Error('Malformed token');
  }

  const expected = createHmac('sha256', secret).update(body).digest('base64url');
  const actualBuf = Buffer.from(signature);
  const expectedBuf = Buffer.from(expected);
  if (
    actualBuf.length !== expectedBuf.length ||
    !timingSafeEqual(actualBuf, expectedBuf)
  ) {
    throw new Error('Bad signature');
  }

  const payload = JSON.parse(
    Buffer.from(body, 'base64url').toString('utf8'),
  ) as TokenPayload;
  if (!payload.sub || !payload.email || typeof payload.exp !== 'number') {
    throw new Error('Malformed token');
  }
  if (payload.exp < Math.floor(Date.now() / 1000)) {
    throw new Error('Token expired');
  }
  return payload;
}
