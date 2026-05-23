#!/bin/sh
set -e

if [ -n "$VAULT_HABITS_URL" ]; then
  cat > /usr/share/nginx/html/runtime-config.local.js <<EOF
window.__VAULT_WEB_EXTERNAL_LINKS__ = [
  {
    name: "Habits",
    url: "${VAULT_HABITS_URL}",
    forwardVaultWebToken: true
  }
];
EOF
else
  echo "window.__VAULT_WEB_EXTERNAL_LINKS__ = [];" > /usr/share/nginx/html/runtime-config.local.js
fi

exec "$@"
