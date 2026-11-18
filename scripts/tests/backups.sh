#!/usr/bin/env bash
# Linux regression suite: real rsync, manifests and independent file restores.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
mkdir -p "${TMP}/source/alice" "${TMP}/source/bob" "${TMP}/mount" "${TMP}/restore" "${TMP}/bin"
# Only mount operations are stubbed: no host disk is mounted by the tests.
printf '#!/bin/sh\nexit 0\n' >"${TMP}/bin/mountpoint"
chmod +x "${TMP}/bin/mountpoint"
export PATH="${TMP}/bin:${PATH}" BACKUP_MNT="${TMP}/mount"
export VAULT_USERS_SOURCE="${TMP}/source" RESTORE_TEST_ROOT="${TMP}/restore"
export BACKUP_LOCK="${TMP}/lock" BACKUP_KEEP=2
printf 'alice original\n' >"${TMP}/source/alice/file with spaces"
printf 'bob private\n' >"${TMP}/source/bob/file"
printf 'newline name\n' >"${TMP}/source/alice/"$'line\nbreak'
ln -s /outside/private "${TMP}/source/alice/external"
ln "${TMP}/source/bob/file" "${TMP}/source/bob/hardlink"
chmod 0640 "${TMP}/source/bob/file"
backup() { bash "${ROOT}/scripts/backup-vault-users.sh" "$@"; }
fail() { if "$@"; then echo "Expected failure: $*" >&2; exit 1; fi; }
BASE="${BACKUP_MNT}/vault-users-backups"
backup
FIRST="$(readlink -f "${BASE}/latest")"
[ "$(cat "${FIRST}/data/bob/file")" = 'bob private' ]
[ "$(readlink "${FIRST}/data/alice/external")" = /outside/private ]
backup verify
[ -z "$(find "${RESTORE_TEST_ROOT}" -mindepth 1 -print -quit)" ]
printf 'alice changed\n' >"${TMP}/source/alice/file with spaces"
backup
SECOND="$(readlink -f "${BASE}/latest")"
[ "$(cat "${FIRST}/data/alice/file with spaces")" = 'alice original' ]
[ "$(stat -c %i "${FIRST}/data/bob/file")" = "$(stat -c %i "${SECOND}/data/bob/file")" ]
echo 'PASS: independent restore, filenames, symlinks, hardlinks and user isolation'

# Corruption and extra/missing files must fail, without deleting source files.
printf 'corruption\n' >"${SECOND}/data/alice/file with spaces"
fail backup verify
printf 'alice changed\n' >"${SECOND}/data/alice/file with spaces"
touch "${SECOND}/data/extra"
fail backup verify
rm "${SECOND}/data/extra"
mv "${SECOND}/data/alice/external" "${TMP}/saved-link"
fail backup verify
mv "${TMP}/saved-link" "${SECOND}/data/alice/external"
backup verify
echo 'PASS: corruption and inventory changes fail loudly'

# Failed copies preserve previous publication and retention.
printf '#!/bin/sh\nexit 23\n' >"${TMP}/bin/rsync"
chmod +x "${TMP}/bin/rsync"
fail backup
[ "$(readlink -f "${BASE}/latest")" = "${SECOND}" ]
[ -d "${FIRST}" ]
[ -z "$(find "${BASE}" -name '.partial.*' -print -quit)" ]
rm "${TMP}/bin/rsync"
mkfifo "${TMP}/source/fifo"
fail backup
rm "${TMP}/source/fifo"
VAULT_USERS_SOURCE="${BACKUP_MNT}" fail backup
# Shared lock prevents concurrent file/database jobs.
(
  exec 8>"${BACKUP_LOCK}"
  flock 8
  BACKUP_LOCK_WAIT_SECONDS=1 fail backup
)
echo 'PASS: failed copy, special files, overlap and concurrency preserve latest'

