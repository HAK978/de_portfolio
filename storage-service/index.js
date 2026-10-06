// Storage service entry point: owns the Steam + Game Coordinator
// session and serves the HTTP API from app.js.

const SteamUser = require('steam-user');
const GlobalOffensive = require('globaloffensive');
const { LoginSession, EAuthTokenPlatformType } = require('steam-session');
const path = require('path');
const readline = require('readline');
const ItemResolver = require('./itemResolver');
const metrics = require('./metrics');
const { createApp } = require('./app');
const { readToken, writeToken, tokenExpiryMs, shouldRenew } = require('./token');

// ── Config (env vars; see DEPLOY.md) ──────────────────────
const PORT = Number(process.env.PORT) || 3456;
// Loopback by default: Caddy terminates TLS on the same machine and
// proxies to localhost. Set HOST=0.0.0.0 only for LAN development.
const HOST = process.env.HOST || '127.0.0.1';
const API_KEY = process.env.API_KEY || '';
const ALLOW_NO_AUTH = process.env.ALLOW_NO_AUTH === '1';
const REFRESH_TOKEN_ENV = process.env.REFRESH_TOKEN || '';
const TOKEN_FILE = path.join(__dirname, '.refresh_token');

const itemResolver = new ItemResolver();

// ── Steam & GC instances ──────────────────────────────────
// renewRefreshTokens: on each logOn Steam may issue a fresh refresh
// token (it does when the current one nears expiry). The old token stops
// working at that point, so the 'refreshToken' handler below must save
// the new one.
const user = new SteamUser({ renewRefreshTokens: true });
const csgo = new GlobalOffensive(user);
let isLoggedIn = false;
let isGCConnected = false;
let isBlocked = false; // real Steam client is currently playing CS2
let steamDisplayName = '';
let currentRefreshToken = '';

// On-demand GC: we only set gamesPlayed([730]) while a request needs
// GC, then drop it after [GC_IDLE_MS] of inactivity. Without this,
// having the VM logged in 24/7 with gamesPlayed([730]) accrues fake
// CS2 playtime on the user's profile.
const GC_IDLE_MS = 30 * 1000;
let gcIdleTimer = null;
// Number of in-flight GC operations (e.g. casket fetches). The idle
// timer must not release the GC while this is > 0 — a large casket can
// take 30-60s to enumerate, longer than GC_IDLE_MS, and dropping the
// game session mid-fetch aborts the request.
let gcBusyCount = 0;

function updateTokenExpiryMetric() {
  const expiry = tokenExpiryMs(currentRefreshToken);
  if (expiry !== null) metrics.refreshTokenExpiry.set(expiry / 1000);
}

// ── Steam event handlers ──────────────────────────────────

user.on('loggedOn', () => {
  console.log('[Steam] Logged in successfully');
  isLoggedIn = true;
  metrics.steamLoggedIn.set(1);
  // Intentionally do NOT call gamesPlayed([730]) here. GC is brought
  // up on demand by ensureGCConnected() when an API request needs it.
});

user.on('refreshToken', (token) => {
  currentRefreshToken = token;
  try {
    writeToken(TOKEN_FILE, token);
    console.log('[Auth] Steam renewed the refresh token — saved');
  } catch (err) {
    // The renewed token is still used in memory until the next restart.
    console.error('[Auth] Could not save the renewed refresh token:', err.message);
  }
  updateTokenExpiryMetric();
});

user.on('accountInfo', (name) => {
  steamDisplayName = name;
  console.log(`[Steam] Account: ${name}`);
});

// When the real Steam client starts/stops playing CS2, track it so
// ensureGCConnected() can refuse rather than fight the user's
// foreground session. We never auto-resume — next API request will
// re-enter the play state if appropriate.
user.on('playingState', (blocked, playingApp) => {
  isBlocked = blocked;
  if (blocked) {
    console.log(`[Steam] Real client started playing ${playingApp} — yielding`);
    user.gamesPlayed([]);
    cancelIdleTimer();
  } else {
    console.log('[Steam] Real client stopped playing — VM available on demand');
  }
});

