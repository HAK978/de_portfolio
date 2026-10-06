// HTTP-level tests for the storage service API (app.js). A fake Steam
// adapter stands in for the real Game Coordinator session, so these run
// offline and exercise the real Express routes, auth and validation.

const { test, describe, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { createApp, safeKeyEqual } = require('../app');

const API_KEY = 'a'.repeat(64);
const VALID_INSPECT =
  'steam://rungame/730/76561202255233023/+csgo_econ_action_preview S76561198000000001A123456789D987654321';

function fakeSteam(overrides = {}) {
  const calls = { ensureConnected: 0, beginWork: 0, endWork: 0 };
  return {
    calls,
    status: () => ({ steam: true, gc: false, displayName: 'Owner', steamId: '76561198000000001' }),
    ensureConnected: async () => { calls.ensureConnected++; },
    inventory: () => [],
    getCasketContents: async () => [],
    inspectItem: async () => ({ itemid: '1', defindex: 7, paintindex: 282, paintwear: 0.2, paintseed: 1 }),
    beginWork: () => { calls.beginWork++; },
    endWork: () => { calls.endWork++; },
    ...overrides,
  };
}

const fakeResolver = {
  _extractMusicIndex() {},
  _extractGraffitiTint() {},
  convertStorageItems: (raw) => raw.map((item) => ({ id: item.id, marketHashName: `item-${item.id}` })),
  _convertItem: (item) => (item.def_index ? { marketHashName: `def-${item.def_index}` } : null),
};

let server;
let baseUrl;

async function serve(options) {
  const app = createApp({ apiKey: API_KEY, itemResolver: fakeResolver, ...options });
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
}

function get(path, { key = API_KEY } = {}) {
  return fetch(baseUrl + path, { headers: key === null ? {} : { 'X-Api-Key': key } });
}

afterEach(() => new Promise((resolve) => {
  if (!server) return resolve();
  server.close(() => resolve());
  server = null;
}));

describe('configuration', () => {
  test('refuses to build without an API key (fails closed)', () => {
    assert.throws(() => createApp({ steam: fakeSteam(), itemResolver: fakeResolver }), /API_KEY/);
  });

  test('allows an open server only when explicitly requested', async () => {
    await serve({ apiKey: '', allowNoAuth: true, steam: fakeSteam() });
    assert.equal((await get('/status', { key: null })).status, 200);
  });
});

describe('API key auth', () => {
  beforeEach(() => serve({ steam: fakeSteam() }));

  test('rejects a missing key', async () => {
    const res = await get('/status', { key: null });
    assert.equal(res.status, 401);
    assert.deepEqual(await res.json(), { error: 'Invalid or missing API key' });
  });

  test('rejects a wrong key of the same length and of a different length', async () => {
    assert.equal((await get('/status', { key: 'b'.repeat(64) })).status, 401);
    assert.equal((await get('/status', { key: 'short' })).status, 401);
  });

  test('accepts the right key and reports which account the VM serves', async () => {
    const res = await get('/status');
    assert.equal(res.status, 200);
    assert.equal((await res.json()).steamId, '76561198000000001');
  });

  test('does not advertise the framework', async () => {
    const res = await get('/status');
    assert.equal(res.headers.get('x-powered-by'), null);
  });

  test('protects every route, not just /status', async () => {
    for (const path of ['/caskets', '/storage/123', '/inventory/floats', `/inspect?url=${encodeURIComponent(VALID_INSPECT)}`]) {
      assert.equal((await get(path, { key: null })).status, 401, path);
    }
  });
});

describe('safeKeyEqual', () => {
  test('handles non-string input without throwing', () => {
    assert.equal(safeKeyEqual(undefined, API_KEY), false);
    assert.equal(safeKeyEqual(['a'], API_KEY), false);
    assert.equal(safeKeyEqual(API_KEY, API_KEY), true);
  });
});

describe('/inspect', () => {
  test('rejects malformed links before waking the Game Coordinator', async () => {
    const steam = fakeSteam();
    await serve({ steam });
    for (const url of ['', 'https://evil.example', `${VALID_INSPECT}; rm -rf /`, VALID_INSPECT + '0'.repeat(200)]) {
      const res = await get(`/inspect?url=${encodeURIComponent(url)}`);
      assert.equal(res.status, 400, url);
    }
    assert.equal(steam.calls.ensureConnected, 0);
  });

  test('returns the item fields for a valid link', async () => {
    await serve({ steam: fakeSteam() });
    const res = await get(`/inspect?url=${encodeURIComponent(VALID_INSPECT)}`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.floatValue, 0.2);
    assert.deepEqual(body.stickers, []);
    assert.equal(body.customName, null);
  });

  test('times out instead of hanging when the GC never answers', async () => {
    await serve({
      steam: fakeSteam({ inspectItem: () => new Promise(() => {}) }),
      inspectTimeoutMs: 20,
    });
    const res = await get(`/inspect?url=${encodeURIComponent(VALID_INSPECT)}`);
    assert.equal(res.status, 500);
    assert.match((await res.json()).error, /timed out/);
  });

  test('reports 503 when Steam is unavailable', async () => {
    await serve({
      steam: fakeSteam({ ensureConnected: async () => { throw new Error('Real Steam client is playing CS2'); } }),
    });
    const res = await get(`/inspect?url=${encodeURIComponent(VALID_INSPECT)}`);
    assert.equal(res.status, 503);
    assert.match((await res.json()).error, /playing CS2/);
  });
});

describe('/storage/:casketId', () => {
  test('rejects non-numeric IDs before touching the GC', async () => {
    const steam = fakeSteam();
    await serve({ steam });
    for (const id of ['abc', '1;2', '-1', '1.5', '1'.repeat(21)]) {
      assert.equal((await get(`/storage/${id}`)).status, 400, id);
    }
    assert.equal(steam.calls.ensureConnected, 0);
  });

  test('returns resolved items and releases the GC hold', async () => {
    const steam = fakeSteam({ getCasketContents: async () => [{ id: '7' }, { id: '8' }] });
    await serve({ steam });
    const res = await get('/storage/123');
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), {
      casketId: '123',
      itemCount: 2,
      items: [{ id: '7', marketHashName: 'item-7' }, { id: '8', marketHashName: 'item-8' }],
    });
    assert.equal(steam.calls.beginWork, 1);
    assert.equal(steam.calls.endWork, 1);
  });

  test('refuses a second concurrent fetch of the same casket only', async () => {
    let release;
    const steam = fakeSteam({
      // Casket 123 hangs until released; any other casket answers at once.
      getCasketContents: (id) => (id === '123'
        ? new Promise((resolve) => { release = () => resolve([]); })
        : Promise.resolve([])),
    });
    await serve({ steam });
    const first = get('/storage/123');
    // Wait until the first request is actually in flight.
    while (!release) await new Promise((resolve) => setTimeout(resolve, 5));

    assert.equal((await get('/storage/123')).status, 409);
    assert.equal((await get('/storage/456')).status, 200);

    release();
    assert.equal((await first).status, 200);
    // The lock is released once the first fetch finishes.
    release = null;
    const again = get('/storage/123');
    while (!release) await new Promise((resolve) => setTimeout(resolve, 5));
    release();
    assert.equal((await again).status, 200);
  });

  test('releases the GC hold even when the fetch fails or times out', async () => {
    const steam = fakeSteam({ getCasketContents: () => new Promise(() => {}) });
    await serve({ steam, casketTimeoutMs: 20 });
    const res = await get('/storage/123');
    assert.equal(res.status, 500);
    assert.match((await res.json()).error, /timed out/);
    assert.equal(steam.calls.beginWork, steam.calls.endWork);
    // The in-flight lock is gone, so a retry isn't refused with 409.
    assert.equal((await get('/storage/123')).status, 500);
  });
});

