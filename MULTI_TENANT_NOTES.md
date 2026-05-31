# Multi-tenant storage units — analysis and decision

As of 2026-05-12, after the v1.2.0 release and the HTTPS migration to
`harshcs2.duckdns.org`.

## TL;DR

The Storage tab in this app works only for me (Harsh). Everything else —
inventory, Steam Market + CSFloat prices, charts, sorting, comparison,
drop-pool indicators — works for any Steam user who installs the APK.

Making Storage multi-tenant is technically possible but architecturally
pivots from "mobile app + cloud" to "mobile app + each user runs a local
backend." The pure-cloud path violates Steam ToS, gets IP-flagged, and
turns the VM into a high-value attack target. Skinledger (from Casemove's
creator) made the same architectural call — desktop helper, not cloud.

For now: keep it single-tenant. If multi-tenant ever matters, the Docker
self-host path is the cheapest entry point.

---

## What works for who (current state)

**Works for anyone who installs the APK:**

- Steam OpenID login → Cloud Function `createCustomToken` → Firebase auth
- Inventory fetch via Steam Web API
- Steam Market prices (public)
- CSFloat prices (user provides their own CSFloat API key in Settings)
- All UI: charts, sorting, comparison, drop-pool indicators, etc.
- App Check gating Cloud Function abuse

**Works only for me:**

- Storage tab (casket list, casket contents, per-storage-unit totals)
- Per-storage-item float values (these come from the GC, not CSFloat)

Inventory floats are publicly accessible via CSFloat's API given an
inspect link, so those work for any user. Storage floats are GC-only.

---

## Why storage units are single-tenant

CS2 storage unit contents are not exposed by the Steam Web API. The only
way to read them is to open an authenticated session to the CS2 Game
Coordinator (GC), which requires running the Steam client protocol
(`node-steam-user` + `node-globaloffensive`).

A GC connection is bound to one Steam account at a time, in one Node
process at a time.

Today, `storage-service/index.js` runs on a GCE e2-micro VM
(`cs2-storage`, static IP `34.44.97.110`, reachable at
`https://harshcs2.duckdns.org` since 2026-05-11). At startup it loads a
Steam refresh token from `.refresh_token` and logs in as me. All
`/caskets`, `/caskets/:id`, `/float/:id` endpoints use that one Steam
session. Anyone calling those endpoints (with the correct API key) gets
**my** storage units, not theirs.

The phone↔VM API key authenticates the network call. It doesn't change
whose Steam account the GC connection is bound to.

---

## The IP fingerprinting problem

Steam tracks logins per IP for abuse detection. A "normal" IP shows one
account with occasional logins. A "suspicious" IP shows many accounts
logging in repeatedly from a datacenter — that's the signature of an
account farm or stolen-credential resale operation.

Right now my VM's IP looks normal to Steam: one account (mine),
persistent refresh-token session, almost never re-logs unless the VM
restarts.

If I were to host 20+ users' Steam sessions on the same VM IP:

1. Steam rate-limits logins → users see "RateLimitExceeded" → blame the
   app, not Steam
2. Steam throttles all traffic from the IP → storage loads slow or fail
3. Eventually the IP is banned → all users lose access simultaneously
4. Some users' Steam accounts flagged "suspicious" → their normal Steam
   life gets harder because of my app

Workarounds all fail:

- **Rotating VM IPs** looks like evasion to Steam, cracked down on harder
- **Residential proxies** violate Steam ToS, are expensive (~$10-100/mo
  for usable bandwidth), and slow
- **One VM per user** would clean up the IP fingerprint, but GCE
  e2-micro is only $0 for the *first* one — every subsequent VM is
  ~$5-7/mo. 20 users = $100+/mo for a free portfolio app

The IP honestly represents one user. Beyond that, Steam treats it as a
bad actor.

### Why a desktop helper sidesteps this

In the current cloud setup, the Steam protocol connection originates
from the VM:

```
[phone, IP=A] ──HTTPS──> [VM, IP=B] ──Steam protocol──> [Steam servers]
                                     ^^^^^^^^^^^^^^^^^
                                     Steam only sees IP=B
```

In a desktop-helper setup, the Steam protocol connection originates from
the user's own machine:

```
[phone, IP=A] ──LAN/tunnel──> [user's PC, IP=C] ──Steam protocol──> [Steam servers]
                                                  ^^^^^^^^^^^^^^^^^
                                                  Steam sees IP=C
                                                  (user's home/office IP)
```

Each user's home IP is unique. To Steam, each user looks like a normal
Steam customer logging in from their own internet connection — which is
what they are. The phone's IP is irrelevant because the phone never
speaks the Steam protocol directly; it always goes through whatever
machine is running `node-steam-user`.

The single architectural lever: **where does the `node-steam-user`
process physically live?** That determines the IP Steam sees. With a
cloud VM it's you. With a desktop helper it's each user.

---

## What we currently store

**On the VM** (`/home/harshavinashkute/de_portfolio/storage-service/`):

- `.refresh_token` — Steam refresh token for my account, used by
  `user.logOn({ refreshToken })` on every VM start/reconnect. Auto-renews
  while the token is in use.
- `.env` — phone↔VM API key + `PORT=3456`. Unrelated to Steam.

**On the phone:**

- Storage-service URL (`https://harshcs2.duckdns.org` after v1.2.0)
- Storage-service API key (in Android Keystore as of v1.2.0)
- **No Steam credentials, no Steam refresh token**