// Coalesce reconnect attempts: if `LoggedInElsewhere` (eresult 6)
// fires repeatedly within the 30s window, only one timer is active.
// Without this, multiple stacked `setTimeout`-driven `user.logOn`
// calls can race the watchdog and pile up reconnects.
let reconnectTimer = null;

user.on('error', (err) => {
  console.error('[Steam] Error:', err.message);
  isLoggedIn = false;
  isGCConnected = false;

  // LoggedInElsewhere is fatal — autoRelogin won't handle it.
  if (err.eresult === SteamUser.EResult.LoggedInElsewhere) {
    if (reconnectTimer) {
      console.log('[Steam] Reconnect already pending; skipping duplicate');
      return;
    }
    const delaySec = 30;
    console.log(`[Steam] Will reconnect in ${delaySec}s...`);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      console.log('[Steam] Reconnecting...');
      logOnWithToken();
    }, delaySec * 1000);
  }
});

user.on('disconnected', (eresult, msg) => {
  console.log(`[Steam] Disconnected: ${msg} (${eresult})`);
  isLoggedIn = false;
  isGCConnected = false;
  metrics.steamLoggedIn.set(0);
  metrics.gcConnected.set(0);
  // autoRelogin (default: true) handles reconnect automatically.
  // The watchdog below catches cases where autoRelogin gets stuck.
});

csgo.on('connectedToGC', () => {
  console.log('[GC] Connected to CS2 Game Coordinator');
  isGCConnected = true;
  metrics.gcConnected.set(1);
  metrics.gcConnectionsTotal.inc();
});

csgo.on('disconnectedFromGC', (reason) => {
  console.log(`[GC] Disconnected: ${reason}`);
  isGCConnected = false;
  metrics.gcConnected.set(0);
  metrics.gcDisconnectionsTotal.inc({ reason: String(reason ?? 'unknown') });
  // Do NOT auto-reconnect. GC is on-demand now — next API request
  // calls ensureGCConnected() which sets gamesPlayed([730]) again.
});

function logOnWithToken() {
  try {
    user.logOn({ refreshToken: currentRefreshToken });
  } catch (err) {
    // steam-user throws if a logon is already in progress.
    console.log('[Steam] logOn skipped:', err.message);
  }
}

// ── Watchdog: recover from stuck Steam logins ─────────────
// autoRelogin handles most disconnects but can get stuck. We only
// watch the Steam login here; GC is on-demand and doesn't need a
// keep-alive ping.
setInterval(() => {
  if (!isLoggedIn) {
    console.log('[Watchdog] Steam disconnected — attempting re-login...');
    logOnWithToken();
  }
}, 2 * 60 * 1000);

// ── Refresh-token renewal ─────────────────────────────────
// Steam client refresh tokens last ~200 days. Every logOn asks Steam
// for a renewal, but the session can stay up for months, so once a day
// check the expiry and, inside the renewal window, log off and back on
// to give Steam the chance to issue a new token.
setInterval(() => {
  if (!shouldRenew(currentRefreshToken)) return;
  if (!isLoggedIn || gcBusyCount > 0) return; // try again tomorrow
  console.log('[Auth] Refresh token expires soon — re-logging on so Steam can renew it');
  user.once('disconnected', () => setTimeout(logOnWithToken, 2000));
  user.logOff();
}, 24 * 60 * 60 * 1000);

// ── Helpers: GC lifecycle ─────────────────────────────────

function cancelIdleTimer() {
  if (gcIdleTimer) {
    clearTimeout(gcIdleTimer);
    gcIdleTimer = null;
  }
}

