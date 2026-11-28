#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if [[ $# -gt 1 || ( $# -eq 1 && $1 != --browser ) ]]; then
  echo "Usage: $0 [--browser]" >&2
  exit 1
fi
if [[ ${1:-} == --browser ]]; then
  python3 -c 'import playwright' || { echo "Install Playwright for --browser." >&2; exit 1; }
fi

# Bind mounts must resolve on this machine and no test should target a remote daemon.
if [[ -n ${DOCKER_CONTEXT:-} || -z ${DOCKER_HOST:-} ]]; then
  docker_host=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
else
  docker_host=$DOCKER_HOST
fi
if [[ $docker_host != unix://* ]]; then
  echo "Compose smoke requires a local Docker socket." >&2
  exit 1
fi

for service in vault-web cloud-page server-docs vault-habits; do
  if [[ ! -f services/$service/.git && ! -d services/$service/.git ]]; then
    echo "Initialize the service submodules before running the Compose smoke test." >&2
    exit 1
  fi
done

fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/vault-compose-smoke.XXXXXXXX")
project="vault-smoke-${fixture_dir##*.}"
project=${project,,}
compose=(
  docker compose --project-name "$project" --env-file /dev/null
  -f docker-compose.deploy.yml -f scripts/tests/compose-smoke.yml
)
cleanup() {
  local status=$?
  if (( status != 0 )); then
    "${compose[@]}" ps -a >&2 || true
    "${compose[@]}" logs --tail 60 db vault-web-backend cloud-page-backend server-docs vault-habits vaultwarden >&2 || true
  fi
  if ! "${compose[@]}" down --volumes --remove-orphans --rmi local; then
    status=1
  fi
  rm -rf -- "$fixture_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The tracked base file is composed with fixed test-only configuration. Do not
# load the checkout's .env or inherit an operator-selected Compose profile.
unset COMPOSE_PROFILES
export FRONTEND_PORT=127.0.0.1:80 POSTGRES_PORT=127.0.0.1:5432 PGADMIN_PORT=127.0.0.1:81
export POSTGRES_USER=vaultsmoke POSTGRES_PASSWORD=local-smoke-db-password POSTGRES_DEFAULT_DB=postgres
export POSTGRES_DB_VAULT=vault_db POSTGRES_DB_CLOUD=cloud_db
export PGADMIN_DEFAULT_EMAIL=pgadmin@example.invalid PGADMIN_DEFAULT_PASSWORD=local-smoke-pgadmin-password
export JWT_SECRET=local-smoke-access-signing-key-2026-fixture-only
export JWT_REFRESH_SECRET=local-smoke-refresh-key-2026-fixture-only
export JWT_MEDIA_SECRET=local-smoke-media-signing-key-2026-fixture-only
export VAULT_WEB_FORWARD_HEADERS_STRATEGY=none VAULT_WEB_INTERNAL_PROXIES='(?!)'
export VAULT_WEB_FLYWAY_BASELINE_ON_MIGRATE=false
export CLOUD_HOST_ROOT="$fixture_dir/cloud" SHARE_HOST=share.smoke.invalid
export CLOUD_PUBLIC_BASE_URL="http://$SHARE_HOST"
export VAULTWARDEN_PUBLIC_URL=http://vaultwarden.smoke.invalid VAULTWARDEN_DATA_DIR="$fixture_dir/vaultwarden"
export VAULTWARDEN_SIGNUPS_ALLOWED=false VAULTWARDEN_INVITATIONS_ALLOWED=false VAULTWARDEN_ADMIN_TOKEN=
export VAULT_HABITS_NICEGUI_SECRET=local-smoke-habits-secret
export VAULT_HABITS_LOGIN_URL=http://vault.smoke.invalid/login VAULT_WEB_HOME_URL=http://vault.smoke.invalid
export VAULT_HABITS_URL=http://habits.smoke.invalid/vault-web-login VAULT_HABITS_USER_EMAIL_DOMAIN=smoke.invalid
mkdir -p "$CLOUD_HOST_ROOT/smoke"
if [[ ${1:-} == --browser ]]; then
  # Keep the bind-mounted fixture directories writable for host-side cleanup.
  mkdir -p "$CLOUD_HOST_ROOT/smoke/preview-fixtures"
fi

"${compose[@]}" up -d --build --wait --wait-timeout 180

run_check() {
  local stage=$1
  shift
  local frontend_address
  frontend_address=$("${compose[@]}" port frontend 80)
  if [[ ! $frontend_address =~ ^127\.0\.0\.1:([0-9]+)$ ]]; then
    echo "Unexpected smoke frontend binding." >&2
    return 1
  fi
  python3 scripts/tests/compose_smoke.py "${BASH_REMATCH[1]}" "$stage" "$@"
}

run_check ready
"${compose[@]}" exec -T db psql -X --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB_CLOUD" <<'SQL'
INSERT INTO users (id, username, root_folder_path)
VALUES ('deploy-smoke-cloud-user', 'deploy-smoke', '/host-cloud/smoke');
SQL
run_check write "$@"

# Replace the app containers to check that data survives container replacement,
# including files in the core uploads volume and the Cloud bind mount.
"${compose[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 180 \
  vault-web-backend cloud-page-backend frontend
run_check verify
