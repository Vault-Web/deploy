#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

git pull --ff-only

git submodule sync --recursive
git submodule update --init --recursive --remote

docker compose -f docker-compose.deploy.yml pull || true
docker compose -f docker-compose.deploy.yml up -d --build