# A competing timer queues, then succeeds once the preceding job releases its lock.
(
  exec 8>"${BACKUP_LOCK}"
  flock 8
  touch "${TMP}/locked"
  sleep 2
) &
HOLDER=$!
while [ ! -e "${TMP}/locked" ]; do sleep 0.05; done
BACKUP_LOCK_WAIT_SECONDS=10 backup
wait "${HOLDER}"
echo 'PASS: competing backup waits for lock release instead of skipping its run'

# Simulate a one-time upload between manifest capture and the actual copy.
REAL_RSYNC="$(command -v rsync)"
export REAL_RSYNC
cat >"${TMP}/bin/rsync" <<'SH'
#!/bin/sh
if [ ! -e "$VAULT_USERS_SOURCE/.changed-once" ]; then
  printf 'new upload\n' >"$VAULT_USERS_SOURCE/.changed-once"
fi
exec "$REAL_RSYNC" "$@"
SH
chmod +x "${TMP}/bin/rsync"
backup
rm "${TMP}/bin/rsync"
cmp "${BASE}/latest/data/.changed-once" "${VAULT_USERS_SOURCE}/.changed-once"
backup verify
echo 'PASS: changing source retries a fresh complete copy and independent restore'

# Persistent mutations cannot publish or prune a known-good snapshot.
BEFORE="$(readlink "${BASE}/latest")"
cat >"${TMP}/bin/rsync" <<'SH'
#!/bin/sh
printf 'more changes\n' >>"$VAULT_USERS_SOURCE/.changed-once"
exec "$REAL_RSYNC" "$@"
SH
chmod +x "${TMP}/bin/rsync"
fail backup
rm "${TMP}/bin/rsync"
[ "$(readlink "${BASE}/latest")" = "${BEFORE}" ]
[ -z "$(find "${BASE}" -name '.partial.*' -print -quit)" ]
BACKUP_LOCK_WAIT_SECONDS=0 fail backup
echo 'PASS: exhausted capture retries preserve latest; invalid lock timeout fails'

# Legacy flat snapshots are usable link-dest sources and never pruned.
mkdir "${BASE}/2026-01-01_23-30-00"
rsync -aH "${TMP}/source/" "${BASE}/2026-01-01_23-30-00/"
ln -sfn 2026-01-01_23-30-00 "${BASE}/latest"
backup
[ -d "${BASE}/2026-01-01_23-30-00" ]
[ "$(find "${BASE}" -mindepth 1 -maxdepth 1 -name 'backup-*' -type d | wc -l)" -eq 2 ]
echo 'PASS: legacy migration and completed-snapshot retention'

CURRENT="$(readlink "${BASE}/latest")"
mkdir "${BASE}/backup-incomplete"
ln -sfn backup-incomplete "${BASE}/latest"
fail backup
ln -sfn "${CURRENT}" "${BASE}/latest"
rm -r "${BASE}/backup-incomplete"
echo 'PASS: incomplete new-format latest cannot be reused as a legacy snapshot'

# Simulate a flattened filesystem that accepts chmod but ignores mode changes.
chmod 0755 "${BASE}"
printf '#!/bin/sh\nexit 0\n' >"${TMP}/bin/chmod"
chmod +x "${TMP}/bin/chmod"
fail backup
rm "${TMP}/bin/chmod"
chmod 0700 "${BASE}"
echo 'PASS: incompatible destination permissions fail before backup bytes are written'

# Simulate an absent mount: must fail before a snapshot or host fallback write.
printf '#!/bin/sh\nexit 1\n' >"${TMP}/bin/mountpoint"
printf '#!/bin/sh\nexit 32\n' >"${TMP}/bin/mount"
chmod +x "${TMP}/bin/mount"
BEFORE="$(readlink "${BASE}/latest")"
fail backup
[ "$(readlink "${BASE}/latest")" = "${BEFORE}" ]
echo 'PASS: missing backup disk cannot silently write to host storage'
