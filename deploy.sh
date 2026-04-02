#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Pulling latest..."
git pull

echo "==> Ensuring data directory..."
mkdir -p data
chown 65534:65534 data

echo "==> Building..."
docker compose build

echo "==> Restarting (migrations run automatically on start)..."
docker compose down
docker compose up -d

echo "==> Done! Running on port 46142"
