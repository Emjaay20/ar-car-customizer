import {
  BadRequestException,
  ConflictException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service.js';
import { hashPassword, verifyPassword } from './password.js';
import { signToken } from './token.js';
import { AuthPayload } from './models/auth-payload.model.js';

@Injectable()
export class AuthService {
  constructor(private readonly prisma: PrismaService) {}

  async login(email: string, password: string): Promise<AuthPayload> {
    const normalized = email.trim().toLowerCase();
    if (!normalized || !password) {
      throw new UnauthorizedException('Invalid email or password');
    }

    const user = await this.prisma.user.findUnique({
      where: { email: normalized },
    });
    if (!user || !(await verifyPassword(password, user.passwordHash))) {
      throw new UnauthorizedException('Invalid email or password');
    }

    return this.payload(user);
  }

  async register(email: string, password: string, fullName: string): Promise<AuthPayload> {
    const normalized = email.trim().toLowerCase();
    const name = fullName.trim();
    if (!normalized.includes('@') || !normalized.includes('.')) {
      throw new BadRequestException('Enter a valid email');
    }
    if (password.length < 8) {
      throw new BadRequestException('Password must be at least 8 characters');
    }
    if (name.length < 2 || name.length > 80) {
      throw new BadRequestException('Enter your name');
    }

    try {
      const user = await this.prisma.user.create({
        data: {
          email: normalized,
          passwordHash: await hashPassword(password),
          fullName: name,
        },
      });
      return this.payload(user);
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new ConflictException('Email already registered');
      }
      throw error;
    }
  }

  private payload(user: { id: string; email: string; fullName: string }): AuthPayload {
    return {
      token: signToken({ sub: user.id, email: user.email }),
      user: {
        id: user.id,
        email: user.email,
        fullName: user.fullName,
      },
    };
  }
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: string }).code === 'P2002'
  );
}
