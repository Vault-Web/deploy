#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${SCRIPT_DIR}/backup-common.sh"
ROOT_DIR="${DEPLOY_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
BASE="${MNT}/postgres-backups"
protect_destination "${BASE}"
FINAL="${BASE}/backup-$(date -u +%Y-%m-%d_%H-%M-%S)-$$"
WORK="$(mktemp -d "${BASE}/.partial.XXXXXXXX")"
mkdir "${WORK}/data"
# Compose parses .env itself; the password stays inside the existing db container.
# pg_dumpall covers both application databases and roles, with server-matched tools.
docker compose --project-directory "${ROOT_DIR}" -f "${ROOT_DIR}/docker-compose.deploy.yml" \
  exec -T db sh -eu -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dumpall -U "$POSTGRES_USER"' \
  | gzip >"${WORK}/data/cluster.sql.gz"
gzip -t "${WORK}/data/cluster.sql.gz"
python3 "${SCRIPT_DIR}/backup-manifest.py" create "${WORK}/data" "${WORK}/manifest.json"
touch "${WORK}/COMPLETE"
publish_snapshot "${BASE}" "${FINAL}"
echo "PostgreSQL cluster dump published: ${FINAL}"
