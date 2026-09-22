# Guangzhou VPS private deployment

This deployment profile is intentionally separate from the upstream development
Compose file.

## Design

- GitHub Actions builds the `server` target from `docker/Dockerfile`.
- The image is published as `ghcr.io/tevriqorg/agents-anywhere-server:main`
  plus an immutable `sha-<commit>` tag.
- The Guangzhou VPS does **not** build Node/Python source.
- PostgreSQL and Redis are private Docker services.
- Agents Anywhere binds only to `127.0.0.1:5174` on the VPS.
- Tailscale Serve is expected to provide the tailnet-only HTTPS entry point.
- `update.sh` pulls the image first. Docker only downloads changed OCI layers.
  If the running container already uses the pulled image ID and is healthy,
  nothing restarts.
- When the image changes, the updater performs a stop → migrate → start sequence,
  because upstream migrations may prohibit old and new writers from running
  concurrently.

## 1. GHCR

The workflow at `.github/workflows/server-image.yml` publishes on changes to
the Server, Web frontend, Dockerfile, or the workflow itself.

The first GHCR package may be private depending on organization package settings.
Either make the package public (the source repository is already public), or log
the VPS into GHCR with a token that has `read:packages`.

If the systemd timer below runs as root and the package remains private, perform
the registry login as root as well:

```bash
echo "$GHCR_TOKEN" | sudo docker login ghcr.io -u <github-user> --password-stdin
```

Package visibility and network exposure are separate: a public image does not
make the running Agents Anywhere service public.

## 2. Install deployment files on the VPS

Create the deployment directory:

```bash
sudo mkdir -p /opt/agents-anywhere
sudo chown "$USER":"$USER" /opt/agents-anywhere
```

Copy these files from this directory to `/opt/agents-anywhere/`:

- `docker-compose.yml`
- `.env.example` as `.env`
- `update.sh`

Then:

```bash
cd /opt/agents-anywhere
chmod 700 update.sh
chmod 600 .env
```

Generate strong URL-safe values and edit `.env`. Hex avoids password URL
escaping problems in the PostgreSQL connection string:

```bash
openssl rand -hex 32
openssl rand -hex 48
```

Do not commit the resulting `.env`.

## 3. First deployment

Run:

```bash
cd /opt/agents-anywhere
./update.sh
```

The first run pulls the image, starts PostgreSQL/Redis, migrates the empty
database, starts the Server, and waits for the container health check.

Verify locally on the VPS:

```bash
curl -fsS http://127.0.0.1:5174/api/v2/health
docker compose --env-file .env -f docker-compose.yml ps
```

Obtain the first-admin setup token from the Server logs:

```bash
docker compose --env-file .env -f docker-compose.yml logs server-next
```

## 4. Tailnet-only access

Keep port 5174 bound to VPS localhost. Do not publish it in the public firewall.

Expose it through Tailscale Serve:

```bash
sudo tailscale serve --bg localhost:5174
tailscale serve status
```

Use the resulting HTTPS `.ts.net` address from Web/Desktop/mobile clients.

If OAuth is later enabled, set `AGENT_SERVER_PUBLIC_ORIGIN` in `.env` to that
HTTPS origin.

## 5. Automatic image updates

Install the supplied systemd units:

```bash
sudo cp agents-anywhere-update.service /etc/systemd/system/
sudo cp agents-anywhere-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now agents-anywhere-update.timer
systemctl list-timers agents-anywhere-update.timer
```

The default check interval is one hour. A no-change/healthy check does not
recreate the Server. Concurrent updater runs are prevented with `flock`.

## Failure boundary

The updater deliberately does **not** automatically downgrade the database or
roll back to the old Server image after a successful migration. Upstream has
schema revisions where old/new writers are not compatible and downgrades can be
unsafe. Update state, including the previous running image ID, is written under
`state/` for diagnosis.

If migration fails, the Server remains stopped so an operator can inspect the
database and migration output instead of automatically starting an incompatible
writer.

By ChatGPT
