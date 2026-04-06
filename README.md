# Vault Web Deploy

Deployment repository for Vault Web with Docker Compose and service submodules.

> Security note: all domains, IPs, usernames, UUIDs, and secrets in this README are examples and must be replaced for real deployments.

## Included Services

- [`services/vault-web`](./services/vault-web)
- [`services/cloud-page`](./services/cloud-page)
- [`services/password-manager`](./services/password-manager)
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
6. Headscale Caddy proxies `vault.example.com` to `deploy-frontend-1:80`.
7. Firewall + `DOCKER-USER` rules block accidental exposure of debug/admin ports.
8. Vault user data backups run daily at `23:30` to an external disk using incremental snapshots.

Result:

- `vault.example.com` stays HTTPS and secure-context capable.
- non-VPN users cannot resolve or reach Vault Web.
- Headscale login endpoint remains reachable as designed.

## Prerequisites

- Debian/Ubuntu server with Docker Engine and Compose plugin
- `git`, `openssl`, `dnsmasq`
- DNS:
  - `vpn.example.com` -> server public IP
  - `vault.example.com` -> no public A/AAAA record (resolved only via Split-DNS in VPN)
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
- strong DB/JWT secrets
- valid `CLOUD_HOST_ROOT` (existing host directory)

Start:

```bash
cd /opt/deploy
docker compose -f docker-compose.deploy.yml up -d --build
docker compose -f docker-compose.deploy.yml ps
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

## 3) Split-DNS (central, production path)

On server (`root`):

```bash
cat >/etc/dnsmasq.d/10-headscale-splitdns.conf <<'EOF'
bind-dynamic
interface=tailscale0
listen-address=127.0.0.1,100.64.0.10
no-resolv
address=/vault.example.com/100.64.0.10
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

Docker published ports hardening:

```bash
sudo iptables -F DOCKER-USER
sudo iptables -I DOCKER-USER -p tcp --dport 8080 -j DROP
sudo iptables -I DOCKER-USER -p tcp --dport 8081 -j DROP
sudo iptables -I DOCKER-USER -p tcp --dport 5433 -j DROP
sudo iptables -A DOCKER-USER -j RETURN
sudo iptables -S DOCKER-USER
```

## 5) Verification Checklist

Server:

```bash
ss -tulpen | grep -E ':80|:443|:8080|:8081|:5433'
docker compose -f /opt/deploy/docker-compose.deploy.yml ps
docker compose -f /opt/headscale/docker-compose.yml ps
curl -vk https://vpn.example.com
dig +short vault.example.com
curl -vk https://vault.example.com
```

Expected:

- `vpn.example.com` responds from Caddy/Headscale.
- `vault.example.com` from VPN client resolves to `100.64.0.10` and returns `200`.
- `vault.example.com` from public resolver (for example `dig +short vault.example.com @1.1.1.1`) returns no record.

Browser on VPN device at `https://vault.example.com`:

- `window.isSecureContext` -> `true`
- `!!globalThis.crypto?.subtle` -> `true`

## 6) Daily Incremental Backup of `/data/vault-users` (23:30)

### Backup strategy

- Snapshot-like backups using `rsync --link-dest` (incremental with hardlinks).
- Retention: keep only the last 5 snapshots.
- `latest` symlink always points to the newest snapshot.
- The backup job mounts backup disk, runs backup, then unmounts.

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
apt-get install -y rsync hdparm ntfs-3g

mkdir -p "${MNT}"

grep -q "${PART_UUID}" /etc/fstab || \
echo "UUID=${PART_UUID} ${MNT} ntfs-3g defaults,uid=0,gid=0,umask=022,nofail 0 0" >> /etc/fstab

mount "${MNT}" || true
```

Create backup script:

```bash
cat >/usr/local/sbin/backup-vault-users.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SRC="/data/vault-users/"
MNT="/mnt/backup5tb"
DST_BASE="${MNT}/vault-users-backups"
TS="$(date +%F_%H-%M-%S)"
DST="${DST_BASE}/${TS}"
LATEST="${DST_BASE}/latest"
KEEP=5
DISK_DEV="/dev/sdc"