describe('/caskets and /inventory/floats', () => {
  const inventory = [
    { id: '1', def_index: 7, paint_wear: 0.2, paint_seed: 42, paint_index: 282 },
    { id: '2', def_index: 7, paint_wear: 0.05, paint_seed: 7, paint_index: 282 },
    { id: '3', def_index: 1201, casket_contained_item_count: 12, custom_name: 'Knives' },
    { id: '4', def_index: 1201, casket_contained_item_count: 0 },
    { id: '5', def_index: 9, paint_wear: 0 }, // no float (vanilla) — skipped
    { id: '6', def_index: 0, paint_wear: 0.5 }, // unresolvable — skipped
  ];

  test('lists only storage units, with a default name', async () => {
    await serve({ steam: fakeSteam({ inventory: () => inventory }) });
    const body = await (await get('/caskets')).json();
    assert.deepEqual(body, {
      total: 2,
      caskets: [
        { casketId: '3', name: 'Knives', itemCount: 12, defIndex: 1201 },
        { casketId: '4', name: 'Storage Unit', itemCount: 0, defIndex: 1201 },
      ],
    });
  });

  test('groups floats by market hash name and skips items without one', async () => {
    await serve({ steam: fakeSteam({ inventory: () => inventory }) });
    const body = await (await get('/inventory/floats')).json();
    assert.equal(body.itemCount, 1);
    assert.deepEqual(body.floats['def-7'].map((f) => f.floatValue), [0.2, 0.05]);
    assert.deepEqual(body.floats['def-7'][0], { assetId: '1', floatValue: 0.2, paintSeed: 42, paintIndex: 282 });
  });
});
