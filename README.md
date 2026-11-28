# Vault Web Deploy

Deployment repository for Vault Web with Docker Compose and service submodules.

> Security note: all domains, IPs, usernames, UUIDs, and secrets in this README are examples and must be replaced for real deployments.

## Included Services

- [`services/vault-web`](./services/vault-web)
- [`services/cloud-page`](./services/cloud-page)
- [`services/server-docs`](./services/server-docs)

Main compose files:

- [`docker-compose.deploy.yml`](./docker-compose.deploy.yml) (full stack)
- [`docker-compose.db.yml`](./docker-compose.db.yml) (DB only)

## Production Architecture (Current)

This repository is deployed with this security model:

1. App containers run internally (HTTP only).
2. Frontend binds to localhost only (`127.0.0.1:8080`) and is not directly public.
3. Headscale Caddy (`/opt/headscale`) terminates public TLS on `443`.
4. `vpn.example.com` stays public (required for Headscale/Tailscale control-plane).
5. `vault.example.com` has no public DNS record and resolves only inside VPN via Split-DNS to `100.64.0.10`.
6. `passwords.example.com` follows the same VPN-only pattern and proxies to Vaultwarden.
7. Headscale Caddy proxies `vault.example.com` to `deploy-frontend-1:80`.
8. Headscale Caddy proxies `passwords.example.com` to `vaultwarden:80`.
9. Database/admin ports must bind to loopback; pgAdmin is an opt-in `admin` profile.
10. Vault user data and Vaultwarden backups run daily to an external disk using incremental snapshots.

Result:

- `vault.example.com` stays HTTPS and secure-context capable.
- `passwords.example.com` stays HTTPS for the Vaultwarden web vault and Bitwarden clients.
- non-VPN users cannot resolve or reach Vault Web.
- Headscale login endpoint remains reachable as designed.

## Prerequisites

- Debian/Ubuntu server with Docker Engine and Compose plugin
- `git`, `openssl`, `dnsmasq`, `python3` (deployment port preflight)
- DNS:
  - `vpn.example.com` -> server public IP
  - `vault.example.com` -> no public A/AAAA record (resolved only via Split-DNS in VPN)
  - `passwords.example.com` -> no public A/AAAA record (resolved only via Split-DNS in VPN)
- Router forwards `80/tcp` and `443/tcp` to server

## 1) Deploy Stack

```bash
cd /opt
git clone --recurse-submodules https://github.com/Vault-Web/deploy.git
cd /opt/deploy
cp -n .env.example .env
```

Set required values in `/opt/deploy/.env`:

- `FRONTEND_PORT=127.0.0.1:8080`
- `POSTGRES_PORT=127.0.0.1:5433`
- `PGADMIN_PORT=127.0.0.1:8081` (only used with `--profile admin`)
- `VAULTWARDEN_PUBLIC_URL=https://passwords.example.com`
- `VAULTWARDEN_DATA_DIR=/data/vaultwarden`
- a strong DB password and independent values for `JWT_SECRET`, `JWT_REFRESH_SECRET`,
  and `JWT_MEDIA_SECRET`. Run `openssl rand -hex 32` separately for each signing
  key and save the values only in the private `.env` file.
- an Argon2id `VAULTWARDEN_ADMIN_TOKEN`
- valid `CLOUD_HOST_ROOT` (existing host directory)

If an existing deployment used signing keys from an older example file, replace
all three keys in one maintenance window and recreate Vault Web, Cloud Page, and
Vault Habits together. Existing Vault Web sessions and media links will need to
be renewed after the rotation.

