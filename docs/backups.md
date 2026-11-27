# Verified backups: installation, migration and recovery

## Scope and prerequisites

The host jobs preserve rsync incremental hardlinks for `/data/vault-users`.
They do not deploy services, modify database schemas or restore production data.
Daily PostgreSQL `pg_dumpall` adds coverage for both app databases and cluster
roles. Vaultwarden continues to use its existing separate backup script.
Uploads, Habits and other named volumes need their own coverage; these jobs do
not claim to be a complete stack disaster-recovery system.

Use Bash, GNU coreutils, rsync, Python 3, util-linux (`flock`, `mountpoint`), gzip,
Docker Compose and a backup filesystem supporting hardlinks and the source's
ownership/permissions. Use an existing POSIX-compatible filesystem such as ext4;
flattened NTFS uid/gid/umask mounts are incompatible. Before writing any sensitive
bytes, both jobs require an owner-only mode-0700 backup directory and probe mode
changes and (when root) ownership changes. A mismatch fails before capture.
Do not reformat an existing backup disk or simply change its fstab filesystem type;
preserve its copies and migrate onto a separate compatible disk. Provide enough free temporary space
for a full independent restore. Jobs share an exclusive host lock and queue for up
to one hour by default, including after persistent timers catch up at boot. Set
`BACKUP_LOCK_WAIT_SECONDS` to a positive timeout appropriate to measured backup
duration; an exhausted wait fails visibly and requires an operator retry/alert.

The manifest records expected files from the source before rsync. Changes during
capture/copy retry up to three fresh copies if the inventories differ. Rsync uses
content checksums rather than relying only on size/mtime for incremental reuse.
Persistent changes still fail without replacing the previous snapshot; pause
writers and retry after an exhausted capture. For consistent multi-file
application state, pause writers during the file backup window. These copies are
not atomic filesystem snapshots. PostgreSQL dumps are transactionally consistent
per database; cross-database/file consistency requires coordinated writer downtime.

## Opt-in rollout and rollback

1. Record the deployed checkout revision, existing timer/service/drop-ins, mount
   configuration and `latest` target. Save copies outside the backup tree. Keep
   known-good backups on a separate protected disk before replacing a job.
2. Stop the old `backup-vault-users.timer`, wait for any active backup to finish,
   and retain the old `/usr/local/sbin/backup-vault-users.sh` for rollback. Stop
   writers for the initial source capture. No destructive migration is automatic.
3. Keep the new scripts together in `/opt/deploy/scripts`. Install the six tracked
   units using the README. Optionally create a root-owned mode-0600
   `/etc/default/vaultweb-backups` (systemd environment syntax, not shell code):

   ```ini
   BACKUP_MNT=/mnt/backup5tb
   VAULT_USERS_SOURCE=/data/vault-users
    BACKUP_KEEP=5
    BACKUP_LOCK_WAIT_SECONDS=3600
   RESTORE_TEST_ROOT=/var/tmp
   DEPLOY_DIR=/opt/deploy
   ```

   No database password belongs here. Compose parses the application's `.env`;
   PostgreSQL credentials are used inside its existing `db` container.
4. Run the three services manually and inspect exit status/journals. Confirm an
   independent restore completes, source files are unchanged, and the backup mount
   is not accidentally a host-directory fallback. Test alerts by temporarily using
   a missing source or corrupting a **disposable copy** of a snapshot. Restore the
   valid configuration and enable schedules only after success.
5. New snapshots are `backup-<UTC timestamp>-<pid>/data`, plus `manifest.json` and
   `COMPLETE`. An existing flat `latest` can supply the first rsync link-dest.
   Legacy snapshots are never automatically pruned. The weekly verifier requires
   a new-format snapshot: create one before enabling its timer. Only completed
   new-format snapshots beyond the configured count are pruned after success.
6. To roll back the job installation, stop all three timers, wait for active units,
   restore the saved units/drop-ins and reload systemd. Repoint `latest` to the
   retained flat snapshot **before** starting the old script; old scripts expect
   flat layouts and must never use a new-format directory as source/link-dest.
   Keep new-format snapshots for manual recovery using their `data/` directory.

Scripts unmount only mounts they created. They do not spin down disks or change
fstab. A failed copy/drill leaves the prior `latest` and retention intact; temporary
directories are removed on normal failure. After power loss/SIGKILL, inspect stale
`.partial.*` directories manually while no job is active. Never promote one without
its manifest and a successful independent drill. Root-owned backup directories
must not be writable by users; manifests detect accidental corruption, not an
attacker able to rewrite both files and manifests. Protect off-host copies and
encrypt the backup device: database dumps contain password hashes and private data.

## Failure visibility

```bash
systemctl --failed
journalctl -u backup-vault-users -u verify-vault-users -u backup-postgres --since yesterday
```

Each failure propagates to systemd; no success heartbeat runs after a failed
`ExecStart`. Configure independent missed-heartbeat/OnFailure alerts for all three
services and test delivery. Weekly verification reads the saved manifest, copies
the actual bytes without hardlinks, and compares the restored inventory. Missing,
changed or extra files and unreadable files fail; symlinks are compared without
following their targets. Special files are rejected. No restore drill writes into
the live source tree.

## PostgreSQL restore rehearsal and incident recovery

`postgres-backups/latest/data/cluster.sql.gz` is a SQL cluster dump made with the
running server's tools; gzip integrity is checked before publication. Periodically
restore it into an isolated **same-major-version** PostgreSQL container/host with
empty disposable storage and no production network. A valid gzip alone does not
prove SQL restoreability. Never pipe a dump into the live cluster for a drill.

1. Copy a selected dump and its manifest to protected scratch storage; run
   `python3 scripts/backup-manifest.py check <scratch>/data <scratch>/manifest.json`.
2. Start PostgreSQL 16 (or the actually deployed major version) on isolated storage,
   with an initial superuser name absent from the dump (e.g. `restore_operator`).
3. Pipe `gzip -dc <scratch>/data/cluster.sql.gz` to that disposable server's
   `psql -X -v ON_ERROR_STOP=1 -U restore_operator -d postgres`. Check roles, both
   app databases, representative table rows and application login/file ownership
   with synthetic accounts. Remove the disposable storage after the rehearsal.
4. For a real incident, stop app writers and take an additional backup of current
   files/databases. Restore selected files to staging first; never run `--delete`
   against live storage until the selection and destination have been reviewed.
   Restore SQL to a replacement cluster, verify it, then plan a controlled cutover.
   Record original DB/volume pointers so rollback can return to the preserved cluster.
   Database/file backups taken at different times may need reconciliation and
   downtime; cross-major restoration requires a separate tested upgrade plan.

No production restore, migration or deployed-client compatibility is implied by
the repository's synthetic test suite. Run `bash scripts/tests/backups.sh` on Linux
with the prerequisites above; the PostgreSQL end-to-end rehearsal additionally
needs disposable PostgreSQL resources as documented in the test harness.
