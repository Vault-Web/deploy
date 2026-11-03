#!/usr/bin/env bash
set -euo pipefail
# Called by backup-vault-users.service only after the backup command succeeds.
if [[ -z "${HC_BACKUP_UUID:-}" ]]; then
  echo "HC_BACKUP_UUID is unset; skipping optional backup heartbeat." >&2
  exit 0
fi
curl --fail --silent --show-error --max-time 10 "https://hc-ping.com/$HC_BACKUP_UUID" >/dev/null
echo "Backup heartbeat sent to healthchecks.io."
