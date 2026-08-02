#!/bin/sh
set -e

# The public share host differs per deployment, so the nginx config ships as a
# template. Substitute that one name only: nginx's own $variables must survive.
# Unset, the share block answers for a name nothing resolves to, and the
# default_server keeps serving everything as before.
: "${SHARE_HOST:=share.invalid}"
export SHARE_HOST
envsubst '${SHARE_HOST}' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf

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
