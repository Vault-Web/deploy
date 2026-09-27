#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /mnt/backup5tb/vaultwarden-backups/<snapshot|latest>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/../docker-compose.deploy.yml" ]; then
  ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  ROOT_DIR="${DEPLOY_DIR:-/opt/deploy}"
fi
ENV_FILE="${ROOT_DIR}/.env"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.deploy.yml"

if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

SNAP="$(readlink -f "$1")"
DST="${VAULTWARDEN_DATA_DIR:-/data/vaultwarden}/"

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

if [ ! -d "${SNAP}" ]; then
  echo "Snapshot not found: ${SNAP}" >&2
  exit 1
fi

if compose ps --status running --services | grep -Fxq vaultwarden; then
  echo "Vaultwarden is running. Stop it before restoring:" >&2
  echo "  docker compose -f ${COMPOSE_FILE} stop vaultwarden" >&2
  exit 1
fi

mkdir -p "${DST}"
rsync -aH --delete --numeric-ids "${SNAP}/" "${DST}"
echo "Vaultwarden data restored from ${SNAP} to ${DST}"