**Initial setup (one-time):** I ran `node index.js` interactively on the
VM once, entered username/password/Steam Guard code at the stdin prompt
(see `storage-service/index.js:231` `interactiveLogin()`). Password lived
only in process memory for that one run, was never persisted. From then
on, every restart logs in with the refresh token alone.

---

## Multi-tenant options analyzed

### Option A — Cloud refresh tokens per user

Each user signs up, does interactive Steam login through my VM once,
their refresh token persists on my VM under their account.

**What this fixes:**

- Steam Guard friction (only prompts on enrollment, not per session)

**What it doesn't fix:**

1. **IP fingerprinting** — all users still come from one VM IP. The
   whole IP-flagging cascade above still happens.
2. **ToS violation** — Steam Subscriber Agreement forbids third parties
   from accessing accounts on a user's behalf. A refresh token sitting
   on my server *is* third-party access.
3. **High-value attack target** — one VM compromise = N stolen Steam
   accounts. Refresh tokens are functionally equivalent to passwords:
   the holder can log in, read messages, modify trades, drain
   inventories, get accounts VAC-banned.
4. **Enrollment still transmits passwords** — even though I don't
   *store* them, the interactive login flow requires the user's
   username/password to traverse my server. Any bug (error trace,
   logging middleware, memory dump) leaks credentials. I'd need to be
   airtight forever from day one.
5. **Concurrency cost** — `node-steam-user` is one Steam session per
   process. N concurrent users = N processes on an e2-micro. Memory
   and port management get real.
6. **Token expiry** — refresh tokens last ~30-200 days. Returning users
   find their tokens expired and have to re-enroll. Recovery flow
   needed.
7. **Skinledger's creator considered this and rejected it.** The person
   closest to the problem domain chose desktop helper instead. Strongest
   precedent against this option.

**Verdict:** Not viable.

### Option B — Docker self-host (recommended starting point)

Package the existing `storage-service/` code in a Dockerfile. Publish as
`hak978/cs2-storage:latest` on Docker Hub.

Each user runs:

```
docker run -p 3456:3456 -v cs2-tokens:/app/.tokens hak978/cs2-storage
```

The container prompts for Steam login interactively the first time,
persists the refresh token to the named volume. User opens the mobile
app → Settings → Storage Service URL = `http://<their-PC-IP>:3456` for
LAN access, or via Tailscale / WireGuard for remote access.

**Pros:**

- ~95% of existing code unchanged
- No new UI to build
- Steam sees each user's home IP — looks normal, no flagging
- No ToS issue (each user runs their own backend)
- No credentials touch my infrastructure at all

**Cons:**

- Audience limited to users comfortable with Docker
- No mobile-friendly UI for "my PC is off and I'm out of the house"
- Pairing UX is manual (copy URL into mobile Settings)

**Effort:** ~one weekend.

### Option C — Electron desktop helper (Skinledger model)

Wrap the same `storage-service/` code in an Electron app, like Casemove.
Native Windows/Mac/Linux installers. Small UI window: connection
status, "log in to Steam" button, generated URL+API key with a copy
button or QR code. Mobile app gets a "Pair with helper" wizard with QR
scanner that auto-fills URL + API key.

**Pros:**

- Same architecture as Skinledger — proven for this exact problem
- Friendly for non-developers
- True "double-click and run" experience
- Best portfolio narrative: "I built a mobile app + a companion desktop
  app and used a hybrid architecture to bypass cloud multi-tenant
  constraints"

**Cons:**

- Real desktop development project (Electron build, signing, installers)
- Multiple weekends of work
- Code-signing certs cost money (~$100/yr for Windows, free-ish for Mac
  via Apple Developer)

**Effort:** 2-3 weekends.

---

## Recommendation

**Keep it single-tenant for now.** The portfolio story is already strong
without multi-tenant: "I built this; the storage tab is single-tenant by
design because cloud multi-tenant violates Steam ToS, gets IP-flagged,
and concentrates attack risk. Skinledger came to the same conclusion."
That kind of architectural-tradeoff reasoning is exactly what senior
interviews are looking for.

If multi-tenant ever becomes a real goal, **start with Option B
(Docker)**. About a weekend of work, no new project, captures the
developer audience. Only escalate to Option C (Electron) if there's
actual demand from non-developer users — building Electron just for the
narrative isn't worth multiple weekends.

---

## Files and code references

- `lib/providers/storage_provider.dart:26` — default storage-service URL
- `lib/screens/settings/settings_screen.dart:352` — Settings → Storage Service hint
- `storage-service/index.js:231` — `interactiveLogin()` (one-time Steam Guard flow)
- `storage-service/index.js:300` — `loginWithToken()` (refresh-token login)
- `storage-service/index.js:485-533` — bootstrap: env var → file → interactive
- `storage-service/HTTPS_DEPLOY.md` — Caddy/HTTPS migration (executed 2026-05-11)
- `storage-service/DEPLOY.md` — original GCE VM deployment

## External references

- [node-steam-user](https://github.com/DoctorMcKay/node-steam-user) — Steam client protocol library
- [node-steam-session](https://github.com/DoctorMcKay/node-steam-session) — refresh-token / machine-auth flow
- [McKay refresh-token how-to](https://dev.doctormckay.com/topic/4228-login-via-refresh-token/)
- [Casemove (unmaintained)](https://github.com/nombersDev/casemove) — original desktop storage manager
- [CratesMove (active successor)](https://github.com/ByMykel/cratesmove) — same model, maintained
- [Skinledger](https://skinledger.com/) — hybrid web+desktop, by Casemove's creator
