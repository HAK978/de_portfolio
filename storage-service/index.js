const express = require('express');
const SteamUser = require('steam-user');
const GlobalOffensive = require('globaloffensive');
const { LoginSession, EAuthTokenPlatformType } = require('steam-session');
const ItemResolver = require('./itemResolver');
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const app = express();
const itemResolver = new ItemResolver();
app.use(express.json());

// ── Config (env vars for remote, defaults for local dev) ─
const PORT = process.env.PORT || 3456;
const API_KEY = process.env.API_KEY || '';
const REFRESH_TOKEN_ENV = process.env.REFRESH_TOKEN || '';
const TOKEN_FILE = path.join(__dirname, '.refresh_token');

// ── API key auth middleware ───────────────────────────────
// Only enforced if API_KEY env var is set. Skipped for local dev.
if (API_KEY) {
  app.use((req, res, next) => {
    const key = req.headers['x-api-key'];
    if (key !== API_KEY) {
      return res.status(401).json({ error: 'Invalid or missing API key' });
    }
    next();
  });
  console.log('[Auth] API key protection enabled');
}

// ── Steam & GC instances ──────────────────────────────────
let user = new SteamUser();
let csgo = new GlobalOffensive(user);
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

// ── Steam event handlers ──────────────────────────────────

user.on('loggedOn', () => {
  console.log('[Steam] Logged in successfully');
  isLoggedIn = true;
  // Intentionally do NOT call gamesPlayed([730]) here. GC is brought
  // up on demand by ensureGCConnected() when an API request needs it.
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
let _reconnectTimer = null;

user.on('error', (err) => {
  console.error('[Steam] Error:', err.message);
  isLoggedIn = false;
  isGCConnected = false;

  // LoggedInElsewhere is fatal — autoRelogin won't handle it.
  if (err.eresult === 6) { // EResult.LoggedInElsewhere
    if (_reconnectTimer) {
      console.log('[Steam] Reconnect already pending; skipping duplicate');
      return;
    }
    const delaySec = 30;
    console.log(`[Steam] Will reconnect in ${delaySec}s...`);
    _reconnectTimer = setTimeout(() => {
      _reconnectTimer = null;
      console.log('[Steam] Reconnecting...');
      try {
        user.logOn({ refreshToken: currentRefreshToken });
      } catch (e) {
        console.log('[Steam] logOn threw on reconnect:', e.message);
      }
    }, delaySec * 1000);
  }
});

user.on('disconnected', (eresult, msg) => {
  console.log(`[Steam] Disconnected: ${msg} (${eresult})`);
  isLoggedIn = false;
  isGCConnected = false;
  // autoRelogin (default: true) handles reconnect automatically.
  // The watchdog below catches cases where autoRelogin gets stuck.
});

csgo.on('connectedToGC', () => {
  console.log('[GC] Connected to CS2 Game Coordinator');
  isGCConnected = true;
});

csgo.on('disconnectedFromGC', (reason) => {
  console.log(`[GC] Disconnected: ${reason}`);
  isGCConnected = false;
  // Do NOT auto-reconnect. GC is on-demand now — next API request
  // calls ensureGCConnected() which sets gamesPlayed([730]) again.
});

// ── Watchdog: recover from stuck Steam logins ─────────────
// autoRelogin handles most disconnects but can get stuck. We only
// watch the Steam login here; GC is on-demand and doesn't need a
// keep-alive ping.
setInterval(() => {
  if (!isLoggedIn) {
    console.log('[Watchdog] Steam disconnected — attempting re-login...');
    try {
      user.logOn({ refreshToken: currentRefreshToken });
    } catch (e) {
      console.log('[Watchdog] logOn failed:', e.message);
    }
  }
}, 2 * 60 * 1000);

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
    if (isGCConnected) {
      console.log(`[GC] Idle ${GC_IDLE_MS / 1000}s — releasing gamesPlayed([])`);
      user.gamesPlayed([]);
    }
    gcIdleTimer = null;
  }, GC_IDLE_MS);
}

