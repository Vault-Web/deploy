# Vault Web Deploy

Deployment repository for the Vault Web ecosystem.  
Use this repo to run the full stack with Docker Compose (including submodules), or DB-only mode.

## What Is Included

- [vault-web](https://github.com/Vault-Web/vault-web) (submodule in services/vault-web)
- [cloud-page](https://github.com/Vault-Web/cloud-page) (submodule in services/cloud-page)
- [password-manager](https://github.com/Vault-Web/password-manager) (submodule in services/password-manager)
- [server-docs](https://github.com/Vault-Web/server-docs) (submodule in services/server-docs)

Compose files:
- docker-compose.deploy.yml (full stack)
- docker-compose.db.yml (DB + pgAdmin only)

Scripts:
- scripts/bootstrap.sh
- scripts/deploy-up.sh
- scripts/deploy-down.sh
- scripts/deploy-logs.sh
- scripts/deploy-pull.sh

## Prerequisites

- Docker Engine + Docker Compose plugin installed
- `openssl` installed
- Free host ports:
  - FRONTEND_PORT (default 80)
  - PGADMIN_PORT (default 8081)
  - POSTGRES_PORT (default 5433, optional external DB access)

## First-Time Deployment

1. Clone repository with submodules:
```bash
git clone --recurse-submodules https://github.com/Vault-Web/deploy.git
cd deploy
```

Alternative (if already cloned without submodules):
```bash
git submodule update --init --recursive
```

2. Bootstrap (submodules + `.env` creation):
```bash
./scripts/bootstrap.sh
```

3. Generate secrets:
```bash
openssl rand -hex 64
openssl rand -base64 48
openssl rand -base64 32
```

4. Edit `.env` and replace required values (see variable table below).

5. Start full stack:
```bash
./scripts/deploy-up.sh
```

6. Verify running containers:
```bash
docker compose -f docker-compose.deploy.yml ps
```

## .env Variables

- FRONTEND_PORT: Host port for the web app (nginx frontend container).
- PGADMIN_PORT: Host port for pgAdmin UI.
- POSTGRES_PORT: Host port mapped to PostgreSQL (5432 in container).
- CLOUD_HOST_ROOT: Absolute host path mounted into cloud service as `/host-cloud`.

- POSTGRES_USER: PostgreSQL username.
- POSTGRES_PASSWORD: PostgreSQL password.
- POSTGRES_DEFAULT_DB: Default DB for initial connect/admin.
- POSTGRES_DB_VAULT: DB name used by Vault Web backend.
- POSTGRES_DB_CLOUD: DB name used by Cloud Page backend.
- POSTGRES_DB_PASSWORD_MANAGER: DB name used by Password Manager backend.

- PGADMIN_DEFAULT_EMAIL: pgAdmin admin login email (must be valid format).
- PGADMIN_DEFAULT_PASSWORD: pgAdmin admin login password.

- JWT_SECRET: JWT signing secret for core services.
- JWT_REFRESH_SECRET: Refresh-token signing secret.
- PASSWORD_MANAGER_ENCRYPTION_SECRET: Base64 AES key used by password-manager encryption.

Important:
- .env.example contains sample values only.
- Replace all sensitive values before any real deployment.

## Service and URL Map

Public URLs (browser):
- App: `http://localhost:<FRONTEND_PORT>/`
- pgAdmin: `http://localhost:<PGADMIN_PORT>/`
- Docs: `http://localhost:<FRONTEND_PORT>/docs/`

API via frontend reverse proxy:
- Core API: `http://localhost:<FRONTEND_PORT>/api/...`
- Cloud API: `http://localhost:<FRONTEND_PORT>/cloud-api/...`
- Password API: `http://localhost:<FRONTEND_PORT>/password-api/...`

Internal container ports:
- vault-web-backend: 8080
- cloud-page-backend: 8090
- password-manager-backend: 8091
- db (postgres): 5432
- pgadmin: 80

## Cloud Storage Path Behavior

CLOUD_HOST_ROOT is mounted into cloud-page-backend as `/host-cloud`.

That means:
- Host path in `.env`: `/home/deniz-altunkapan/Downloads/TEMP`
- Container path to use in DB: `/host-cloud`

For user root folders in `cloud_db.users.root_folder_path`, use `/host-cloud/...`, not host paths like `/home/...`.

Example SQL:
```sql
UPDATE users
SET root_folder_path = '/host-cloud'
WHERE username = 'deniz';
```

## Operations

Start / recreate full stack:
```bash
./scripts/deploy-up.sh
```

Stop full stack:
```bash
./scripts/deploy-down.sh
```

Follow logs (all services):
```bash
./scripts/deploy-logs.sh
```

Show status:
```bash
docker compose -f docker-compose.deploy.yml ps
```

Logs for one service:
```bash
docker compose -f docker-compose.deploy.yml logs -f cloud-page-backend
```

Restart one service:
```bash
docker compose -f docker-compose.deploy.yml up -d --build --force-recreate cloud-page-backend
```

Update code + submodules + rebuild:
```bash
./scripts/deploy-pull.sh
```

Manual update alternative (explicit recursive pull/update):
```bash
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive --remote
docker compose -f docker-compose.deploy.yml up -d --build --remove-orphans
```

## Tear Down and Cleanup

Stop and remove containers + network (keep volumes/data):
```bash
docker compose -f docker-compose.deploy.yml down --remove-orphans
```

Stop and remove everything including volumes (deletes DB data):
```bash
docker compose -f docker-compose.deploy.yml down -v --remove-orphans
```

## DB-Only Mode

Run only PostgreSQL + pgAdmin:
```bash
docker compose -f docker-compose.db.yml up -d
```

Stop DB-only mode:
```bash
docker compose -f docker-compose.db.yml down
```

## Security Notes

- `.env` is git-ignored; never commit real secrets.
- Restrict/firewall POSTGRES_PORT if external DB access is not needed.
- Internal Docker traffic is plain HTTP by design; terminate TLS at your edge proxy/load balancer.
- Rotate secrets per environment and do not reuse sample defaults.
