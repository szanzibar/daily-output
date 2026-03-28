#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Pulling latest..."
git pull

echo "==> Building..."
docker compose build

echo "==> Migrating database..."
docker compose run --rm sprachjournal /app/bin/migrate

echo "==> Restarting..."
docker compose down
docker compose up -d

echo "==> Done! Running on port 46142"
