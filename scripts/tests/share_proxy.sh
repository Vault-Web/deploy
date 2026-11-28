#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
root=$PWD
image=$(awk '$1 == "FROM" && $2 ~ /^nginx:/ {print $2}' docker/frontend.Dockerfile)
: "${image:?Frontend nginx image not found}"
fixture=$(mktemp -d)
network="vault-share-smoke-${fixture##*.}"
upstream="$network-upstream"
frontend="$network-frontend"

cleanup() {
  docker rm -f "$frontend" "$upstream" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -f -- "$fixture/default.conf"
  rmdir -- "$fixture"
}
trap cleanup EXIT

cat > "$fixture/default.conf" <<'NGINX'
server {
    listen 80;
    listen 8080;
    listen 8090;
    location = /api/public/secure-sends/fixture/view {
        if ($http_x_secure_send_password != "test-only") { return 401; }
        default_type application/pdf;
        return 200 '%PDF-1.7';
    }
    location = /api/public/secure-sends/expired/view { return 404; }
    location = /uploads/profile-pictures/fixture.png {
        default_type image/png;
        return 200 'fixture-image';
    }
    location / { return 200 'private-upstream'; }
}
NGINX

docker network create "$network" >/dev/null
docker run -d --name "$upstream" --network "$network" \
  --network-alias cloud-page-backend --network-alias vault-web-backend \
  --network-alias server-docs \
  -v "$fixture/default.conf:/etc/nginx/conf.d/default.conf:ro" "$image" >/dev/null
docker run -d --name "$frontend" --network "$network" \
  -p 127.0.0.1::80 -e SHARE_HOST=share.invalid \
  -v "$root/docker/nginx/default.conf:/etc/nginx/templates/default.conf.template:ro" \
  -v "$root/docker/nginx/entrypoint.sh:/vault-entrypoint.sh:ro" \
  --entrypoint /bin/sh "$image" /vault-entrypoint.sh nginx -g 'daemon off;' >/dev/null

base_url="http://$(docker port "$frontend" 80/tcp)"
for attempt in {1..20}; do
  if curl -fsS -H 'Host: share.invalid' "$base_url/s/fixture" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = 20 ]; then
    docker logs "$frontend" >&2
    exit 1
  fi
  sleep 1
done

status() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
view="$base_url/cloud-api/public/secure-sends/fixture/view"
[ "$(status -H 'Host: share.invalid' "$view")" = 401 ]
[ "$(curl -fsS -H 'Host: share.invalid' -H 'X-Secure-Send-Password: test-only' "$view")" = '%PDF-1.7' ]
[ "$(status -H 'Host: share.invalid' "$base_url/cloud-api/public/secure-sends/expired/view")" = 404 ]
[ "$(status -H 'Host: share.invalid' "$base_url/api/auth/users")" = 404 ]
[ "$(status -H 'Host: share.invalid' "$base_url/uploads/profile-pictures/fixture.png")" = 404 ]
[ "$(curl -fsS -H 'Host: vault.invalid' "$base_url/uploads/profile-pictures/fixture.png")" = 'fixture-image' ]
echo 'Share proxy routes protected previews and keeps portal routes private'
