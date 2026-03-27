#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/3] Syncing submodule remotes..."
git submodule sync --recursive

echo "[2/3] Initializing/updating submodules..."
git submodule update --init --recursive --remote

echo "[3/3] Preparing environment file..."
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example"
else
  echo ".env already exists, keeping current values"
fi

echo "Bootstrap complete. Next: edit .env, then run ./scripts/deploy-up.sh"
