// Tests for turning raw Game Coordinator items into market names
// (itemResolver.js). The market hash name is the key every price lookup
// uses, so a wrong name means an item silently shows no price.
// Uses the item definitions bundled in itemData/, so no network.

const { test, before } = require('node:test');
const assert = require('node:assert/strict');
const ItemResolver = require('../itemResolver');

const STATTRAK = { def_index: 80, value_bytes: Buffer.alloc(4) };
const SOUVENIR = { def_index: 140, value_bytes: Buffer.alloc(4) };

// Real indexes from items_game: def 7 = AK-47, paint 282 = Redline,
// def 507 = Karambit, paint 418 = Doppler, def 16 = M4A4, paint 309 = Howl.
const redline = (wear, extra = {}) =>
  ({ id: '1', def_index: 7, paint_index: 282, paint_wear: wear, quality: 4, rarity: 5, ...extra });

let resolver;
before(() => {
  resolver = new ItemResolver();
  resolver.loadBundledData();
});

test('builds the market hash name with the wear suffix', () => {
  const item = resolver._convertItem(redline(0.2));
  assert.equal(item.marketHashName, 'AK-47 | Redline (Field-Tested)');
  assert.equal(item.rarity, 'Classified');
  assert.equal(item.isStatTrak, false);
});

test('StatTrak knives put the star first, like Steam does', () => {
  const knife = resolver._convertItem({
    id: '2', def_index: 507, paint_index: 418, paint_wear: 0.01, quality: 3, rarity: 6, attribute: [STATTRAK],
  });
  assert.equal(knife.marketHashName, '★ StatTrak™ Karambit | Doppler (Factory New)');
  assert.equal(knife.rarity, 'Covert');
});

test('Souvenir items get the Souvenir prefix', () => {
  const item = resolver._convertItem(redline(0.2, { quality: 12, attribute: [SOUVENIR] }));
  assert.equal(item.marketHashName, 'Souvenir AK-47 | Redline (Field-Tested)');
});

test('wear ranges are half-open at every boundary', () => {
  const wearOf = (f) => resolver._convertItem(redline(f)).wear;
  assert.equal(wearOf(0), 'Factory New');
  assert.equal(wearOf(0.0699), 'Factory New');
  assert.equal(wearOf(0.07), 'Minimal Wear');
  assert.equal(wearOf(0.15), 'Field-Tested');
  assert.equal(wearOf(0.38), 'Well-Worn');
  assert.equal(wearOf(0.45), 'Battle-Scarred');
  assert.equal(wearOf(1), 'Battle-Scarred');
});

test('GC rarity 7 is Contraband (M4A4 | Howl)', () => {
  const howl = resolver._convertItem({ id: '4', def_index: 16, paint_index: 309, paint_wear: 0.3, quality: 4, rarity: 7 });
  assert.equal(howl.marketHashName, 'M4A4 | Howl (Field-Tested)');
  assert.equal(howl.rarity, 'Contraband');
});

test('items without wear have no suffix', () => {
  const unit = resolver._convertItem({ id: '5', def_index: 1201, quality: 4, rarity: 0 });
  assert.equal(unit.marketHashName, 'Storage Unit');
  assert.equal(unit.wear, null);
});

test('convertStorageItems skips items it cannot resolve instead of failing the casket', () => {
  const items = resolver.convertStorageItems([
    redline(0.2),
    { id: '6', def_index: 999999, quality: 4 }, // unknown definition
    { id: '7' }, // no def_index at all
  ]);
  assert.deepEqual(items.map((i) => i.marketHashName), ['AK-47 | Redline (Field-Tested)']);
});

test('music kit index is read from attribute 166', () => {
  const value = Buffer.alloc(4);
  value.writeUInt32LE(3, 0);
  const item = { id: '8', def_index: 1314, attribute: [{ def_index: 166, value_bytes: value }] };
  resolver._extractMusicIndex(item);
  assert.equal(item.music_index, 3);
});
