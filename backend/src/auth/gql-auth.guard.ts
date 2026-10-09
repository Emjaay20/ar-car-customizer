import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { GqlExecutionContext } from '@nestjs/graphql';
import { verifyToken } from './token.js';

@Injectable()
export class GqlAuthGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const ctx = GqlExecutionContext.create(context);
    const req = ctx.getContext().req;
    const header = req?.headers?.authorization as string | undefined;
    const token = header?.startsWith('Bearer ') ? header.slice(7).trim() : '';

    if (!token) {
      throw new UnauthorizedException('Missing bearer token');
    }

    try {
      const payload = verifyToken(token);
      req.user = { id: payload.sub, email: payload.email };
      return true;
    } catch {
      throw new UnauthorizedException('Invalid or expired token');
    }
  }
}