function armIdleTimer() {
  cancelIdleTimer();
  gcIdleTimer = setTimeout(() => {
    // Defensive: never release while a GC operation is still running,
    // even if the timer was somehow armed during one.
    if (isGCConnected && gcBusyCount === 0) {
      console.log(`[GC] Idle ${GC_IDLE_MS / 1000}s — releasing gamesPlayed([])`);
      user.gamesPlayed([]);
    }
    gcIdleTimer = null;
  }, GC_IDLE_MS);
}

// Bracket a long-running GC operation so the idle timer can't release
// the game session mid-flight. beginGCWork() holds the GC up; endGCWork()
// re-arms the idle countdown only once all work is done.
function beginGCWork() {
  gcBusyCount++;
  cancelIdleTimer();
}

function endGCWork() {
  if (gcBusyCount > 0) gcBusyCount--;
  if (gcBusyCount === 0) armIdleTimer();
}

function waitForGC(timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    if (isGCConnected) return resolve();
    const onConnected = () => {
      clearTimeout(timeout);
      resolve();
    };
    const timeout = setTimeout(() => {
      csgo.removeListener('connectedToGC', onConnected);
      reject(new Error('GC connection timed out'));
    }, timeoutMs);
    csgo.once('connectedToGC', onConnected);
  });
}

/// Polls until csgo.inventory has at least one item, or times out.
/// Inventory arrives a beat or two after `connectedToGC` fires —
/// without this wait, the first request after a cold GC connect can
/// see an empty inventory.
///
/// 25s default: on the very first cold connect of the day, GC may
/// send connectedToGC fast but take >10s to push the inventory data,
/// especially after the previous idle-drop. Anything faster than
/// that on hot paths still resolves immediately because the check
/// fires every 200ms.
function waitForInventory(timeoutMs = 25000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const check = () => {
      if (csgo.inventory && csgo.inventory.length > 0) return resolve();
      if (Date.now() - start > timeoutMs) {
        return reject(new Error('Inventory wait timed out'));
      }
      setTimeout(check, 200);
    };
    check();
  });
}

/// Bring up GC if needed, optionally wait for inventory, then arm
/// the idle timer. Endpoints call this at the top before touching
/// `csgo.*` so the VM only counts playtime while it's actually
/// serving requests.
async function ensureGCConnected({ needInventory = false } = {}) {
  if (!isLoggedIn) {
    throw new Error('Not logged in to Steam — try again in a moment');
  }
  if (isBlocked) {
    throw new Error('Real Steam client is playing CS2 — yielded to it');
  }

  if (!isGCConnected) {
    console.log('[GC] On-demand connect: setting gamesPlayed([730])');
    user.gamesPlayed([730], true);
    await waitForGC();
  }

  if (needInventory) {
    await waitForInventory();
  }

  // Reset the idle countdown on every successful enter.
  armIdleTimer();
}

// The Steam/GC adapter app.js talks to.
const steamAdapter = {
  status: () => ({
    steam: isLoggedIn,
    gc: isGCConnected,
    displayName: steamDisplayName,
    steamId: user.steamID ? user.steamID.getSteamID64() : null,
  }),
  ensureConnected: ensureGCConnected,
  inventory: () => csgo.inventory || [],
  getCasketContents: (casketId) => new Promise((resolve, reject) => {
    csgo.getCasketContents(casketId, (err, items) => (err ? reject(err) : resolve(items)));
  }),
  inspectItem: (link) => new Promise((resolve) => {
    csgo.inspectItem(link, resolve);
  }),
  beginWork: beginGCWork,
  endWork: endGCWork,
};

// ── Login helpers ─────────────────────────────────────────

