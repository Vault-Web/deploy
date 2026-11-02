#!/usr/bin/env bash
set -euo pipefail

# Install the official Gatus binary from its pinned Go module version.
GATUS_VERSION="${GATUS_VERSION:-v5.15.0}"
MIN_GO_VERSION="1.23.3"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script with sudo/root." >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Go >= ${MIN_GO_VERSION} is required to install Gatus." >&2
  exit 1
fi

GO_VERSION="$(go version | awk '{print $3}' | sed 's/^go//')"
if [[ "$(printf '%s\n' "$MIN_GO_VERSION" "$GO_VERSION" | sort -V | head -n1)" != "$MIN_GO_VERSION" ]]; then
  echo "Go >= ${MIN_GO_VERSION} is required; found ${GO_VERSION}." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
umask 077

mkdir -p "$TMP_DIR/bin"

CGO_ENABLED=0 GOBIN="$TMP_DIR/bin" \
  go install "github.com/TwiN/gatus/v5@${GATUS_VERSION}"

if [[ ! -x "$TMP_DIR/bin/gatus" ]]; then
  echo "Gatus binary installation failed." >&2
  exit 1
fi

install -o root -g root -m 0755 "$TMP_DIR/bin/gatus" /usr/local/bin/gatus

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
