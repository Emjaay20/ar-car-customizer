#!/bin/sh
set -e

echo "=== AR Car Customizer Backend Starting ==="

# Check if we should use local embedded postgres
if [ -z "$DATABASE_URL" ] || echo "$DATABASE_URL" | grep -q -E "localhost|127.0.0.1"; then
  echo "Setting up local PostgreSQL database..."
  mkdir -p /run/postgresql /var/lib/postgresql/data
  chown -R postgres:postgres /run/postgresql /var/lib/postgresql/data

  if command -v su-exec >/dev/null 2>&1; then
    SU="su-exec postgres"
  elif command -v gosu >/dev/null 2>&1; then
    SU="gosu postgres"
  else
    SU="su -s /bin/sh postgres -c"
  fi

  if [ ! -d "/var/lib/postgresql/data/base" ]; then
    echo "Initializing new PostgreSQL cluster..."
    $SU initdb -D /var/lib/postgresql/data --auth=trust
    $SU pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses='127.0.0.1'" start
    $SU psql -U postgres -c "CREATE USER admin WITH SUPERUSER PASSWORD 'adminpassword';" || true
    $SU createdb -U postgres -O admin ar_car_customizer || true
  else
    echo "Starting existing PostgreSQL cluster..."
    $SU pg_ctl -D /var/lib/postgresql/data -o "-c listen_addresses='127.0.0.1'" start
  fi

  export DATABASE_URL="postgresql://admin:adminpassword@127.0.0.1:5432/ar_car_customizer?schema=public"
fi

export JWT_SECRET="${JWT_SECRET:-ar-car-secret-key-aetherhost-production}"

echo "Running Prisma migrations..."
npx prisma db push --accept-data-loss || true

echo "Seeding database with demo catalog..."
npx prisma db seed || tsx prisma/seed.ts || true

echo "Starting NestJS server on port ${PORT:-3000}..."
exec node dist/main.js
