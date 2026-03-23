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
let steamDisplayName = '';
let currentRefreshToken = '';

// ── Steam event handlers ──────────────────────────────────

user.on('loggedOn', () => {
  console.log('[Steam] Logged in successfully');
  isLoggedIn = true;
  // Tell Steam we're "playing" CS2 — this triggers GC connection
  user.gamesPlayed([730], true);
});

user.on('accountInfo', (name) => {
  steamDisplayName = name;
  console.log(`[Steam] Account: ${name}`);
});

// Gracefully yield when the real Steam client starts playing,
// and resume when it stops. This avoids LoggedInElsewhere kicks.
user.on('playingState', (blocked, playingApp) => {
  if (blocked) {
    console.log(`[Steam] Blocked — app ${playingApp} is playing elsewhere. Yielding...`);
    user.gamesPlayed([]); // stop "playing" so we don't get kicked
  } else {
    console.log('[Steam] Other session stopped playing. Resuming CS2...');
    user.gamesPlayed([730], true);
  }
});

user.on('error', (err) => {
  console.error('[Steam] Error:', err.message);
  isLoggedIn = false;
  isGCConnected = false;

  // LoggedInElsewhere is fatal — autoRelogin won't handle it.
  // Wait and reconnect automatically.
  if (err.eresult === 6) { // EResult.LoggedInElsewhere
    const delaySec = 30;
    console.log(`[Steam] Will reconnect in ${delaySec}s...`);
    setTimeout(() => {
      console.log('[Steam] Reconnecting...');
      user.logOn({ refreshToken: currentRefreshToken });
    }, delaySec * 1000);
  }
});

user.on('disconnected', (eresult, msg) => {
  console.log(`[Steam] Disconnected: ${msg} (${eresult})`);
  isLoggedIn = false;
  isGCConnected = false;
});

csgo.on('connectedToGC', () => {
  console.log('[GC] Connected to CS2 Game Coordinator');
  isGCConnected = true;
});

csgo.on('disconnectedFromGC', (reason) => {
  console.log(`[GC] Disconnected: ${reason}`);
  isGCConnected = false;
});

// ── Helper: wait for GC connection ────────────────────────

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
app.get('/caskets', (req, res) => {
  if (!isGCConnected) {
    return res.status(503).json({ error: 'Not connected to Game Coordinator' });
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

// GET /inventory — raw GC inventory (for debugging)
app.get('/inventory', (req, res) => {
  if (!isGCConnected) {
    return res.status(503).json({ error: 'Not connected to Game Coordinator' });
  }

  const inventory = csgo.inventory || [];
  res.json({ total: inventory.length, items: inventory.slice(0, 5) }); // first 5 for debugging
});

// GET /storage/:casketId — fetch storage unit contents
app.get('/storage/:casketId', async (req, res) => {
  if (!isGCConnected) {
    return res.status(503).json({ error: 'Not connected to Game Coordinator' });
  }

  const casketId = req.params.casketId;
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

  // Wait for GC
  console.log('[GC] Waiting for Game Coordinator...');
  try {
    await waitForGC();
  } catch (err) {
    console.error('[GC] Failed to connect:', err.message);
    console.log('[GC] Will keep trying in background. Start the app anyway.');
  }

  // Start HTTP server — bind 0.0.0.0 so it's reachable from outside
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`\n[Server] Storage service running on port ${PORT}`);
    console.log(`[Server] Status: http://0.0.0.0:${PORT}/status`);
    console.log(`[Server] Auth:   ${API_KEY ? 'API key required' : 'OPEN (no API_KEY set)'}\n`);
  });
}

start().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
