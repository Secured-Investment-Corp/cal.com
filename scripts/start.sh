#!/bin/sh
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

scripts/wait-for-it.sh ${DATABASE_HOST} -- echo "database is up"
# Create the database if it doesn't exist (needed on first deploy).
# Use DATABASE_DIRECT_URL (has sslmode=require) but connect to postgres db, not calcom.
DB_BASE="${DATABASE_DIRECT_URL%/*}"
psql "${DB_BASE}/postgres?sslmode=require" -c "CREATE DATABASE calcom;" 2>/dev/null || true
psql "${DB_BASE}/postgres?sslmode=require" -c "GRANT ALL PRIVILEGES ON DATABASE calcom TO calcom;" 2>/dev/null || true
npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
yarn start
