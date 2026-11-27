#!/usr/bin/env bash
# Shared by the host backup jobs. Never source the application's .env as shell code.
set -euo pipefail
umask 077

MNT="$(realpath -e "${BACKUP_MNT:-/mnt/backup5tb}")"
KEEP="${BACKUP_KEEP:-5}"
[[ "${KEEP}" =~ ^[1-9][0-9]*$ ]] || { echo 'BACKUP_KEEP must be positive' >&2; exit 2; }
exec 9>"${BACKUP_LOCK:-/run/lock/vaultweb-backups.lock}"
LOCK_WAIT="${BACKUP_LOCK_WAIT_SECONDS:-3600}"
[[ "${LOCK_WAIT}" =~ ^[1-9][0-9]*$ ]] || { echo 'BACKUP_LOCK_WAIT_SECONDS must be positive' >&2; exit 2; }
flock -w "${LOCK_WAIT}" 9 || { echo 'Timed out waiting for another backup or verification job' >&2; exit 1; }
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

protect_destination() {
  local base=$1 probe expected_uid
  [ ! -L "${base}" ] || { echo 'Backup directory must not be a symlink' >&2; exit 1; }
  mkdir -p "${base}"
  chmod 0700 "${base}"
  expected_uid="$(id -u)"
  [[ "$(stat -c '%a:%u' "${base}")" == "700:${expected_uid}" ]] || {
    echo 'Backup destination cannot enforce private owner-only permissions' >&2; exit 1;
  }
  # Probe filesystem semantics before writing a manifest or sensitive dump bytes.
  WORK="$(mktemp -d "${base}/.partial.XXXXXXXX")"
  probe="${WORK}/permissions"
  touch "${probe}"
  chmod 0640 "${probe}"
  [[ "$(stat -c %a "${probe}")" == 640 ]] || {
    echo 'Backup filesystem does not preserve POSIX permissions' >&2; exit 1;
  }
  chmod 0600 "${probe}"
  [[ "$(stat -c %a "${probe}")" == 600 ]] || {
    echo 'Backup filesystem cannot protect sensitive files' >&2; exit 1;
  }
  if [ "${expected_uid}" -eq 0 ]; then
    chown 65534:65534 "${probe}"
    [[ "$(stat -c '%u:%g' "${probe}")" == 65534:65534 ]] || {
      echo 'Backup filesystem does not preserve POSIX ownership' >&2; exit 1;
    }
  fi
  rm -rf -- "${WORK}"
  WORK=''
}

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
