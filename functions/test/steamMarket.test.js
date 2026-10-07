const {test, describe} = require('node:test');
const assert = require('node:assert/strict');
const {
  STEAM_USER_AGENT,
  BlockBreaker,
  fetchSteamPrice,
  parseUsdPrice,
} = require('../lib/steamMarket');

const noSleep = async () => {};

/** A fetch that answers each call with the next response in [responses]. */
function fakeFetch(responses) {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({url: String(url), init});
    const next = responses[Math.min(calls.length - 1, responses.length - 1)];
    if (next instanceof Error) throw next;
    return next;
  };
  return {fetcher, calls};
}

const json = (body, status = 200) => Response.json(body, {status});
const priced = (lowest) => json({success: true, lowest_price: lowest, median_price: '$1.00'});

describe('parseUsdPrice', () => {
  test('handles thousands separators and symbols', () => {
    assert.equal(parseUsdPrice('$1,234.96'), 1234.96);
    assert.equal(parseUsdPrice('$0.03'), 0.03);
  });

  test('rejects missing, zero and unparseable values', () => {
    for (const raw of [undefined, '', '$0.00', 'free', '--']) {
      assert.equal(parseUsdPrice(raw), null, String(raw));
    }
  });
});

describe('fetchSteamPrice', () => {
  test('identifies the app to Steam instead of using Node\'s default signature', async () => {
    const {fetcher, calls} = fakeFetch([priced('$12.50')]);
    const result = await fetchSteamPrice('AK-47 | Redline (Field-Tested)', {fetcher, sleep: noSleep});

    assert.deepEqual(result, {price: 12.5, outcome: 'ok'});
    assert.equal(calls[0].init.headers['User-Agent'], STEAM_USER_AGENT);
    assert.match(STEAM_USER_AGENT, /^CS2PortfolioManager\/.+github\.com\/HAK978\/de_portfolio/);
    const url = new URL(calls[0].url);
    assert.equal(url.pathname, '/market/priceoverview/');
    assert.equal(url.searchParams.get('market_hash_name'), 'AK-47 | Redline (Field-Tested)');
  });

  test('falls back to the median price when there is no lowest price', async () => {
    const {fetcher} = fakeFetch([json({success: true, median_price: '$3.20'})]);
    assert.equal((await fetchSteamPrice('x', {fetcher, sleep: noSleep})).price, 3.2);
  });

  test('"no listing" is not a failure', async () => {
    for (const body of [{success: false}, {success: true}]) {
      const {fetcher} = fakeFetch([json(body)]);
      assert.deepEqual(await fetchSteamPrice('x', {fetcher, sleep: noSleep}), {price: null, outcome: 'no_listing'});
    }
  });

  test('retries once on 429 and succeeds if Steam relents', async () => {
    const waits = [];
    const {fetcher, calls} = fakeFetch([json({}, 429), priced('$5.00')]);
    const result = await fetchSteamPrice('x', {fetcher, sleep: async (ms) => waits.push(ms)});

    assert.deepEqual(result, {price: 5, outcome: 'ok'});
    assert.equal(calls.length, 2);
    assert.deepEqual(waits, [5000]);
  });

  test('a second 429, or a 403, means Steam is refusing us', async () => {
    const twice = fakeFetch([json({}, 429)]);
    assert.deepEqual(await fetchSteamPrice('x', {fetcher: twice.fetcher, sleep: noSleep}), {price: null, outcome: 'blocked'});
    assert.equal(twice.calls.length, 2);

    const forbidden = fakeFetch([json({}, 403)]);
    assert.deepEqual(await fetchSteamPrice('x', {fetcher: forbidden.fetcher, sleep: noSleep}), {price: null, outcome: 'blocked'});
    assert.equal(forbidden.calls.length, 1);
  });

  test('network failures and server errors are plain errors', async () => {
    const down = fakeFetch([new TypeError('fetch failed')]);
    assert.deepEqual(await fetchSteamPrice('x', {fetcher: down.fetcher, sleep: noSleep}), {price: null, outcome: 'error'});

    const broken = fakeFetch([json({}, 500)]);
    assert.deepEqual(await fetchSteamPrice('x', {fetcher: broken.fetcher, sleep: noSleep}), {price: null, outcome: 'error'});
  });
});

describe('BlockBreaker', () => {
  const refuse = (breaker, times) => {
    for (let i = 0; i < times; i++) {
      assert.equal(breaker.shouldAttempt(), true);
      breaker.record('blocked');
    }
  };

  test('opens only after the threshold of refusals in a row', () => {
    const breaker = new BlockBreaker(3, 5);
    refuse(breaker, 2);
    assert.equal(breaker.isOpen, false);
    refuse(breaker, 1);
    assert.equal(breaker.isOpen, true);
  });

  test('a success in between resets the count', () => {
    const breaker = new BlockBreaker(3, 5);
    refuse(breaker, 2);
    breaker.record('ok');
    refuse(breaker, 2);
    assert.equal(breaker.isOpen, false);
  });

  test('ordinary errors and missing listings never open it', () => {
    const breaker = new BlockBreaker(3, 5);
    for (let i = 0; i < 50; i++) breaker.record('error');
    for (let i = 0; i < 50; i++) breaker.record('no_listing');
    assert.equal(breaker.isOpen, false);
    assert.equal(breaker.shouldAttempt(), true);
  });

  test('while open, skips lookups and lets one probe through every few items', () => {
    const breaker = new BlockBreaker(3, 5);
    refuse(breaker, 3);

    const decisions = Array.from({length: 12}, () => breaker.shouldAttempt());
    assert.deepEqual(decisions, [
      false, false, false, false, false, true, // probe after 5 skipped
      false, false, false, false, false, true,
    ]);
  });

  test('a successful probe closes it again; a refused probe keeps it open', () => {
    const breaker = new BlockBreaker(3, 2);
    refuse(breaker, 3);
    breaker.shouldAttempt();
    breaker.shouldAttempt();
    assert.equal(breaker.shouldAttempt(), true); // probe
    breaker.record('blocked');
    assert.equal(breaker.isOpen, true);

    breaker.shouldAttempt();
    breaker.shouldAttempt();
    assert.equal(breaker.shouldAttempt(), true); // next probe
    breaker.record('ok');
    assert.equal(breaker.isOpen, false);
    assert.equal(breaker.shouldAttempt(), true);
  });
});
