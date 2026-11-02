#!/usr/bin/env bash
set -euo pipefail
# Call this only after the backup and its verification have succeeded.
[[ -n "${HC_BACKUP_UUID:-}" ]] || exit 0
curl --fail --silent --show-error --max-time 10 "https://hc-ping.com/$HC_BACKUP_UUID" >/dev/null