When upgrading an existing Vault Web database to the first release that uses
Flyway, take a verified backup and follow the [backend migration guide](https://github.com/Vault-Web/vault-web/blob/main/backend/README.md#database-migrations).
Set `VAULT_WEB_FLYWAY_BASELINE_ON_MIGRATE=true` in `.env` only for the first
startup against the verified legacy Vault Web schema. After successful startup,
remove the setting. Fresh databases use the default `false` setting.

Generate the Vaultwarden admin token hash:

```bash
docker run --rm -it vaultwarden/server:1.37.3 /vaultwarden hash --preset owasp
```

Place the resulting PHC string in `.env` as a single-quoted value. Keep
`VAULTWARDEN_SIGNUPS_ALLOWED=false` for normal operation; temporarily set it to
`true` only while creating the first account, then set it back to `false` and
recreate the container.

Start:

```bash
cd /opt/deploy
python3 scripts/check-admin-ports.py
docker compose -f docker-compose.deploy.yml up -d --build
docker compose -f docker-compose.deploy.yml ps
```

Before using Cloud Page, complete [Cloud Page user root mapping](#8-cloud-page-user-root-folder-mapping)
for each account. Login alone does not assign a Cloud storage directory.

`deploy-up.sh` and `deploy-pull.sh` run this preflight before Docker starts or
pulls services. It checks effective database/admin/frontend Compose bindings, including shell overrides
and the optional admin profile, without printing private configuration. Direct
Compose commands must run it explicitly; for DB-only startup pass
`docker-compose.db.yml`. Bare ports or wildcard binds fail closed. Follow
[`docs/admin-port-migration.md`](docs/admin-port-migration.md) for existing installs.

### Runtime external links

The frontend container writes `runtime-config.local.js` on startup. Set
`VAULTWARDEN_PUBLIC_URL` and `VAULT_HABITS_URL` in `.env`; Vaultwarden is added
without forwarding a Vault-Web token, while Habits keeps the existing SSO token
handoff.

Apply `.env` changes:

```bash
cd /opt/deploy
docker compose -f docker-compose.deploy.yml build frontend
docker compose -f docker-compose.deploy.yml up -d frontend
```

## 2) Headscale Caddy Routing

Connect Headscale Caddy container to deploy network (one-time):

```bash
cd /opt/headscale
docker network connect deploy_default headscale-caddy 2>/dev/null || true
```

Configure `/opt/headscale/Caddyfile`:

```caddy
{
  email {$LETSENCRYPT_EMAIL}
}

vpn.example.com {
  reverse_proxy headscale:8080
}

vault.example.com {
  reverse_proxy deploy-frontend-1:80
}

passwords.example.com {
  reverse_proxy vaultwarden:80
}
```

Apply:

```bash
cd /opt/headscale
docker compose up -d --force-recreate caddy
docker network connect deploy_default headscale-caddy 2>/dev/null || true
docker compose logs --tail=200 caddy
```

Important:

- If you run `--force-recreate` again, reconnect `headscale-caddy` to `deploy_default` afterwards.
- If `dial tcp: lookup deploy-frontend-1 ... no such host` appears, the network attach step is missing.
- If Vaultwarden clients reject the server URL, verify that `passwords.example.com`
  has a valid HTTPS certificate and that `VAULTWARDEN_PUBLIC_URL` matches it.

## 3) Split-DNS (central, production path)

On server (`root`):

```bash
cat >/etc/dnsmasq.d/10-headscale-splitdns.conf <<'EOF'
bind-dynamic
interface=tailscale0
listen-address=127.0.0.1,100.64.0.10
no-resolv
address=/vault.example.com/100.64.0.10
address=/passwords.example.com/100.64.0.10
server=1.1.1.1
server=1.0.0.1
cache-size=10000
EOF

dnsmasq --test
systemctl restart dnsmasq
ss -lupn | grep ':53'
dig +short vault.example.com @127.0.0.1
dig +short vault.example.com @100.64.0.10
```

Set Headscale DNS in `/opt/headscale/config/config.yaml`:

```yaml
dns:
  magic_dns: true
  base_domain: vpn.internal
  override_local_dns: true
  nameservers:
    global:
      - 1.1.1.1
      - 1.0.0.1
    split:
      example.com:
        - 100.64.0.10
  extra_records:
    - name: vault.example.com
      type: A
      value: "100.64.0.10"
    - name: passwords.example.com
      type: A
      value: "100.64.0.10"
```

Apply:

```bash
cd /opt/headscale
docker compose restart headscale
```

Client reconnect (example Linux laptop):

```bash
sudo tailscale up --reset --login-server=https://vpn.example.com --accept-dns=true
sudo resolvectl flush-caches
dig +short vault.example.com
```

## 4) Firewall Hardening

Baseline UFW:

```bash
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

Docker-published ports can bypass UFW. Keep the frontend, Postgres and pgAdmin
host binds on `127.0.0.1`; do not use bare port numbers. The example configuration
applies to both Compose files. pgAdmin is disabled by default; operators may start
it locally with `docker compose -f docker-compose.deploy.yml --profile admin up -d pgadmin`
and stop it with `docker compose -f docker-compose.deploy.yml --profile admin stop pgadmin`.
Use an SSH tunnel for remote administration rather than publishing it on a public
or VPN interface, for example `ssh -L 8081:127.0.0.1:8081 operator@server`.

The old `DOCKER-USER --dport 8081/5433/8080` examples were ineffective: Docker
DNAT changes the destination to the container port before that chain. Do not flush
shared firewall chains. If an operator deliberately needs non-loopback publication,
their firewall policy must account for original destinations (conntrack) and IPv6;
that is outside the default VPN-first setup.

**Existing installations:** updating this checkout does not change `.env` or
running containers. Follow [the admin-port migration and rollback plan](docs/admin-port-migration.md)
before applying these settings. Docker Engine 28 or newer is recommended: older
engines have a known same-L2 reachability issue for localhost-published ports.

## 5) Verification Checklist

Server:

```bash
ss -tulpen | grep -E ':80|:443|:8080|:8081|:5433'
docker compose -f /opt/deploy/docker-compose.deploy.yml ps
docker compose -f /opt/headscale/docker-compose.yml ps
curl -vk https://vpn.example.com
dig +short vault.example.com
dig +short passwords.example.com
curl -vk https://vault.example.com
curl -vk https://passwords.example.com/alive
```

Expected:

- Postgres is bound only to `127.0.0.1:5433`; pgAdmin is absent unless explicitly
  enabled, then bound only to `127.0.0.1:8081`. Check actual Docker bindings too,
  since `ss` alone may not show ports when Docker's userland proxy is disabled.
- From a separate public/LAN/VPN client, connections to the server's ports 5433
  and 8081 fail (check IPv4 and IPv6); VPN application HTTPS access still works.
- `vpn.example.com` responds from Caddy/Headscale.
- `vault.example.com` from VPN client resolves to `100.64.0.10` and returns `200`.
- `passwords.example.com` from VPN client resolves to `100.64.0.10` and Vaultwarden `/alive` returns `200`.
- `vault.example.com` from public resolver (for example `dig +short vault.example.com @1.1.1.1`) returns no record.
- `passwords.example.com` from public resolver returns no record.

Browser on VPN device at `https://vault.example.com`:

- `window.isSecureContext` -> `true`
- `!!globalThis.crypto?.subtle` -> `true`

## 6) Vaultwarden Operations

Vault-Web previously included an experimental in-house password manager. The
deployment now uses Vaultwarden instead, because password management should rely
on a mature Bitwarden-compatible client/server rather than custom portal code.
Before removing an existing production password-manager database from backups,
export any real entries that still need to be retained.

Vault-Web should link users to Vaultwarden; it must not receive Vaultwarden
master passwords, embed the web vault in an iframe, or forward Vault-Web tokens
to Vaultwarden.

Important operating rules:

- use the dedicated HTTPS origin in `VAULTWARDEN_PUBLIC_URL`;
- back up the full `VAULTWARDEN_DATA_DIR` before going live;
- keep `VAULTWARDEN_SIGNUPS_ALLOWED=false` after the first account exists;
- keep `SHOW_PASSWORD_HINT=false`;
- store `VAULTWARDEN_ADMIN_TOKEN` as an Argon2id PHC hash, not plaintext;
- keep `/admin` reachable only to operators who know the admin token.

### Vaultwarden Backups

Vaultwarden stores its database, attachments, sends, and RSA key files under
`/data`. In this deployment, that is the host directory from
`VAULTWARDEN_DATA_DIR`. Losing that directory means losing the password vaults,
so test backup and restore before onboarding users.

The backup script briefly stops the `vaultwarden` container before copying the
data directory, then starts it again if it was running. This avoids copying a
live SQLite database and its WAL files mid-write.

Daily backup timer example:

```bash
cat >/etc/systemd/system/backup-vaultwarden.service <<'EOF'
[Unit]
Description=Incremental backup of Vaultwarden data

[Service]
Type=oneshot
WorkingDirectory=/opt/deploy
ExecStart=/opt/deploy/scripts/backup-vaultwarden.sh
EOF

cat >/etc/systemd/system/backup-vaultwarden.timer <<'EOF'
[Unit]
Description=Daily incremental backup timer for Vaultwarden (23:20)

[Timer]
OnCalendar=*-*-* 23:20:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now backup-vaultwarden.timer
systemctl start backup-vaultwarden.service
```

Restore example:

```bash
cd /opt/deploy
docker compose -f docker-compose.deploy.yml stop vaultwarden
scripts/restore-vaultwarden.sh /mnt/backup5tb/vaultwarden-backups/latest
docker compose -f docker-compose.deploy.yml up -d vaultwarden
```

## 7) Daily Incremental Backup of `/data/vault-users` (23:30)

### Backup strategy

- Snapshot-like backups using `rsync --link-dest` (incremental with hardlinks).
- Retention: keep only the last 5 snapshots.
- `latest` points only to a completed, restore-verified snapshot.
- The backup job mounts the disk if necessary and unmounts only a mount it created.
- Each new snapshot contains `data/`, a SHA-256/metadata manifest and `COMPLETE`.
  Existing flat snapshots remain readable and are retained during migration.
- Every backup performs an independent copy into temporary storage and compares
  contents, paths, symlink targets, ownership and permissions with the source manifest.
  A weekly job repeats this drill to detect later disk corruption.

### One-time setup (server root)

Adjust disk UUID and device if needed.

If you want the disk mounted only during backup runs, do not use `x-systemd.automount` in `/etc/fstab`.

```bash
sudo -i
set -euo pipefail

DISK_DEV="/dev/sdc"
PART_UUID="REPLACE_WITH_BACKUP_PARTITION_UUID"
MNT="/mnt/backup5tb"

apt-get update
apt-get install -y rsync util-linux

mkdir -p "${MNT}"

grep -q "${PART_UUID}" /etc/fstab || \
echo "UUID=${PART_UUID} ${MNT} ext4 defaults,nofail 0 0" >> /etc/fstab

mount "${MNT}" || true
```

This example requires an already-created ext4 backup filesystem. Do not change
an existing disk's fstab type or reformat it to follow the example: preserve old
backups and migrate to a separate tested POSIX-compatible disk. Flattened NTFS
`uid/gid/umask` mounts are rejected before sensitive data is written.

Install the tracked jobs (see [backup rollout and recovery](docs/backups.md)
before replacing an existing timer):

```bash
apt-get install -y rsync python3 util-linux gzip
install -m 0644 /opt/deploy/scripts/systemd/{backup-vault-users,verify-vault-users,backup-postgres}.{service,timer} /etc/systemd/system/
```

Enable schedules after a successful manual run:

```bash
systemctl daemon-reload
systemctl start backup-vault-users.service
systemctl start verify-vault-users.service
systemctl start backup-postgres.service
systemctl enable --now backup-vault-users.timer verify-vault-users.timer backup-postgres.timer
```

### Run immediate test backup

```bash
systemctl start backup-vault-users.service
systemctl status backup-vault-users.service --no-pager
journalctl -u backup-vault-users.service -n 80 --no-pager
mount /mnt/backup5tb || true
ls -lah /mnt/backup5tb/vault-users-backups
umount /mnt/backup5tb || true
```

The services are `Type=oneshot`; successful runs show `inactive (dead)` with
`status=0/SUCCESS`. Failures produce a nonzero service result and journal errors.
Monitor all three units; configure the optional heartbeat below on verification
and PostgreSQL services as well, using separate monitor UUIDs.

### Restore procedure (manual)

Pick a snapshot folder and restore to source:

```bash
mount /mnt/backup5tb || true
SNAP="/mnt/backup5tb/vault-users-backups/backup-2026-11-15_23-30-00-1234"
rsync -aH --delete --numeric-ids "${SNAP}/data/" /data/vault-users/
umount /mnt/backup5tb || true
```

For legacy flat snapshots, use `${SNAP}/` instead. Stop application writers,
save the current tree and review the selected manifest before a destructive
manual restore; follow the rollback plan in [docs/backups.md](docs/backups.md).
PostgreSQL backups run at 23:45 via server-matched `pg_dumpall`, covering both
application databases and roles. They are sensitive compressed SQL dumps,
separate from user-file snapshots; see the same guide for isolated restore checks.

### Backup troubleshooting

- `rsync: command not found`:
  - `apt-get install -y rsync`
- `Unit backup-vault-users.service not found`:
  - recreate `/etc/systemd/system/backup-vault-users.service`, then `systemctl daemon-reload`
- `target is busy` on unmount:
  - check with `lsof +f -- /mnt/backup5tb` and `fuser -vm /mnt/backup5tb`
- `hdparm -C /dev/sdc` shows `unknown`:
  - common on USB enclosures; backup still works.

## 8) Cloud Page User Root Folder Mapping

`CLOUD_HOST_ROOT` is mounted as `/host-cloud` in the Cloud Page container.
For example, with `CLOUD_HOST_ROOT=/data/vault-users`, the host directory
`/data/vault-users/alice` is visible there as `/host-cloud/alice`. The Cloud
database's `users.root_folder_path` must contain the **container-visible** path,
not the host path. Each account needs its own directory and Cloud user record;
do not point two users at the same directory or at the shared `/host-cloud` root.

### Assign a new user's root

1. Confirm the account already has exactly one matching record in the **Cloud**
   database (`POSTGRES_DB_CLOUD`, not the core `POSTGRES_DB_VAULT`). If it is
   missing or ambiguous, resolve account provisioning first; do not invent IDs
   or copy a core user row into Cloud.
2. Create the directory on the host. For the example mapping above:

   ```bash
   sudo mkdir -p /data/vault-users/alice
   ```

   Use the ownership/permissions required by the deployed Cloud container and
   any existing Syncthing setup. Verify Cloud can read and write this directory;
   do not grant world-writable permissions or recursively change other users' data.
3. Open an administrative `psql` session in the Cloud database. From `/opt/deploy`:

   ```bash
   docker compose -f docker-compose.deploy.yml exec db sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d cloud_db'
   ```

   Replace `cloud_db` with your configured `POSTGRES_DB_CLOUD` value if different.
   The `db` service receives `POSTGRES_USER`, but not `POSTGRES_DB_CLOUD`, so the
   database name is supplied explicitly. Do not paste database passwords
   into shell commands or logs.
4. Inspect the row and record its existing path privately before updating it.
   Replace `alice` with the intended username. In the same `psql` session:

   ```sql
   BEGIN;
   SELECT id, username, root_folder_path
   FROM users WHERE username = 'alice' FOR UPDATE;

   UPDATE users
   SET root_folder_path = '/host-cloud/alice'
   WHERE username = 'alice'
     AND (root_folder_path IS NULL OR root_folder_path = '')
   RETURNING id, username, root_folder_path;
   ```

   Continue with `COMMIT;` only if the inspected account is unique and the update
   reports exactly `UPDATE 1` with the intended path; otherwise use `ROLLBACK;`
   and investigate. The guard intentionally leaves existing mappings untouched.
   Quote SQL string values correctly when adapting the example.

For an already configured account, changing the path redirects access to its
files; it does not move them. Back up the Cloud database and user files, record
the previous mapping and coordinate filesystem changes before any reassignment.
If a new assignment is wrong, stop Cloud operations for that account and restore
the recorded previous mapping in a reviewed transaction. Preserve any files
written in the new directory for reconciliation; do not delete them as rollback.

Wrong (causes "Root folder does not exist..."):

- `/alice`
- `/data/vault-users/alice`

Quick checks:

```bash
ls -ld /data/vault-users /data/vault-users/alice
docker compose -f /opt/deploy/docker-compose.deploy.yml exec cloud-page-backend ls -ld /host-cloud /host-cloud/alice
```

Path consistency reference:

- host storage path: `/data/vault-users/<user>`
- Cloud Page container-visible path: `/host-cloud/<user>`
- Syncthing user container-visible path: `/vault-user`

### Setup checklist

- [ ] `db` is healthy and Cloud connects to `POSTGRES_DB_CLOUD` without database errors.
- [ ] The intended Cloud user row has its own `/host-cloud/<user>` path; that
      directory exists and is readable/writable from `cloud-page-backend`.
- [ ] Core and Cloud receive the same configured `JWT_SECRET` through Compose.
      Compare configuration privately; do not print secrets or rotate keys as a setup test.
- [ ] From the VPN, sign in and open Cloud through the normal HTTPS portal.
      `/cloud-api/` must reach Cloud's `/api/` routes through nginx, not the SPA shell.
- [ ] Upload and download a small disposable file as that user, then remove it
      through the UI; confirm another user's files are not visible.

This is a manual setup runbook. A future helper can automate these checks and
the guarded assignment without becoming a full installer.

## 9) Daily Operations

Update deploy repo only:

```bash
cd /opt/deploy
git pull --ff-only
docker compose -f docker-compose.deploy.yml up -d --build --remove-orphans
```

Update with submodules:

```bash
cd /opt/deploy
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive
docker compose -f docker-compose.deploy.yml up -d --build --remove-orphans
```

Logs:

```bash
docker compose -f /opt/deploy/docker-compose.deploy.yml logs -f frontend
docker compose -f /opt/deploy/docker-compose.deploy.yml logs -f vault-web-backend
docker compose -f /opt/deploy/docker-compose.deploy.yml logs -f vaultwarden
docker compose -f /opt/headscale/docker-compose.yml logs -f caddy
```

## 10) Syncthing User Sync (Optional)

For multi-user Syncthing with per-user server folder isolation and VPN-only access, use:

- [Syncthing Runbook S1 - Vault Users](./services/server-docs/syncthing/runbooks/01-vault-users-syncthing.md)

## 11) Known Pitfalls

- `dial tcp: lookup frontend ... no such host` or `deploy-frontend-1 ... no such host` in headscale-caddy logs:
  - missing Docker network connection (`deploy_default` not attached to `headscale-caddy`).
- `ERR_SSL_PROTOCOL_ERROR` on `vault.example.com`:
  - Caddy route broken, certificate pending, or wrong reverse proxy target.
- Bitwarden clients keep using `bitwarden.com`:
  - choose the self-hosted/server URL option and enter `https://passwords.example.com`.
- Vaultwarden account creation is visible after onboarding:
  - set `VAULTWARDEN_SIGNUPS_ALLOWED=false` and recreate the container.
- `vault.example.com` resolves to public IP on VPN client:
  - Split-DNS not applied on client; reconnect with `--accept-dns=true` and flush resolver cache.
- `Invalid CORS request`:
  - backend CORS allowlist/pattern does not include current frontend origin.
- WebCrypto unavailable:
  - app opened via plain HTTP or insecure context.

## 10) Independent Runtime Monitoring (Gatus + Heartbeats)

Gatus runs as a **host-level systemd service**, not in `docker-compose.deploy.yml`. This keeps monitoring independent from the application stack: a Compose outage does not also take down the monitor.

### Network and privacy model

- Install Gatus on the deployment host (or another independent host) and keep its dashboard bound to `127.0.0.1:8082`. Access it with an SSH tunnel (`ssh -L 8082:127.0.0.1:8082 <server>`) or an authenticated VPN-only proxy.
- The monitoring host must have the same VPN connectivity and Split-DNS access as a normal user for VPN-only endpoints. For example, `vault.example.com` should resolve to the VPN address on that host.
- Do not add public DNS records, firewall openings, or public port forwards for VPN-only services just to make a check pass.
- Configure every endpoint with the URLs users actually visit through the frontend/reverse proxy. Do not point checks at Docker-only service names or internal container ports.

### Install Gatus

From the repository root on the server:

```bash
cd /opt/deploy
sudo GATUS_VERSION=v5.15.0 ./monitoring/gatus/install.sh
sudoedit /etc/gatus/gatus.env
```

Set the URLs in `/etc/gatus/gatus.env`. The example file is [monitoring/gatus/gatus.env.example](./monitoring/gatus/gatus.env.example). It includes the user-facing Vault Web and Cloud Page UI URLs, a Cloud Page backend probe, Vaultwarden, Vault Habits and the WebSocket route `wss://vault.example.com/ws-chat`, matching `docker/nginx/default.conf`. Replace every example host with the real route in your installation.

The Cloud Page backend probe deliberately requests a nonexistent Secure Send token through `/cloud-api/public/secure-sends/<probe-token>/meta`. A healthy backend returns the expected `404` response body `Secure Send link is unavailable`; this proves the request reached the Cloud Page application rather than merely receiving Angular's SPA shell. If the backend or its database is unavailable, the expected status/body check fails.

To verify the backend monitor on the deployment host, stop only the Cloud Page backend and wait for the next Gatus interval:

```bash
cd /opt/deploy
sudo docker compose -f docker-compose.deploy.yml stop cloud-page-backend
# The "Cloud Page backend" endpoint should become unhealthy.
sudo docker compose -f docker-compose.deploy.yml start cloud-page-backend
```

After the backend is healthy again, Gatus should report the endpoint as healthy on a subsequent check.

Enable the service:

```bash
sudo systemctl enable --now gatus
sudo systemctl status gatus --no-pager
sudo journalctl -u gatus -n 100 --no-pager
# From your workstation, open an SSH tunnel:
ssh -L 8082:127.0.0.1:8082 <server>
# Then visit http://127.0.0.1:8082 in your browser.
```

Gatus restarts on failure and runs checks every minute. A failed condition marks the endpoint unhealthy. Review the Gatus status page/logs and investigate the affected reverse proxy, VPN/DNS route or application. Do not expose private services to the public internet to satisfy a check.

### Optional external host and backup heartbeats

Create separate monitors at [healthchecks.io](https://healthchecks.io/) for host uptime and the backup job. Keep generated UUIDs secret. The scripts in [monitoring/healthchecks](./monitoring/healthchecks) are no-ops when their UUID environment variable is absent, so this integration remains optional.

Create `/etc/default/vault-web-heartbeats` with mode `0600` and set:

```bash
HC_HOST_UUID=replace-with-host-check-uuid
HC_BACKUP_UUID=replace-with-backup-check-uuid
```

Install the host timer using the example units:

```bash
sudo install -m 0755 /opt/deploy/monitoring/healthchecks/host-heartbeat.sh /usr/local/sbin/vault-web-host-heartbeat
sudo install -m 0644 /opt/deploy/monitoring/healthchecks/host-heartbeat.service.example /etc/systemd/system/vault-web-host-heartbeat.service
sudo install -m 0644 /opt/deploy/monitoring/healthchecks/host-heartbeat.timer.example /etc/systemd/system/vault-web-host-heartbeat.timer
sudo systemctl daemon-reload
sudo systemctl enable --now vault-web-host-heartbeat.timer
```

For backup monitoring, install the hook and attach it to the existing systemd backup service with an `ExecStartPost` drop-in. systemd runs `ExecStartPost` only after the backup command exits successfully, so failed backups never send a success heartbeat:

```bash
sudo install -m 0755 /opt/deploy/monitoring/healthchecks/backup-heartbeat.sh /usr/local/sbin/vault-web-backup-heartbeat
sudo install -d -m 0755 /etc/systemd/system/backup-vault-users.service.d
sudo tee /etc/systemd/system/backup-vault-users.service.d/healthchecks.conf >/dev/null <<'EOF'
[Service]
EnvironmentFile=/etc/default/vault-web-heartbeats
ExecStartPost=/usr/local/sbin/vault-web-backup-heartbeat
EOF
sudo systemctl daemon-reload
```

The required `EnvironmentFile` passes `HC_BACKUP_UUID` from `/etc/default/vault-web-heartbeats` into the hook. The hook runs after the existing backup script, including its retention and verification steps. Do not call it at backup start: a later backup failure must not be reported as success. Test the configured path with a successful backup run, then confirm the backup monitor's last-ping time updates in healthchecks.io. Set its grace period longer than the normal backup duration; missed pings trigger its configured email/webhook alerts.

### Troubleshooting

- **All VPN endpoints fail:** check VPN connectivity and Split-DNS (`getent hosts vault.example.com`).
- **One endpoint fails:** open the same user-facing URL from a VPN client and inspect proxy/application logs; confirm the expected HTTP status.
- **WebSocket fails:** verify the route supports an HTTP Upgrade handshake and `/ws-chat` matches the frontend proxy.
- **Heartbeat is late:** inspect the systemd timer/service, outbound HTTPS connectivity and UUID configuration.
