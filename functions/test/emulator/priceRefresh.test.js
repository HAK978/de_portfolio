// Runs the scheduled price refresh against the Firestore emulator, with
// CS2 Trader's bulk price files faked at the fetch layer.
//
// Run with `npm run test:emulator`.

const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');

const {getFirestore} = require('firebase-admin/firestore');
const {updatePriceChanges} = require('../../lib/index');
const {MIN_BULK_ITEMS} = require('../../lib/bulkPrices');

const HOUR = 60 * 60 * 1000;
const realFetch = globalThis.fetch;

const REDLINE = 'AK-47 | Redline (Field-Tested)';
const HOWL = 'M4A4 | Howl (Field-Tested)'; // only in a user's inventory, never priced before
const RARE = 'Souvenir AWP | Dragon Lore (Factory New)'; // no recent Steam sales
const GRAFFITI = 'Sealed Graffiti | GGWP (Wire Blue)'; // not listed on CSFloat
const MEDAL = '5 Year Veteran Coin'; // not on any market
const CAPSULE = 'Paris 2023 Legends Sticker Capsule'; // only inside a storage unit

function bulkFile(extra) {
  const items = {...extra};
  for (let i = 0; Object.keys(items).length < MIN_BULK_ITEMS; i++) items[`filler ${i}`] = {};
  return items;
}

const steamFile = bulkFile({
  [REDLINE]: {last_24h: 1100, last_7d: 1050, last_30d: 1000, last_90d: 990},
  [HOWL]: {last_24h: 4000, last_7d: 3900, last_30d: null, last_90d: null},
  [RARE]: {last_24h: null, last_7d: null, last_30d: 250000, last_90d: 240000},
  [GRAFFITI]: {last_24h: 0.05, last_7d: 0.05, last_30d: 0.05, last_90d: 0.05},
  [CAPSULE]: {last_24h: 0.4, last_7d: 0.38, last_30d: 0.35, last_90d: 0.3},
});
const csfloatFile = bulkFile({
  [REDLINE]: {price: 1080, starting_at: {price: 1080}, highest_order: {price: 1000}},
  [HOWL]: {price: 3800},
});

const requested = [];
before(() => {
  globalThis.fetch = async (url, init) => {
    const u = new URL(String(url));
    if (u.hostname !== 'prices.csgotrader.app') return realFetch(url, init);
    requested.push(u.pathname);
    assert.ok(init.headers['User-Agent'].startsWith('CS2PortfolioManager/'), 'requests must identify the app');
    const body = u.pathname.endsWith('/steam.json') ? steamFile : csfloatFile;
    return Response.json(body, {headers: {'last-modified': 'Tue, 27 Oct 2026 01:25:15 GMT'}});
  };
});

after(() => {
  globalThis.fetch = realFetch;
});

test('prices every watched and inventory item from two bulk downloads', async () => {
  const db = getFirestore();
  const now = Date.now();

  // Already-priced item with history from the bulk source: changes are computed.
  await db.doc(`prices/${REDLINE}`).set({marketHashName: REDLINE, currentPrice: 1000});
  await db.doc(`priceHistory/${REDLINE}`).set({
    source: 'csgotrader-steam',
    samples: [{at: now - 24 * HOUR - HOUR, price: 1000}],
  });
  // Already-priced item whose history came from the old per-item scraper:
  // those samples measured a different price, so they're discarded.
  await db.doc(`prices/${GRAFFITI}`).set({marketHashName: GRAFFITI, currentPrice: 0.03});
  await db.doc(`priceHistory/${GRAFFITI}`).set({samples: [{at: now - 24 * HOUR - HOUR, price: 0.03}]});
  // Items that exist only in a user's synced inventory.
  await db.doc('inventories/76561198000000002').set({itemCount: 3});
  await db.doc('inventories/76561198000000002/items/a').set({marketHashName: HOWL});
  await db.doc('inventories/76561198000000002/items/b').set({marketHashName: RARE});
  await db.doc('inventories/76561198000000002/items/c').set({marketHashName: MEDAL});
  // Item names from a user's storage units (written by the app).
  await db.doc('users/76561198000000002').set({displayName: 'Friend', storageItemNames: [CAPSULE, REDLINE]});

  await updatePriceChanges.run({});

  assert.deepEqual(requested.sort(), ['/latest/csfloat.json', '/latest/steam.json']);

  const redline = (await db.doc(`prices/${REDLINE}`).get()).data();
  assert.equal(redline.currentPrice, 1100);
  assert.equal(redline.steamPriceWindow, 'last_24h');
  assert.equal(redline.csfloatPrice, 1080);
  assert.equal(redline.priceChange24h, 10);
  assert.equal(redline.priceHistoryVersion, 2);

  // A friend's item gets priced without the app writing anything.
  const howl = (await db.doc(`prices/${HOWL}`).get()).data();
  assert.equal(howl.marketHashName, HOWL);
  assert.equal(howl.currentPrice, 4000);
  assert.equal(howl.csfloatPrice, 3800);
  assert.equal(howl.priceChange24h, null); // no history yet, so "unknown", not 0%

  const rare = (await db.doc(`prices/${RARE}`).get()).data();
  assert.equal(rare.currentPrice, 250000);
  assert.equal(rare.steamPriceWindow, 'last_30d');
  assert.equal(rare.csfloatPrice, undefined);

  const graffiti = (await db.doc(`prices/${GRAFFITI}`).get()).data();
  assert.equal(graffiti.currentPrice, 0.05);
  assert.equal(graffiti.priceChange24h, null); // old-source history wasn't compared
  const graffitiHistory = (await db.doc(`priceHistory/${GRAFFITI}`).get()).data();
  assert.equal(graffitiHistory.source, 'csgotrader-steam');
  assert.deepEqual(graffitiHistory.samples.map((s) => s.price), [0.05]);

  // Storage-only items get priced too.
  const capsule = (await db.doc(`prices/${CAPSULE}`).get()).data();
  assert.equal(capsule.currentPrice, 0.4);

  // Not on any market: no document is created for it.
  assert.equal((await db.doc(`prices/${MEDAL}`).get()).exists, false);

  // The document the app downloads never carries the history samples.
  assert.equal(redline.samples, undefined);

  const meta = (await db.doc('meta/priceRefresh').get()).data();
  assert.deepEqual(
    {source: meta.source, items: meta.items, steamPriced: meta.steamPriced,
      csfloatPriced: meta.csfloatPriced, missing: meta.missing},
    {source: 'csgotrader', items: 6, steamPriced: 5, csfloatPriced: 2, missing: 1},
  );
  assert.equal(meta.steamUpdatedAt, 'Tue, 27 Oct 2026 01:25:15 GMT');
  assert.equal(meta.cursor, undefined); // stats from the old per-item job are gone
});
