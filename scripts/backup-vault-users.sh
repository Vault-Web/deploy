#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-common.sh
source "${SCRIPT_DIR}/backup-common.sh"
BASE="${MNT}/vault-users-backups"
ACTION="${1:-backup}"
if [ "$#" -gt 1 ] || [[ "${ACTION}" != backup && "${ACTION}" != verify ]]; then
  echo "Usage: $0 [backup|verify]" >&2
  exit 2
fi
mkdir -p "${BASE}"

verify_snapshot() {
  local snapshot=$1
  [ -f "${snapshot}/COMPLETE" ]
  python3 "${SCRIPT_DIR}/backup-manifest.py" check "${snapshot}/data" "${snapshot}/manifest.json"
  RESTORE="$(mktemp -d "${RESTORE_TEST_ROOT:-/var/tmp}/vaultweb-restore.XXXXXXXX")"
  mkdir "${RESTORE}/data"
  # No --link-dest: the drill must read/copy bytes into independent storage.
  rsync -aH --numeric-ids "${snapshot}/data/" "${RESTORE}/data/"
  python3 "${SCRIPT_DIR}/backup-manifest.py" check "${RESTORE}/data" "${snapshot}/manifest.json"
  rm -rf -- "${RESTORE}"
  RESTORE=''
  echo "Restore verified: ${snapshot}"
}

if [ "${ACTION}" = verify ]; then
  SNAP="$(realpath -e "${BASE}/latest")"
  [[ "${SNAP}" == "${BASE}/backup-"* && "${SNAP}" != *'/../'* ]]
  verify_snapshot "${SNAP}"
  exit 0
fi

SRC="$(realpath -e "${VAULT_USERS_SOURCE:-/data/vault-users}")"
[[ "${SRC}" != / && "${SRC}/" != "${MNT}/"* && "${MNT}/" != "${SRC}/"* ]] || {
  echo 'Source and backup mount must be separate directories' >&2; exit 2;
}
FINAL="${BASE}/backup-$(date -u +%Y-%m-%d_%H-%M-%S)-$$"
WORK="$(mktemp -d "${BASE}/.partial.XXXXXXXX")"
mkdir "${WORK}/data"
# Capture expectations from the source, not from a possibly incomplete rsync result.
python3 "${SCRIPT_DIR}/backup-manifest.py" create "${SRC}" "${WORK}/manifest.json"
LINK=()
if [ -L "${BASE}/latest" ]; then
  PREV="$(realpath -e "${BASE}/latest")"
  [[ "${PREV}" == "${BASE}/"* ]] || { echo 'latest points outside backup directory' >&2; exit 1; }
  if [ -d "${PREV}/data" ] && [ -f "${PREV}/COMPLETE" ]; then
    LINK=("--link-dest=${PREV}/data")
  else
    [[ "$(basename "${PREV}")" != backup-* ]] || {
      echo 'latest points to an incomplete new-format snapshot' >&2; exit 1;
    }
    LINK=("--link-dest=${PREV}")
  fi
fi
rsync -aH --numeric-ids "${LINK[@]}" "${SRC}/" "${WORK}/data/"
python3 "${SCRIPT_DIR}/backup-manifest.py" check "${WORK}/data" "${WORK}/manifest.json"
touch "${WORK}/COMPLETE"
# A failed drill fails the backup service too, so success heartbeats are not sent.
verify_snapshot "${WORK}"
publish_snapshot "${BASE}" "${FINAL}"
echo "Verified backup published: ${FINAL}"
