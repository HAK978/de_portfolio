// Runs the scheduled price refresh against the Firestore emulator, with
// Steam Market and CSFloat faked at the fetch layer.
//
// Run with `npm run test:emulator`.

const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');

process.env.CSFLOAT_API_KEY = 'test-key'; // read by defineSecret at run time
const admin = require('firebase-admin');
const {updatePriceChanges} = require('../../lib/index');

const HOUR = 60 * 60 * 1000;
const realFetch = globalThis.fetch;

before(() => {
  globalThis.fetch = async (url, init) => {
    const u = new URL(String(url));
    const name = u.searchParams.get('market_hash_name');
    if (u.hostname === 'steamcommunity.com') {
      // Steam answers 429 to Node's default User-Agent, so the job must identify itself.
      assert.ok(init.headers['User-Agent'].startsWith('CS2PortfolioManager/'), 'Steam request must identify the app');
      if (name === 'Unlisted Item') return Response.json({success: false});
      return Response.json({success: true, lowest_price: '$1,100.00'});
    }
    if (u.hostname === 'csfloat.com') {
      assert.equal(init.headers.Authorization, 'test-key');
      return Response.json(name === 'Unlisted Item' ? [] : [{price: 110000}]);
    }
    return realFetch(url, init);
  };
});

after(() => {
  globalThis.fetch = realFetch;
});

test('refresh writes prices and changes to prices/, samples to priceHistory/', async () => {
  const db = admin.firestore();
  const now = Date.now();
  await db.doc('prices/ak').set({
    marketHashName: 'AK-47 | Redline (Field-Tested)',
    currentPrice: 1000,
    previousPrice24h: 900, // leftover from the old baseline scheme
    baselineTakenAt: now - 30 * HOUR,
  });
  await db.doc('priceHistory/ak').set({samples: [{at: now - 24 * HOUR - HOUR, price: 1000}]});
  await db.doc('prices/unlisted').set({marketHashName: 'Unlisted Item', currentPrice: 5});
  await db.doc('prices/broken').set({currentPrice: 1}); // no marketHashName

  await updatePriceChanges.run({});

  const price = (await db.doc('prices/ak').get()).data();
  assert.equal(price.currentPrice, 1100);
  assert.equal(price.csfloatPrice, 1100);
  assert.equal(price.priceChange24h, 10);
  assert.equal(price.priceChange7d, null);
  assert.equal(price.priceHistoryVersion, 2);
  // The document the app downloads stays small: no samples, no old baseline fields.
  assert.equal(price.samples, undefined);
  assert.equal(price.priceHistory, undefined);
  assert.equal(price.previousPrice24h, undefined);
  assert.equal(price.baselineTakenAt, undefined);

  const history = (await db.doc('priceHistory/ak').get()).data();
  assert.equal(history.samples.length, 2);
  assert.equal(history.samples.at(-1).price, 1100);

  // Items with no listing on either market are left alone.
  assert.equal((await db.doc('prices/unlisted').get()).data().currentPrice, 5);
  assert.equal((await db.doc('priceHistory/unlisted').get()).exists, false);

  const meta = (await db.doc('meta/priceRefresh').get()).data();
  assert.deepEqual(
    {
      updated: meta.updated, skipped: meta.skipped, total: meta.total, unreached: meta.unreached,
      steamBlocked: meta.steamBlocked, steamSkipped: meta.steamSkipped,
    },
    {updated: 1, skipped: 2, total: 3, unreached: 0, steamBlocked: 0, steamSkipped: 0},
  );
  assert.equal(typeof meta.cursor, 'string');
});