function waitForGC(timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    if (isGCConnected) return resolve();
    const timeout = setTimeout(() => {
      reject(new Error('GC connection timed out'));
    }, timeoutMs);
    csgo.once('connectedToGC', () => {
      clearTimeout(timeout);
      resolve();
    });
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

// ── Helper: interactive login ─────────────────────────────
// Creates a refresh token from Steam credentials.
// Only used for local dev — not available on remote servers (no TTY).

async function interactiveLogin() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const ask = (q) => new Promise((resolve) => rl.question(q, resolve));

  console.log('\n=== Steam Login ===');
  console.log('This generates a refresh token. You only need to do this once.\n');

  const accountName = await ask('Steam username: ');
  const password = await ask('Steam password: ');

  const session = new LoginSession(EAuthTokenPlatformType.SteamClient);

  try {
    const result = await session.startWithCredentials({
      accountName,
      password,
    });

    let activeSession = session;

    // Handle Steam Guard — cancel the polling session and start fresh
    // with the code passed directly, avoiding the 30s poll timeout
    if (result.actionRequired) {
      const guard = result.validActions[0];
      console.log(`\nSteam Guard required (type: ${guard.type})`);
      const code = (await ask('Enter Steam Guard code: ')).toUpperCase().trim();

      // Kill the old session's polling
      session.cancelLoginAttempt();

      // Start a new session with the code included
      activeSession = new LoginSession(EAuthTokenPlatformType.SteamClient);
      await activeSession.startWithCredentials({
        accountName,
        password,
        steamGuardCode: code,
      });
    }

    // Wait for authenticated event
    const refreshToken = await new Promise((resolve, reject) => {
      activeSession.on('authenticated', () => {
        resolve(activeSession.refreshToken);
      });
      activeSession.on('error', (err) => {
        reject(err);
      });
      if (activeSession.refreshToken) {
        resolve(activeSession.refreshToken);
      }
    });

    // Save token
    fs.writeFileSync(TOKEN_FILE, refreshToken);
    console.log('\n[Auth] Refresh token saved. You won\'t need to log in again.\n');
    rl.close();
    return refreshToken;
  } catch (err) {
    rl.close();
    throw err;
  }
}

// ── Helper: login with refresh token ──────────────────────

async function loginWithToken(token) {
  return new Promise((resolve, reject) => {
    user.once('loggedOn', () => resolve());
    user.once('error', (err) => reject(err));
    user.logOn({ refreshToken: token });
  });
}

// ── API Routes ────────────────────────────────────────────

// GET /status — check connection state
app.get('/status', (req, res) => {
  res.json({
    steam: isLoggedIn,
    gc: isGCConnected,
    displayName: steamDisplayName,
  });
});

// GET /caskets — list all storage units in inventory
app.get('/caskets', async (req, res) => {
  try {
    await ensureGCConnected({ needInventory: true });
  } catch (err) {
    return res.status(503).json({ error: err.message });
  }

  // csgo.inventory is populated by the GC after connecting.
  // Storage units have a 'casket_contained_item_count' property.
  const inventory = csgo.inventory || [];
  const caskets = inventory.filter(
    (item) => item.casket_contained_item_count !== undefined
  );

  console.log(`[API] Found ${caskets.length} storage units in inventory of ${inventory.length} items`);

  const result = caskets.map((item) => ({
    casketId: item.id,
    name: item.custom_name || 'Storage Unit',
    itemCount: item.casket_contained_item_count || 0,
    defIndex: item.def_index,
  }));

  res.json({ total: result.length, caskets: result });
});

// In-flight casket fetches keyed by casketId. Prevents two concurrent
// /storage/:id calls for the same casket from racing the
// `globaloffensive` library's per-casket callback (which can return
// stale results to the wrong request if both are pending).
const _inflightCaskets = new Set();

// GET /storage/:casketId — fetch storage unit contents
app.get('/storage/:casketId', async (req, res) => {
  try {
    await ensureGCConnected();
  } catch (err) {
    return res.status(503).json({ error: err.message });
  }

  const casketId = req.params.casketId;

  if (_inflightCaskets.has(casketId)) {
    return res.status(409).json({
      error: 'Already fetching this storage unit — wait for it to finish',
    });
  }
  _inflightCaskets.add(casketId);

  console.log(`[API] Fetching contents of casket ${casketId}...`);

  try {
    const rawItems = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error('Casket contents request timed out (30s)'));
      }, 30000);

      csgo.getCasketContents(casketId, (err, items) => {
        clearTimeout(timeout);
        if (err) return reject(err);
        resolve(items);
      });
    });

    // Extract hidden attributes (music_index, graffiti_tint)
    for (const item of rawItems) {
      itemResolver._extractMusicIndex(item);
      itemResolver._extractGraffitiTint(item);
    }

    // Resolve raw GC data to human-readable names/images
    const items = itemResolver.convertStorageItems(rawItems);

    console.log(`[API] Casket ${casketId}: ${rawItems.length} raw → ${items.length} resolved`);
    res.json({ casketId, itemCount: items.length, items });
  } catch (err) {
    console.error(`[API] Error fetching casket ${casketId}:`, err.message);
    res.status(500).json({ error: err.message });
  } finally {
    _inflightCaskets.delete(casketId);
  }
});