/// Creates a refresh token from Steam credentials. Needs a terminal,
/// so it only runs when the service is started by hand (local dev, or
/// over SSH to recover from an expired token). The password lives only
/// in this process's memory.
async function interactiveLogin() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = (q) => new Promise((resolve) => rl.question(q, resolve));

  try {
    console.log('\n=== Steam Login ===');
    console.log('This generates a refresh token. You only need to do this once.\n');

    const accountName = await ask('Steam username: ');
    const password = await ask('Steam password: ');

    let session = new LoginSession(EAuthTokenPlatformType.SteamClient);
    const result = await session.startWithCredentials({ accountName, password });

    // Steam Guard: cancel the polling session and start fresh with the
    // code passed directly, avoiding the 30s poll timeout.
    if (result.actionRequired) {
      const guard = result.validActions[0];
      console.log(`\nSteam Guard required (type: ${guard.type})`);
      const code = (await ask('Enter Steam Guard code: ')).toUpperCase().trim();
      session.cancelLoginAttempt();
      session = new LoginSession(EAuthTokenPlatformType.SteamClient);
      await session.startWithCredentials({ accountName, password, steamGuardCode: code });
    }

    const refreshToken = session.refreshToken || await new Promise((resolve, reject) => {
      session.once('authenticated', () => resolve(session.refreshToken));
      session.once('error', reject);
    });

    writeToken(TOKEN_FILE, refreshToken);
    console.log('\n[Auth] Refresh token saved. You won\'t need to log in again.\n');
    return refreshToken;
  } finally {
    rl.close();
  }
}

function loginWithToken(token) {
  return new Promise((resolve, reject) => {
    const onLoggedOn = () => {
      user.removeListener('error', onError);
      resolve();
    };
    const onError = (err) => {
      user.removeListener('loggedOn', onLoggedOn);
      reject(err);
    };
    user.once('loggedOn', onLoggedOn);
    user.once('error', onError);
    user.logOn({ refreshToken: token });
  });
}

// ── Startup ───────────────────────────────────────────────

async function start() {
  // Build the app first so a missing API_KEY fails fast, before any
  // Steam login happens.
  const app = createApp({
    apiKey: API_KEY,
    allowNoAuth: ALLOW_NO_AUTH,
    steam: steamAdapter,
    itemResolver,
    metrics,
  });

  // The saved file wins over the env var: renewals are written to the
  // file, and once Steam renews a token the old one stops working.
  let refreshToken = readToken(TOKEN_FILE) || REFRESH_TOKEN_ENV || null;
  if (!refreshToken) {
    if (!process.stdin.isTTY) {
      console.error('[Auth] No refresh token. Run `node index.js` once in a terminal to log in.');
      process.exit(1);
    }
    refreshToken = await interactiveLogin();
  }
  currentRefreshToken = refreshToken;
  updateTokenExpiryMetric();

  await itemResolver.init();

  console.log('[Steam] Logging in...');
  try {
    await loginWithToken(refreshToken);
  } catch (err) {
    console.error(`[Steam] Login failed: ${err.message} (eresult ${err.eresult})`);
    // Never delete the saved token here: most failures (Steam
    // maintenance, network blips, rate limits) are transient, and the
    // token is the one thing that can't be recreated without a Steam
    // Guard code. Exit so systemd retries; log in by hand if it expired.
    if (!process.stdin.isTTY) {
      console.error('[Auth] If the token has expired, stop the service and run `node index.js` over SSH to log in again.');
      process.exit(1);
    }
    currentRefreshToken = await interactiveLogin();
    updateTokenExpiryMetric();
    await loginWithToken(currentRefreshToken);
  }

  // GC is connected on demand by ensureGCConnected(), so the VM
  // doesn't accrue CS2 playtime while idle.

  app.listen(PORT, HOST, () => {
    console.log(`\n[Server] Storage service running on ${HOST}:${PORT}`);
    console.log(`[Server] Auth:   ${API_KEY ? 'API key required' : 'OPEN (ALLOW_NO_AUTH=1)'}`);
    console.log(`[Server] GC mode: on-demand (idle release after ${GC_IDLE_MS / 1000}s)\n`);
  });
}

start().catch((err) => {
  console.error('Fatal error:', err.message);
  process.exit(1);
});
