# Database and admin port migration

This change makes new installations publish Postgres and optional pgAdmin only
on IPv4 loopback. Both Compose files use the same variables. pgAdmin is now in
the `admin` profile. Internal database addresses (`db:5432`), credentials, schemas
and named volumes are unchanged; there is no data conversion. Old `.env` files
remain effective until an operator edits them. No production migration is automatic.
Deployment helpers now refuse startup/pulls when the effective database, admin or frontend
bind is not loopback-only. Python 3 must be installed. Existing safe bind strings
remain compatible; bare ports require the documented configuration migration.
Direct Compose invocations must run the preflight explicitly.

## Prerequisites and backups

- Record the deployed Git/submodule revisions and Compose project name. Keep a
  private copy of the current `.env`, rendered Compose configuration and database
  volume name; configuration may contain secrets and must not be published.
- Take the existing database backup and verify its restore before maintenance.
  Never use `down -v`, remove `pgdata`, or change the Compose project name.
- Inventory host-port database clients, monitoring and pgAdmin sessions. Move
  remote clients to an SSH tunnel; application containers continue using `db:5432`.
- Use Docker Engine 28+ for the localhost publication fix. Older engines can
  expose localhost-published ports to machines on the same L2 network. Upgrade
  under the host's maintenance plan or verify equivalent network isolation first.
  See [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/).
  These defaults assume standard NAT bridge networks; custom direct-routing or
  routed/unprotected gateway modes need their own isolation assessment.
- Plan a brief database interruption for container recreation. Keep SSH/operator
  access available and arrange retries for application database connections.

## Apply

Run from the existing deployment directory, using its existing project name.
The commands below assume the full stack; substitute `docker-compose.db.yml`
throughout for a DB-only deployment. Do not run both stacks against one volume.

1. Review the candidate and record the current revisions before changing them;
   do not advance unrelated service submodules as part of this migration.
2. In the existing private `.env`, set:

   ```dotenv
   POSTGRES_PORT=127.0.0.1:5433
   PGADMIN_PORT=127.0.0.1:8081
   FRONTEND_PORT=127.0.0.1:8080
   ```

   Preserve custom host port numbers, adding the `127.0.0.1:` prefix. Also verify
   that `FRONTEND_PORT` remains on loopback (full stack only). Do not overwrite credentials from the
   example file. Command-shell variable overrides must match these settings.
3. Render `docker compose -f docker-compose.deploy.yml config` privately and check
   the effective `host_ip` for database/frontend and (with `--profile admin`)
    pgAdmin. It must be `127.0.0.1`, never `0.0.0.0` or `::`.
   Run `python3 scripts/check-admin-ports.py` before startup; pass
   `docker-compose.db.yml` for DB-only deployments. The preflight also accepts
   explicit IPv6 loopback `::1`, but remote-isolation checks remain required.
4. Stop any existing pgAdmin container explicitly; disabling a profile alone does
   not guarantee that a previously running container stops:

   ```bash
   docker compose -f docker-compose.deploy.yml --profile admin stop pgadmin
    docker compose -f docker-compose.deploy.yml up -d --no-deps --force-recreate db
    docker compose -f docker-compose.deploy.yml up -d --no-deps --force-recreate frontend
   docker compose -f docker-compose.deploy.yml ps db
   ```

5. Wait for database readiness and test existing application login/file access.
   DB-only Compose has no healthcheck: use `pg_isready` inside its DB container.
   If pgAdmin is needed, recreate it explicitly so it gets the new binding:

   ```bash
   docker compose -f docker-compose.deploy.yml --profile admin up -d --no-deps --force-recreate pgadmin
   ```

6. Inspect actual bindings with `docker inspect` on the DB/pgAdmin/frontend container IDs
   from `docker compose ... ps -q`. Check `NetworkSettings.Ports` and host `ss`.
   From a separate public/LAN/VPN client verify these direct host ports are unreachable
   on IPv4 and IPv6. Confirm a localhost or SSH-tunnel connection succeeds and
   VPN HTTPS still works. A local-only check cannot prove remote isolation.

## Recovery and rollback

If applications do not reconnect after database readiness, inspect their logs
and restart only affected application containers. Confirm the original database
volume is attached; do not initialize a replacement or restore over live data.
If a host-port client fails, repair its SSH tunnel instead of reopening the port.

To roll back code, restore the recorded deployment revision and submodule pins
without `--remote`. Keep loopback values in `.env`: the previous Compose files
accept `127.0.0.1:PORT` and can use the same database volume/data. Stop pgAdmin
before rollback, since the previous configuration starts it by default; start
only the intended services. Recreate `db` with `--no-deps --force-recreate` if its
configuration changed, then repeat readiness/data/application checks. There is
no schema rollback or database restore required for this port-only change.

Restoring bare port values would restore the original exposure and is not a safe
rollback. Any deliberate network-publication exception needs a separate operator
decision and tested firewall rules before restarting services. Retain the backup
and private configuration evidence until verification completes.