// GET /inventory/floats — return float values for all inventory items
// Uses GC inventory data directly (no inspect requests needed for own items)
app.get('/inventory/floats', async (req, res) => {
  try {
    await ensureGCConnected({ needInventory: true });
  } catch (err) {
    return res.status(503).json({ error: err.message });
  }

  const inventory = csgo.inventory || [];
  const floats = {};

  for (const item of inventory) {
    if (item.paint_wear !== undefined && item.paint_wear > 0) {
      // Key by def_index + paint_index + paint_wear to build a unique-ish key
      // But for Flutter matching, we need market_hash_name → use itemResolver
      const resolved = itemResolver._convertItem(item);
      if (resolved && resolved.marketHashName) {
        if (!floats[resolved.marketHashName]) {
          floats[resolved.marketHashName] = [];
        }
        floats[resolved.marketHashName].push({
          assetId: item.id,
          floatValue: item.paint_wear,
          paintSeed: item.paint_seed || null,
          paintIndex: item.paint_index || null,
        });
      }
    }
  }

  console.log(`[API] Returning floats for ${Object.keys(floats).length} unique items`);
  res.json({ itemCount: Object.keys(floats).length, floats });
});

// GET /inspect?url=... — resolve float from an inspect link
app.get('/inspect', async (req, res) => {
  try {
    await ensureGCConnected();
  } catch (err) {
    return res.status(503).json({ error: err.message });
  }

  const inspectLink = req.query.url;
  if (!inspectLink) {
    return res.status(400).json({ error: 'Missing ?url= parameter with inspect link' });
  }

  try {
    const item = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error('Inspect request timed out (10s)'));
      }, 12000);

      csgo.inspectItem(inspectLink, (itemData) => {
        clearTimeout(timeout);
        resolve(itemData);
      });
    });

    res.json({
      assetId: item.itemid,
      defIndex: item.defindex,
      paintIndex: item.paintindex,
      floatValue: item.paintwear,
      paintSeed: item.paintseed,
      rarity: item.rarity,
      quality: item.quality,
      stickers: item.stickers || [],
      customName: item.customname || null,
    });
  } catch (err) {
    console.error('[API] Inspect error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── Startup ───────────────────────────────────────────────

async function start() {
  let refreshToken;

  // 1. Check env var (remote deployment)
  if (REFRESH_TOKEN_ENV) {
    refreshToken = REFRESH_TOKEN_ENV;
    console.log('[Auth] Using refresh token from environment');
  }
  // 2. Check saved file (local dev)
  else if (fs.existsSync(TOKEN_FILE)) {
    refreshToken = fs.readFileSync(TOKEN_FILE, 'utf-8').trim();
    console.log('[Auth] Found saved refresh token file');
  }
  // 3. Interactive login (local dev only — needs a terminal)
  else if (process.stdin.isTTY) {
    refreshToken = await interactiveLogin();
  }
  // 4. No token and no way to get one
  else {
    console.error('[Auth] No refresh token found.');
    console.error('       Set REFRESH_TOKEN env var, or run locally first to generate .refresh_token');
    process.exit(1);
  }

  // Store token for auto-reconnect on LoggedInElsewhere
  currentRefreshToken = refreshToken;

  // Initialize item resolver (downloads fresh item definitions)
  await itemResolver.init();

  // Log in to Steam
  console.log('[Steam] Logging in...');
  try {
    await loginWithToken(refreshToken);
  } catch (err) {
    console.error('[Steam] Login failed:', err.message);

    if (REFRESH_TOKEN_ENV) {
      // Can't re-auth on remote — exit so the operator knows
      console.error('[Auth] REFRESH_TOKEN env var may be expired. Generate a new one locally.');
      process.exit(1);
    }

    // Local dev — try interactive login
    if (fs.existsSync(TOKEN_FILE)) {
      fs.unlinkSync(TOKEN_FILE);
    }
    console.log('[Auth] Token may be expired. Re-authenticating...');
    refreshToken = await interactiveLogin();
    await loginWithToken(refreshToken);
  }

  // GC is now connected on demand by ensureGCConnected() — no
  // up-front connect, so the VM doesn't accrue CS2 playtime while
  // it's just sitting idle waiting for requests.

  // Start HTTP server — bind 0.0.0.0 so it's reachable from outside
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`\n[Server] Storage service running on port ${PORT}`);
    console.log(`[Server] Status: http://0.0.0.0:${PORT}/status`);
    console.log(`[Server] Auth:   ${API_KEY ? 'API key required' : 'OPEN (no API_KEY set)'}`);
    console.log(`[Server] GC mode: on-demand (idle release after ${GC_IDLE_MS / 1000}s)\n`);
  });
}

start().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
