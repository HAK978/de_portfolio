const {test} = require('node:test');
const assert = require('node:assert/strict');
const {orderAfterCursor} = require('../lib/cursor');

const ids = ['c', 'a', 'd', 'b'];

test('no cursor starts from the beginning, sorted', () => {
  assert.deepEqual(orderAfterCursor(ids, undefined), ['a', 'b', 'c', 'd']);
  assert.deepEqual(orderAfterCursor(ids, null), ['a', 'b', 'c', 'd']);
});

test('resumes after the last attempted item and wraps around', () => {
  assert.deepEqual(orderAfterCursor(ids, 'b'), ['c', 'd', 'a', 'b']);
});

test('a cursor at the end wraps to the start', () => {
  assert.deepEqual(orderAfterCursor(ids, 'd'), ['a', 'b', 'c', 'd']);
});

test('a deleted cursor document still resumes at the next ID', () => {
  assert.deepEqual(orderAfterCursor(ids, 'bb'), ['c', 'd', 'a', 'b']);
});

test('every item appears exactly once', () => {
  for (const cursor of [undefined, 'a', 'b', 'c', 'd', 'zzz', '']) {
    assert.deepEqual([...orderAfterCursor(ids, cursor)].sort(), ['a', 'b', 'c', 'd']);
  }
});

test('ordering does not depend on the locale', () => {
  // localeCompare would put "a" before "B"; code-unit order puts "B" first.
  assert.deepEqual(orderAfterCursor(['a', 'B'], undefined), ['B', 'a']);
});
