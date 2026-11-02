#!/usr/bin/env bash
set -euo pipefail

# Installs the official Gatus release binary. Pin GATUS_VERSION explicitly.
GATUS_VERSION="${GATUS_VERSION:-v5.15.0}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ASSET_ARCH="amd64" ;;
  aarch64|arm64) ASSET_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script with sudo/root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
umask 077
# Release assets are distributed as a tar.gz archive, not a bare executable.
ASSET="gatus-linux-$ASSET_ARCH"
URL="https://github.com/TwiN/gatus/releases/download/$GATUS_VERSION/$ASSET.tar.gz"

curl --fail --location --silent --show-error "$URL" -o "$TMP_DIR/gatus.tar.gz"
tar -xzf "$TMP_DIR/gatus.tar.gz" -C "$TMP_DIR"
if [[ ! -f "$TMP_DIR/gatus" ]]; then
  echo "The release archive did not contain the expected gatus binary." >&2
  exit 1
fi
install -o root -g root -m 0755 "$TMP_DIR/gatus" /usr/local/bin/gatus

if ! getent group gatus >/dev/null; then
  groupadd --system gatus
fi
if ! id gatus >/dev/null 2>&1; then
  useradd --system --gid gatus --home-dir /var/lib/gatus --no-create-home --shell /usr/sbin/nologin gatus
fi

install -d -o root -g gatus -m 0750 /etc/gatus
install -d -o gatus -g gatus -m 0750 /var/lib/gatus
install -o root -g root -m 0644 "$SCRIPT_DIR/config.yaml" /etc/gatus/config.yaml
install -o root -g root -m 0644 "$SCRIPT_DIR/gatus.service" /etc/systemd/system/gatus.service

if [[ ! -f /etc/gatus/gatus.env ]]; then
  install -o root -g gatus -m 0640 "$SCRIPT_DIR/gatus.env.example" /etc/gatus/gatus.env
  echo "Created /etc/gatus/gatus.env. Set your real user-facing URLs."
else
  echo "Keeping existing /etc/gatus/gatus.env"
fi

systemctl daemon-reload
echo "Gatus installed. Edit /etc/gatus/gatus.env, then run: systemctl enable --now gatus"