cleanup() {
  sync || true
  mountpoint -q "${MNT}" && umount "${MNT}" || true
  hdparm -y "${DISK_DEV}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mountpoint -q "${MNT}" || mount "${MNT}"
mkdir -p "${DST_BASE}"

if [ -L "${LATEST}" ] && [ -d "$(readlink -f "${LATEST}")" ]; then
  PREV="$(readlink -f "${LATEST}")"
  rsync -aH --delete --link-dest="${PREV}" "${SRC}" "${DST}/"
else
  rsync -aH --delete "${SRC}" "${DST}/"
fi

ln -sfn "${DST}" "${LATEST}"

find "${DST_BASE}" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' \
  | sort -r | tail -n +$((KEEP+1)) | while read -r old; do
    rm -rf "${DST_BASE}/${old}"
  done
EOF

chmod +x /usr/local/sbin/backup-vault-users.sh
```

Create systemd service + timer:

```bash
cat >/etc/systemd/system/backup-vault-users.service <<'EOF'
[Unit]
Description=Incremental backup of /data/vault-users to external disk

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup-vault-users.sh
EOF

cat >/etc/systemd/system/backup-vault-users.timer <<'EOF'
[Unit]
Description=Daily incremental backup timer for vault-users (23:30)

[Timer]
OnCalendar=*-*-* 23:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now backup-vault-users.timer
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

`backup-vault-users.service` is `Type=oneshot`; after a successful run, `systemctl status` usually shows `inactive (dead)` with `status=0/SUCCESS`. This is expected.

### Restore procedure (manual)

Pick a snapshot folder and restore to source:

```bash
mount /mnt/backup5tb || true
SNAP="/mnt/backup5tb/vault-users-backups/2026-04-01_23-30-00"
rsync -aH --delete "${SNAP}/" /data/vault-users/
umount /mnt/backup5tb || true
```

### Backup troubleshooting

- `rsync: command not found`:
  - `apt-get install -y rsync`
- `Unit backup-vault-users.service not found`:
  - recreate `/etc/systemd/system/backup-vault-users.service`, then `systemctl daemon-reload`
- `target is busy` on unmount:
  - check with `lsof +f -- /mnt/backup5tb` and `fuser -vm /mnt/backup5tb`
- `hdparm -C /dev/sdc` shows `unknown`:
  - common on USB enclosures; backup still works.

## 7) Cloud Page User Root Folder Mapping

`CLOUD_HOST_ROOT` is mounted as `/host-cloud` in container.
Root folder paths stored in DB must use container path.

Correct:

```sql
UPDATE users
SET root_folder_path = '/host-cloud/alice'
WHERE username = 'alice';
```

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

## 8) Daily Operations

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
git submodule update --init --recursive --remote
docker compose -f docker-compose.deploy.yml up -d --build --remove-orphans
```

Logs:

```bash
docker compose -f /opt/deploy/docker-compose.deploy.yml logs -f frontend
docker compose -f /opt/deploy/docker-compose.deploy.yml logs -f vault-web-backend
docker compose -f /opt/headscale/docker-compose.yml logs -f caddy
```

## 9) Syncthing User Sync (Optional)

For multi-user Syncthing with per-user server folder isolation and VPN-only access, use:

- [Syncthing Runbook S1 - Vault Users](./services/server-docs/syncthing/runbooks/01-vault-users-syncthing.md)

## 8) Known Pitfalls

- `dial tcp: lookup frontend ... no such host` or `deploy-frontend-1 ... no such host` in headscale-caddy logs:
  - missing Docker network connection (`deploy_default` not attached to `headscale-caddy`).
- `ERR_SSL_PROTOCOL_ERROR` on `vault.example.com`:
  - Caddy route broken, certificate pending, or wrong reverse proxy target.
- `vault.example.com` resolves to public IP on VPN client:
  - Split-DNS not applied on client; reconnect with `--accept-dns=true` and flush resolver cache.
- `Invalid CORS request`:
  - backend CORS allowlist/pattern does not include current frontend origin.
- WebCrypto unavailable:
  - app opened via plain HTTP or insecure context.
