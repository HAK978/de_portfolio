// HTTP API for the storage service.
//
// Steam / Game Coordinator access is injected through `steam` (see
// index.js for the real implementation), so the routes, auth and input
// validation can be tested without a live Steam session.

const crypto = require('crypto');
const express = require('express');

// Only genuine CS2 inspect links are accepted. /inspect feeds the Game
// Coordinator through the VM's Steam session, so arbitrary input must
// never reach it.
const INSPECT_RE =
  /^steam:\/\/rungame\/730\/\d+\/\+csgo_econ_action_preview\s+[SM]\d+A\d+D\d+$/;

// Storage units (caskets) are identified by their 64-bit asset ID.
const CASKET_ID_RE = /^\d{1,20}$/;

/** Constant-time comparison so response timing can't leak the key. */
function safeKeyEqual(provided, expected) {
  if (typeof provided !== 'string' || typeof expected !== 'string') return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

/** Rejects with [message] if [promise] hasn't settled within [ms]. */
function withTimeout(promise, ms, message) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/**
 * Builds the Express app.
 *
 * @param {object} options
 * @param {string} [options.apiKey] Shared secret expected in X-Api-Key.
 *   Required unless [allowNoAuth] is set (local development only).
 * @param {object} options.steam Steam/GC adapter: status(),
 *   ensureConnected({needInventory}), inventory(),
 *   getCasketContents(id), inspectItem(link), beginWork(), endWork().
 * @param {object} options.itemResolver Converts raw GC items to
 *   names/images (see itemResolver.js).
 * @param {object} [options.metrics] prom-client metrics (metrics.js).
 */
function createApp({
  apiKey,
  allowNoAuth = false,
  steam,
  itemResolver,
  metrics,
  casketTimeoutMs = 110_000,
  inspectTimeoutMs = 12_000,
}) {
  if (!apiKey && !allowNoAuth) {
    // Fail closed: a missing key in .env must not silently expose the
    // owner's Steam session to the internet.
    throw new Error('API_KEY is not set. Set ALLOW_NO_AUTH=1 only for local development.');
  }

  const app = express();
  app.disable('x-powered-by');

  // Metrics middleware + /metrics come BEFORE auth so the local
  // Prometheus scraper doesn't need the key. Caddy blocks /metrics from
  // the public internet (see HTTPS_DEPLOY.md). Labels use the matched
  // route pattern so casket IDs can't explode the label cardinality.
  if (metrics) {
    app.use((req, res, next) => {
      const start = process.hrtime.bigint();
      res.on('finish', () => {
        const route = req.route?.path || 'unmatched';
        const seconds = Number(process.hrtime.bigint() - start) / 1e9;
        metrics.httpRequestsTotal.inc({
          route,
          method: req.method,
          status: String(res.statusCode),
        });
        metrics.httpRequestDurationSeconds.observe({ route, method: req.method }, seconds);
      });
      next();
    });

    app.get('/metrics', async (req, res) => {
      res.set('Content-Type', metrics.register.contentType);
      res.send(await metrics.register.metrics());
    });
  }

  if (apiKey) {
    app.use((req, res, next) => {
      if (!safeKeyEqual(req.headers['x-api-key'], apiKey)) {
        return res.status(401).json({ error: 'Invalid or missing API key' });
      }
      next();
    });
  }

  // GET /status — connection state (and which account the VM serves, so
  // the app only applies GC floats to that account's inventory).
  app.get('/status', (req, res) => {
    res.json(steam.status());
  });

  // GET /caskets — storage units in the inventory.
  app.get('/caskets', async (req, res) => {
    try {
      await steam.ensureConnected({ needInventory: true });
    } catch (err) {
      return res.status(503).json({ error: err.message });
    }

    const caskets = steam.inventory()
      .filter((item) => item.casket_contained_item_count !== undefined)
      .map((item) => ({
        casketId: item.id,
        name: item.custom_name || 'Storage Unit',
        itemCount: item.casket_contained_item_count || 0,
        defIndex: item.def_index,
      }));

    res.json({ total: caskets.length, caskets });
  });

  // In-flight casket fetches. Two concurrent requests for the same casket
  // can make the globaloffensive library hand stale results to the wrong
  // caller, so the second one is refused instead.
  const inflightCaskets = new Set();

  // GET /storage/:casketId — contents of one storage unit.
  app.get('/storage/:casketId', async (req, res) => {
    const { casketId } = req.params;
    if (!CASKET_ID_RE.test(casketId)) {
      return res.status(400).json({ error: 'Invalid storage unit ID' });
    }

    try {
      await steam.ensureConnected();
    } catch (err) {
      return res.status(503).json({ error: err.message });
    }

    if (inflightCaskets.has(casketId)) {
      return res.status(409).json({
        error: 'Already fetching this storage unit — wait for it to finish',
      });
    }
    inflightCaskets.add(casketId);
    // Hold the GC session for the whole fetch: a large casket can take
    // longer than the idle timeout to enumerate.
    steam.beginWork();

    const fetchStart = Date.now();
    try {
      const rawItems = await withTimeout(
        steam.getCasketContents(casketId),
        casketTimeoutMs,
        `Casket contents request timed out (${Math.round(casketTimeoutMs / 1000)}s) — try again, the GC was slow`,
      );

      // Hidden attributes the resolver needs for names (music kits, graffiti).
      for (const item of rawItems) {
        itemResolver._extractMusicIndex(item);
        itemResolver._extractGraffitiTint(item);
      }
      const items = itemResolver.convertStorageItems(rawItems);

      console.log(`[API] Casket ${casketId}: ${rawItems.length} raw → ${items.length} resolved`);
      metrics?.casketFetchesTotal.inc({ result: 'success' });
      res.json({ casketId, itemCount: items.length, items });
    } catch (err) {
      metrics?.casketFetchesTotal.inc({ result: 'error' });
      console.error(`[API] Error fetching casket ${casketId}:`, err.message);
      res.status(500).json({ error: err.message });
    } finally {
      metrics?.casketFetchDurationSeconds.observe((Date.now() - fetchStart) / 1000);
      inflightCaskets.delete(casketId);
      steam.endWork();
    }
  });

  // GET /inventory/floats — float values for every inventory item,
  // straight from the GC's inventory data (no inspect requests needed).
  app.get('/inventory/floats', async (req, res) => {
    try {
      await steam.ensureConnected({ needInventory: true });
    } catch (err) {
      return res.status(503).json({ error: err.message });
    }

    const floats = {};
    for (const item of steam.inventory()) {
      if (item.paint_wear === undefined || item.paint_wear <= 0) continue;
      const resolved = itemResolver._convertItem(item);
      if (!resolved?.marketHashName) continue;
      (floats[resolved.marketHashName] ??= []).push({
        assetId: item.id,
        floatValue: item.paint_wear,
        paintSeed: item.paint_seed || null,
        paintIndex: item.paint_index || null,
      });
    }

    res.json({ itemCount: Object.keys(floats).length, floats });
  });

  // GET /inspect?url=... — resolve an item's float from its inspect link.
  app.get('/inspect', async (req, res) => {
    // Validate before touching the GC, so junk requests don't put the
    // account in-game.
    const inspectLink = typeof req.query.url === 'string' ? req.query.url.trim() : '';
    if (!inspectLink) {
      return res.status(400).json({ error: 'Missing ?url= parameter with inspect link' });
    }
    if (inspectLink.length > 200 || !INSPECT_RE.test(inspectLink)) {
      return res.status(400).json({ error: 'Invalid CS2 inspect link' });
    }

    try {
      await steam.ensureConnected();
    } catch (err) {
      return res.status(503).json({ error: err.message });
    }

    try {
      const item = await withTimeout(
        steam.inspectItem(inspectLink),
        inspectTimeoutMs,
        `Inspect request timed out (${Math.round(inspectTimeoutMs / 1000)}s)`,
      );
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

  return app;
}

module.exports = { createApp, safeKeyEqual, withTimeout, INSPECT_RE, CASKET_ID_RE };
