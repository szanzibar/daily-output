#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Pulling latest..."
git pull

echo "==> Building..."
docker compose build

echo "==> Restarting (migrations run automatically on start)..."
docker compose down
docker compose up -d

echo "==> Done! Running on port 4000 (or custom host port from docker-compose)"
