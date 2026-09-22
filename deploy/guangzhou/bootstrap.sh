#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${AA_INSTALL_DIR:-/opt/agents-anywhere}"
SOURCE_REF="${AA_SOURCE_REF:-main}"
BASE_URL="${AA_DEPLOY_BASE_URL:-https://raw.githubusercontent.com/tevriqorg/Agents-Anywhere/${SOURCE_REF}/deploy/guangzhou}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 2
  }
}

require curl
require docker
require openssl
docker compose version >/dev/null

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this installer as root (for example: sudo bash bootstrap.sh)" >&2
  exit 2
fi

install -d -m 700 "$INSTALL_DIR"

fetch() {
  local name="$1"
  curl --fail --silent --show-error --location     "$BASE_URL/$name"     --output "$INSTALL_DIR/$name"
}

echo "Installing Guangzhou deployment files from $SOURCE_REF..."
fetch docker-compose.yml
fetch update.sh
fetch agents-anywhere-update.service
fetch agents-anywhere-update.timer

chmod 700 "$INSTALL_DIR/update.sh"
chmod 644   "$INSTALL_DIR/docker-compose.yml"   "$INSTALL_DIR/agents-anywhere-update.service"   "$INSTALL_DIR/agents-anywhere-update.timer"

if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  fetch .env.example
  postgres_password="$(openssl rand -hex 32)"
  server_secret="$(openssl rand -hex 48)"

  sed     -e "s/replace-with-a-long-random-password/$postgres_password/"     -e "s/replace-with-a-long-random-secret/$server_secret/"     "$INSTALL_DIR/.env.example" > "$INSTALL_DIR/.env"

  chmod 600 "$INSTALL_DIR/.env"
  rm -f "$INSTALL_DIR/.env.example"
  unset postgres_password server_secret
  echo "Created a new private .env with generated secrets."
else
  echo "Existing $INSTALL_DIR/.env preserved."
fi

echo "Running first image pull / migration / health check..."
"$INSTALL_DIR/update.sh"

install -m 644   "$INSTALL_DIR/agents-anywhere-update.service"   /etc/systemd/system/agents-anywhere-update.service
install -m 644   "$INSTALL_DIR/agents-anywhere-update.timer"   /etc/systemd/system/agents-anywhere-update.timer

systemctl daemon-reload
systemctl enable --now agents-anywhere-update.timer

echo
echo "Agents Anywhere is healthy on VPS localhost."
echo "Local URL: http://127.0.0.1:5174"
echo "Automatic image checks: enabled (hourly)."
echo
echo "Tailscale Serve was intentionally NOT modified."
echo "Inspect existing routes first:"
echo "  tailscale serve status"
echo "Then, if port 8443 is free, expose AA privately with:"
echo "  tailscale serve --https=8443 --bg localhost:5174"
echo
echo "The first-admin setup token remains only in local Server logs."
echo "Read it privately on the VPS with:"
echo "  cd $INSTALL_DIR && docker compose --env-file .env -f docker-compose.yml logs server-next"
