import { Module } from '@nestjs/common';
import { GraphQLModule } from '@nestjs/graphql';
import { ApolloDriver, ApolloDriverConfig } from '@nestjs/apollo';
import { join } from 'node:path';
import { AppController } from './app.controller.js';
import { AppService } from './app.service.js';
import { AuthModule } from './auth/auth.module.js';
import { CarModule } from './car/car.module.js';
import { PrismaModule } from './prisma/prisma.module.js';
import { VisionModule } from './vision/vision.module.js';
import { InspectionModule } from './inspection/inspection.module.js';
import { JobCardModule } from './jobcard/jobcard.module.js';

@Module({
  imports: [
    GraphQLModule.forRoot<ApolloDriverConfig>({
      driver: ApolloDriver,
      autoSchemaFile: join(process.cwd(), 'src/schema.gql'),
      context: ({ req }: { req: unknown }) => ({ req }),
    }),
    PrismaModule,
    AuthModule,
    CarModule,
    VisionModule,
    InspectionModule,
    JobCardModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
