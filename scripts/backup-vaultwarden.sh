#!/usr/bin/env bash
set -euo pipefail

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

SRC="${VAULTWARDEN_DATA_DIR:-/data/vaultwarden}/"
MNT="${BACKUP_MNT:-/mnt/backup5tb}"
DST_BASE="${MNT}/vaultwarden-backups"
TS="$(date +%F_%H-%M-%S)"
DST="${DST_BASE}/${TS}"
LATEST="${DST_BASE}/latest"
KEEP="${VAULTWARDEN_BACKUP_KEEP:-5}"
WAS_RUNNING=false

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

mountpoint -q "${MNT}" || mount "${MNT}"
mkdir -p "${DST_BASE}"

if compose ps --status running --services | grep -Fxq vaultwarden; then
  WAS_RUNNING=true
  compose stop vaultwarden >/dev/null
fi

restart_if_needed() {
  if [ "${WAS_RUNNING}" = true ]; then
    compose up -d vaultwarden >/dev/null
  fi
}
trap restart_if_needed EXIT

if [ -L "${LATEST}" ] && [ -d "$(readlink -f "${LATEST}")" ]; then
  PREV="$(readlink -f "${LATEST}")"
  rsync -aH --delete --numeric-ids --link-dest="${PREV}" "${SRC}" "${DST}/"
else
  rsync -aH --delete --numeric-ids "${SRC}" "${DST}/"
fi

ln -sfn "${DST}" "${LATEST}"

find "${DST_BASE}" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' \
  | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -rf "${DST_BASE}/${old}"
  done

echo "Vaultwarden backup written to ${DST}"
