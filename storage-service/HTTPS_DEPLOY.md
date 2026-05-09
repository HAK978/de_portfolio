# Storage service: HTTPS deployment

The VM currently serves the storage API over plain HTTP, with the
API key sent as a request header in cleartext. Anyone on the network
path between phone and VM (open Wi-Fi, MITM, ISP) can sniff the key
and replay requests.

This guide walks through putting Caddy in front of the existing
Express service so traffic to the VM is TLS-encrypted, with the
API key flowing inside the encrypted tunnel. Caddy auto-issues and
renews a Let's Encrypt certificate.

## What you'll do

1. Reserve a static external IP on GCE (~5 min)
2. Point a domain at the VM (~10 min)
3. Install Caddy and write a tiny config file (~10 min)
4. Open port 443 in the GCE firewall (~5 min)
5. Update the Flutter app's default storage URL (~2 min)

Total: ~30–45 minutes, mostly waiting for DNS to propagate.

---

## 1. Reserve a static external IP

The VM currently has an *ephemeral* external IP (`34.44.97.110`),
which can change on VM restart. Let's Encrypt certs are tied to a
domain, and the domain points to a specific IP — if the IP rotates
your TLS breaks.

1. Open Google Cloud Console → **VPC network** → **IP addresses**
2. Find the row for `cs2-storage` (look for the `External` IP that
   matches the current ephemeral IP)
3. Click the row's three-dot menu → **Promote to static**
4. Name it `cs2-storage-ip`. Confirm.

Cost: $0 while attached to a running VM (Always Free tier).

---

## 2. Point a domain at the VM

You need a DNS A record pointing at the static IP. Two options:

### Option A: free subdomain on a service like DuckDNS

Quickest. No domain purchase.

1. Go to https://www.duckdns.org/ → sign in with GitHub/Google
2. Pick a subdomain like `cs2-storage-yourname` → ".duckdns.org"
3. Set the IP to the static IP from step 1
4. Save

Your VM is now reachable at `cs2-storage-yourname.duckdns.org`.

### Option B: existing domain (Namecheap, Cloudflare, etc.)

If you already own a domain (`yourdomain.com`), add an A record:

| Type | Host | Value | TTL |
|------|------|-------|-----|
| A    | `vm` | `34.44.97.110` (static IP) | Automatic |

Subdomain becomes `vm.yourdomain.com`.

### Verify DNS is live

From your laptop:

```bash
nslookup cs2-storage-yourname.duckdns.org
```

Should return your static IP. May take 5–10 min after the DNS change.

---

## 3. Install Caddy and configure

SSH into the VM (`gcloud compute ssh cs2-storage` or the browser
SSH button), then:

```bash
# Add Caddy's apt repo (one-time)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

Now write the Caddy config. Replace `cs2-storage-yourname.duckdns.org`
with whatever domain you pointed at the IP in step 2:

```bash
sudo tee /etc/caddy/Caddyfile > /dev/null <<'EOF'
cs2-storage-yourname.duckdns.org {
    # Forward all requests to the existing Express service on
    # localhost:3456. Caddy handles TLS termination automatically
    # (Let's Encrypt cert auto-issued + auto-renewed).
    reverse_proxy localhost:3456
}
EOF
```

Restart Caddy to pick up the config:

```bash
sudo systemctl restart caddy
sudo systemctl status caddy
```

The first restart will fetch a Let's Encrypt cert, which takes 30–60
seconds. Watch the logs:

```bash
sudo journalctl -u caddy -f --no-pager
```

You should see lines about ACME challenge succeeded and a cert being
saved.

---

## 4. Open port 443 in GCE firewall

The existing `allow-cs2` rule only opens port 3456. Caddy listens on
443 (HTTPS) and 80 (HTTP, for ACME challenges) — both need to be open.

In Google Cloud Console → **VPC network** → **Firewall**:

1. Find the `default-allow-https` rule. If it doesn't exist:
   - Click **Create firewall rule**
   - Name: `allow-https-cs2`
   - Targets: `All instances in the network` (or tag-target the VM)
   - Source IPv4 ranges: `0.0.0.0/0`
   - Protocols and ports: `tcp:443, tcp:80`
   - Save
2. Optionally remove `tcp:3456` from `allow-cs2` so port 3456 is no
   longer reachable from the public internet — Caddy is the only
   thing that needs to talk to it now, over `localhost`. **Don't
   skip this** — it's the whole point: making 3456 unreachable
   externally means the API key can ONLY arrive over TLS.

Test from your laptop:

```bash
curl https://cs2-storage-yourname.duckdns.org/status
```

Should return `{"steam":true,"gc":false,...}` (or similar). If
`-k` is needed to bypass cert validation, the cert isn't ready yet
— wait a minute and re-try.

---

## 5. Update the Flutter app's default URL

The default URL in `lib/providers/storage_provider.dart` still points
at the plaintext HTTP IP. Edit:

```dart
// before
return 'http://34.44.97.110:3456';

// after
return 'https://cs2-storage-yourname.duckdns.org';
```

Then on your phone, in **Settings → Storage Service**, change the URL
to the new HTTPS address and tap Save. (The default only applies on
fresh installs; existing installs keep their saved URL.)

Build and install a fresh APK so the default is the HTTPS URL for
anyone who ever installs from a fresh state.

---

## After-checks

- `curl http://34.44.97.110:3456/status` should now **fail** (port
  3456 closed externally) — confirms the plaintext path is gone
- `curl https://cs2-storage-yourname.duckdns.org/status` returns 200
- Phone app's Storage tab shows the green "GC Connected" dot
- Settings → Storage Service shows the HTTPS URL

If anything's broken: SSH in, `sudo systemctl status caddy` for
the proxy, `sudo systemctl status cs2-storage` for the Express
service. Both should be green.

## Renewals

Caddy auto-renews the cert ~30 days before expiry. No cron, no
ops. If the VM's been off for >90 days the cert may expire — first
boot Caddy will re-issue automatically.
