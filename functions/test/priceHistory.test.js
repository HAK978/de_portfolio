const {test} = require('node:test');
const assert = require('node:assert/strict');
const {updatePriceHistory} = require('../lib/priceHistory');
const HOUR = 3600000;
const DAY = 24 * HOUR;
const now = 100 * DAY;

test('new items have no invented daily, weekly or monthly change', () => {
  const first = updatePriceHistory(undefined, 100, now);
  const next = updatePriceHistory(first.priceHistory, 110, now + 4 * HOUR);
  for (const key of ['priceChange24h', 'priceChange7d', 'priceChange30d']) {
    assert.equal(next[key], null);
  }
});

test('each lookback uses its own historical observation', () => {
  const history = [
    {at: now - 30 * DAY, price: 50},
    {at: now - 7 * DAY, price: 80},
    {at: now - DAY, price: 100},
  ];
  const result = updatePriceHistory(history, 110, now);
  assert.equal(result.priceChange24h, 10);
  assert.equal(result.priceChange7d, 37.5);
  assert.equal(result.priceChange30d, 120);
});

test('daily change still uses a full day after the next four-hour refresh', () => {
  const initial = updatePriceHistory([
    {at: now - DAY, price: 100},
    {at: now - DAY + 4 * HOUR, price: 105},
  ], 110, now);
  const next = updatePriceHistory(initial.priceHistory, 115.5, now + 4 * HOUR);
  assert.equal(next.priceChange24h, 10);
});

test('missing or excessively old observations clear previously available changes', () => {
  assert.equal(updatePriceHistory([{at: now - DAY - 9 * HOUR, price: 100}], 110, now).priceChange24h, null);
  assert.equal(updatePriceHistory([{at: now - DAY + HOUR, price: 100}], 110, now).priceChange24h, null);
});

test('drops corrupt/future samples and bounds repeated observations', () => {
  const result = updatePriceHistory([
    null, {at: now + DAY, price: 12}, {at: now - DAY, price: 0},
    {at: now - 32 * DAY, price: 50}, {at: now, price: 100},
  ], 110, now + 1000);
  assert.deepEqual(result.priceHistory, [{at: now, price: 100}]);
  assert.equal(result.priceChange24h, null);
});
