import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import express from 'express';
import { join } from 'node:path';
import { AppModule } from './app.module.js';
import { loadEnvFile } from './load-env.js';

loadEnvFile();

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bodyParser: false,
  });
  app.useBodyParser('json', { limit: '8mb' });
  app.useBodyParser('urlencoded', { extended: true, limit: '8mb' });

  // Dev only: the phone is a different origin on the LAN. Do not ship origin:true.
  app.enableCors({
    origin: true,
    methods: 'GET,HEAD,PUT,PATCH,POST,DELETE',
    credentials: false,
  });

  app.use(express.static(join(process.cwd(), 'public')));

  const port = process.env.PORT ?? 3000;
  await app.listen(port, '0.0.0.0');
  console.log(`Backend running on http://0.0.0.0:${port}/graphql`);
  console.log(`Models served from http://0.0.0.0:${port}/models/`);
}

await bootstrap();
