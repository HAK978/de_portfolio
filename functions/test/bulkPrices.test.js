const {test, describe} = require('node:test');
const assert = require('node:assert/strict');
const {
  APP_USER_AGENT,
  BULK_PRICE_BASE,
  MIN_BULK_ITEMS,
  fetchBulkFile,
  pickCsfloatPrice,
  pickSteamPrice,
  priceDocId,
} = require('../lib/bulkPrices');

/** A bulk file with [extra] entries plus enough filler to look complete. */
function bulkFile(extra = {}) {
  const items = {...extra};
  for (let i = 0; Object.keys(items).length < MIN_BULK_ITEMS; i++) items[`filler ${i}`] = {};
  return items;
}

describe('pickSteamPrice', () => {
  test('uses the most recent average available', () => {
    assert.deepEqual(
      pickSteamPrice({last_24h: 43.56, last_7d: 42.8, last_30d: 43.51, last_90d: 43.91}),
      {price: 43.56, window: 'last_24h'});
  });

  test('falls back to longer windows for rarely traded items', () => {
    assert.deepEqual(pickSteamPrice({last_24h: null, last_7d: 12.5, last_30d: 11}), {price: 12.5, window: 'last_7d'});
    assert.deepEqual(pickSteamPrice({last_24h: null, last_7d: null, last_30d: null, last_90d: 3}), {price: 3, window: 'last_90d'});
  });

  test('ignores zero, negative and non-numeric values', () => {
    assert.deepEqual(pickSteamPrice({last_24h: 0, last_7d: -1, last_30d: '9.99', last_90d: 7}), {price: 7, window: 'last_90d'});
  });

  test('no usable price means null', () => {
    for (const entry of [undefined, null, 'x', {}, {last_24h: null, last_7d: 0}]) {
      assert.equal(pickSteamPrice(entry), null, JSON.stringify(entry));
    }
  });
});

describe('pickCsfloatPrice', () => {
  test('uses the lowest listing price', () => {
    assert.equal(pickCsfloatPrice({price: 23.93, starting_at: {price: 23.93}, highest_order: {price: 23}}), 23.93);
  });

  test('falls back to starting_at, and never uses the buy-order price', () => {
    assert.equal(pickCsfloatPrice({starting_at: {price: 5.5}, highest_order: {price: 9}}), 5.5);
    assert.equal(pickCsfloatPrice({highest_order: {price: 9}}), null);
  });

  test('missing or junk entries mean null', () => {
    for (const entry of [undefined, null, 42, {price: 0}, {price: 'free'}]) {
      assert.equal(pickCsfloatPrice(entry), null, JSON.stringify(entry));
    }
  });
});

describe('fetchBulkFile', () => {
  test('downloads the marketplace file and reports when the source refreshed it', async () => {
    let seen;
    const fetcher = async (url, init) => {
      seen = {url, init};
      return Response.json(bulkFile({'AK-47 | Redline (Field-Tested)': {last_24h: 40}}), {
        headers: {'last-modified': 'Tue, 27 Oct 2026 01:25:15 GMT'},
      });
    };
    const file = await fetchBulkFile('steam', fetcher);

    assert.equal(seen.url, `${BULK_PRICE_BASE}/steam.json`);
    assert.equal(seen.init.headers['User-Agent'], APP_USER_AGENT);
    assert.deepEqual(file.items['AK-47 | Redline (Field-Tested)'], {last_24h: 40});
    assert.equal(file.updatedAt, 'Tue, 27 Oct 2026 01:25:15 GMT');
  });

  test('a truncated or broken file is refused, so it can never wipe out prices', async () => {
    const tiny = async () => Response.json({'AK-47 | Redline (Field-Tested)': {last_24h: 40}});
    await assert.rejects(fetchBulkFile('steam', tiny), /looks truncated/);

    const list = async () => Response.json([1, 2, 3]);
    await assert.rejects(fetchBulkFile('steam', list), /unexpected format/);

    const down = async () => new Response('Service Unavailable', {status: 503});
    await assert.rejects(fetchBulkFile('csfloat', down), /HTTP 503/);
  });
});

test('price document IDs replace "/" like the app does', () => {
  assert.equal(priceDocId('Sticker | m0NESY (Holo) | Paris 2023'), 'Sticker | m0NESY (Holo) | Paris 2023');
  assert.equal(priceDocId('Music Kit | Damjan Mravunac, The Talos Principle / x'), 'Music Kit | Damjan Mravunac, The Talos Principle _ x');
});
