#!/usr/bin/env bash
# Shared by the host backup jobs. Never source the application's .env as shell code.
set -euo pipefail
umask 077

MNT="$(realpath -e "${BACKUP_MNT:-/mnt/backup5tb}")"
KEEP="${BACKUP_KEEP:-5}"
[[ "${KEEP}" =~ ^[1-9][0-9]*$ ]] || { echo 'BACKUP_KEEP must be positive' >&2; exit 2; }
exec 9>"${BACKUP_LOCK:-/run/lock/vaultweb-backups.lock}"
flock -n 9 || { echo 'Another backup or verification job is running' >&2; exit 1; }
MOUNTED=false
WORK=''
RESTORE=''
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "${WORK}" ]; then rm -rf -- "${WORK}" || status=1; fi
  if [ -n "${RESTORE}" ]; then rm -rf -- "${RESTORE}" || status=1; fi
  if [ "${MOUNTED}" = true ]; then
    sync || status=1
    umount "${MNT}" || status=1
  fi
  if [ "${status}" -ne 0 ]; then echo 'Backup/restore verification FAILED; see preceding error' >&2; fi
  exit "${status}"
}
trap cleanup EXIT
if ! mountpoint -q "${MNT}"; then
  mount "${MNT}"
  MOUNTED=true
fi
# Refuse to write onto the host filesystem if the backup disk is absent.
mountpoint -q "${MNT}"

publish_snapshot() {
  local base=$1 final=$2
  mv -- "${WORK}" "${final}"
  WORK=''
  ln -s "$(basename "${final}")" "${base}/.latest-$$"
  mv -Tf -- "${base}/.latest-$$" "${base}/latest"
  # Only prune completed snapshots created by these scripts; retain legacy backups.
  local old index=0
  while IFS= read -r old; do
    index=$((index + 1))
    if [ "${index}" -gt "${KEEP}" ] && [ -f "${base}/${old}/COMPLETE" ]; then
      rm -rf -- "${base:?}/${old}"
    fi
  done < <(find "${base}" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' -printf '%f\n' | sort -r)
}
