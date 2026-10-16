FROM node:22-alpine AS builder

WORKDIR /app

RUN apk add --no-cache openssl libc6-compat

COPY package*.json ./
COPY prisma ./prisma/

RUN npm install

COPY . .

RUN npx prisma generate
RUN npm run build

# Runner stage
FROM node:22-alpine AS runner

WORKDIR /app

RUN apk add --no-cache openssl libc6-compat curl postgresql postgresql-contrib su-exec

ENV NODE_ENV=production
ENV PORT=3000
ENV JWT_SECRET="ar-car-secret-key-aetherhost-production"
ENV PATH="/app/node_modules/.bin:$PATH"

COPY package*.json ./
COPY prisma ./prisma/

# Install production dependencies and tsx for seed script
RUN npm install --omit=dev && npm install -g tsx

COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/node_modules/@prisma/client ./node_modules/@prisma/client
COPY public ./public
COPY src ./src
COPY docker-entrypoint.sh ./

RUN chmod +x docker-entrypoint.sh

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fs http://localhost:3000/health || exit 1

ENTRYPOINT ["./docker-entrypoint.sh"]
