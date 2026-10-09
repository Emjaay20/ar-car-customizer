import { Field, ID, ObjectType } from '@nestjs/graphql';

@ObjectType()
export class AuthUserModel {
  @Field(() => ID)
  id: string;

  @Field()
  email: string;

  @Field()
  fullName: string;
}

@ObjectType()
export class AuthPayload {
  @Field()
  token: string;

  @Field(() => AuthUserModel)
  user: AuthUserModel;
}
