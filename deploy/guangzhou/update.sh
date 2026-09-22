#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: $SCRIPT_DIR/.env does not exist" >&2
  exit 2
fi

# .env is administrator-owned and contains only shell-compatible KEY=VALUE entries.
set -a
# shellcheck disable=SC1091
source .env
set +a

IMAGE="${AA_IMAGE:-ghcr.io/tevriqorg/agents-anywhere-server:main}"
STATE_DIR="${AA_STATE_DIR:-$SCRIPT_DIR/state}"
LOCK_FILE="${AA_UPDATE_LOCK:-/tmp/agents-anywhere-update.lock}"
mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Agents Anywhere update is already running; exiting."
  exit 0
fi

compose() {
  docker compose --env-file "$SCRIPT_DIR/.env" -f "$SCRIPT_DIR/docker-compose.yml" "$@"
}

running_container="$(compose ps -q server-next 2>/dev/null || true)"
running_image_id=""
running_health=""
if [[ -n "$running_container" ]]; then
  running_image_id="$(docker inspect --format '{{.Image}}' "$running_container" 2>/dev/null || true)"
  running_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$running_container" 2>/dev/null || true)"
fi

echo "Pulling $IMAGE (Docker will reuse unchanged OCI layers)..."
docker pull "$IMAGE"
new_image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"

if [[ -n "$running_image_id" && "$running_image_id" == "$new_image_id" && "$running_health" == "healthy" ]]; then
  echo "No image change and server is healthy: $new_image_id"
  exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
{
  echo "timestamp=$timestamp"
  echo "previous_running_image_id=$running_image_id"
  echo "previous_running_health=$running_health"
  echo "target_image=$IMAGE"
  echo "target_image_id=$new_image_id"
} > "$STATE_DIR/update-$timestamp.env"

if [[ -n "$running_image_id" && "$running_image_id" == "$new_image_id" ]]; then
  echo "Image is unchanged but the current server is not healthy; recreating it without a database migration."
  compose up -d postgres-next redis-next
  compose up -d --no-deps --force-recreate server-next
else
  echo "Image changed; preparing safe stop-migrate-start update."
  compose up -d postgres-next redis-next

  # Some upstream schema revisions are explicitly not safe with old writers online.
  if [[ -n "$running_container" ]]; then
    compose stop server-next
  fi

  echo "Running database migrations with the new image..."
  if ! compose run --rm migrate-next; then
    echo "ERROR: migration failed. Server remains stopped; inspect database/migration state before recovery." >&2
    exit 1
  fi

  echo "Starting new server image..."
  compose up -d --no-deps --force-recreate server-next
fi

container_id="$(compose ps -q server-next)"
deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
  case "$health" in
    healthy)
      echo "$new_image_id" > "$STATE_DIR/current-image-id"
      echo "Server is healthy: $new_image_id"
      exit 0
      ;;
    unhealthy)
      echo "ERROR: server became unhealthy." >&2
      compose logs --tail=120 server-next >&2 || true
      exit 1
      ;;
  esac
  sleep 3
done

echo "ERROR: health check timed out." >&2
compose logs --tail=120 server-next >&2 || true
exit 1
