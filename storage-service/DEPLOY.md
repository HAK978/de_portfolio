# Storage Service — GCE Deployment Config

## VM Instance
- **Name:** cs2-storage
- **Project:** cs2-portfolio
- **Region/Zone:** us-central1-a
- **Machine type:** e2-micro (2 vCPU shared, 1GB RAM)
- **Boot disk:** Ubuntu 22.04 LTS x86/64, 10GB standard persistent disk
- **Firewall:** tcp:80/443 only (Caddy). The Express port is not exposed.
- **Cost:** $0/month (Always Free tier: 1 e2-micro + 30GB disk in us-central1)

## Free Tier Limits
- 1 e2-micro instance in us-central1, us-west1, or us-east1
- 30GB standard persistent disk
- 1GB network egress/month
- Free tier continues after $300 trial ends

## Environment Variables (`storage-service/.env`, mode 600)
- `API_KEY` — **required.** Shared secret the app sends as `X-Api-Key`.
  The service refuses to start without it. Generate one with
  `openssl rand -hex 32`.
- `PORT` — defaults to 3456
- `HOST` — defaults to `127.0.0.1`. Caddy proxies from localhost, so the
  service never listens on a public interface. Use `0.0.0.0` only for
  LAN development.
- `REFRESH_TOKEN` — optional. Only used when `.refresh_token` doesn't
  exist yet (the file always wins, see below).
- `ALLOW_NO_AUTH=1` — local development only: run without an API key.

## How It Works
- VM runs 24/7 and stays logged in to Steam. The CS2 Game Coordinator is
  only joined while a request needs it (so no fake playtime accrues).
- Caddy terminates HTTPS at `https://harshcs2.duckdns.org` and proxies to
  `localhost:3456` (see HTTPS_DEPLOY.md). `/metrics` is blocked publicly
  and scraped locally by Grafana Alloy.
- The app authenticates with the `X-Api-Key` header (compared in constant
  time).

## Steam Refresh Token
- Stored in `storage-service/.refresh_token` (mode 600). Treat it like the
  account password: it can log in to Steam as the owner.
- Tokens last ~200 days. Every logon asks Steam to renew it, and once a
  day the service checks the expiry. Within 30 days of expiry it logs off
  and back on so Steam can issue a new token, which is saved atomically.
- The expiry is exported as `cs2_storage_refresh_token_expiry_timestamp_seconds`
  so Grafana can alert before it lapses.
- A failed login never deletes the token. The service exits and systemd
  restarts it (transient failures like Steam maintenance recover on
  their own).

## When You Need to Touch the VM
- **Token expired / revoked** (logs show `Login failed` on every restart):
  ```bash
  sudo systemctl stop cs2-storage
  cd ~/de_portfolio/storage-service && node index.js   # prompts for login + Steam Guard
  # Ctrl+C once it says "Storage service running", then:
  sudo systemctl start cs2-storage
  ```
  Run it with the same `.env` values exported (`set -a; . ./.env; set +a`).
- **Code update** — pushing `storage-service/**` to `main` runs the
  "Deploy storage-service" GitHub Action (git pull, `npm ci`, restart).
- **Rotate the API key** — update `API_KEY` in `.env`, restart the
  service, then paste the new key into the app (Settings → Storage).
- **VM stopped** (e.g. billing lapsed) — see the recovery notes in the
  project docs; the VM does not auto-start.

## Local Dev
- `ALLOW_NO_AUTH=1 node index.js` (or set `API_KEY` and enter the same key in the app)
- First run prompts for a Steam login and writes `.refresh_token`
- App points to `http://localhost:3456` via `adb reverse tcp:3456 tcp:3456`
- `npm test` runs the API, token and item-resolver tests (no Steam needed)
