import { Args, Mutation, Resolver } from '@nestjs/graphql';
import { AuthService } from './auth.service.js';
import { LoginInput } from './dto/login.input.js';
import { RegisterInput } from './dto/register.input.js';
import { AuthPayload } from './models/auth-payload.model.js';

@Resolver()
export class AuthResolver {
  constructor(private readonly authService: AuthService) {}

  @Mutation(() => AuthPayload, { name: 'login' })
  login(@Args('input') input: LoginInput) {
    return this.authService.login(input.email, input.password);
  }

  @Mutation(() => AuthPayload, { name: 'register' })
  register(@Args('input') input: RegisterInput) {
    return this.authService.register(input.email, input.password, input.fullName);
  }
}
