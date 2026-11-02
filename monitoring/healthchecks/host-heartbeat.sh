#!/usr/bin/env bash
set -euo pipefail
# Optional healthchecks.io heartbeat. Missing UUID is intentionally a no-op.
[[ -n "${HC_HOST_UUID:-}" ]] || exit 0
curl --fail --silent --show-error --max-time 10 "https://hc-ping.com/$HC_HOST_UUID" >/dev/null
