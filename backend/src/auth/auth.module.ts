import { Module } from '@nestjs/common';
import { AuthResolver } from './auth.resolver.js';
import { AuthService } from './auth.service.js';
import { GqlAuthGuard } from './gql-auth.guard.js';

@Module({
  providers: [AuthService, AuthResolver, GqlAuthGuard],
  exports: [AuthService, GqlAuthGuard],
})
export class AuthModule {}
