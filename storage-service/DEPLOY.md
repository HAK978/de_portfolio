# Storage Service — GCE Deployment Config

## VM Instance
- **Name:** cs2-storage
- **Project:** cs2-portfolio
- **Region/Zone:** us-central1-a
- **Machine type:** e2-micro (2 vCPU shared, 1GB RAM)
- **Boot disk:** Ubuntu 22.04 LTS x86/64, 10GB standard persistent disk
- **Firewall:** Allow HTTP traffic
- **Cost:** $0/month (Always Free tier: 1 e2-micro + 30GB disk in us-central1)

## Free Tier Limits
- 1 e2-micro instance in us-central1, us-west1, or us-east1
- 30GB standard persistent disk
- 1GB network egress/month
- Free tier continues after $300 trial ends

## Environment Variables (set on VM)
- `PORT` — defaults to 3456
- `REFRESH_TOKEN` — Steam refresh token (generate locally, paste as env var)
- `API_KEY` — shared secret between app and server

## How It Works
- VM runs 24/7, stays logged into Steam + connected to CS2 Game Coordinator
- Flutter app points to VM's external IP instead of localhost
- API key in X-Api-Key header authenticates requests
- No laptop needed — app is fully standalone

## When You Need to Touch the VM
- Steam refresh token expires (rare, months) — generate new one locally, update env var
- Code update — SSH in, git pull, restart service
- VM stops (shouldn't happen, but check if storage tab stops working)

## Local Dev (unchanged)
- Run `node index.js` locally, no env vars needed
- No API key = no auth check
- App points to http://localhost:3456 via adb reverse
