// Tests for refresh-token persistence (token.js). Losing or corrupting
// this file means a manual Steam Guard login on the VM, so the write
// path and the renewal decision are worth pinning down.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { readToken, writeToken, tokenExpiryMs, shouldRenew, RENEW_WITHIN_MS } = require('../token');

const DAY = 24 * 60 * 60 * 1000;

/** A JWT-shaped token with the given payload (signature is irrelevant here). */
function fakeJwt(payload) {
  const part = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  return `${part({ typ: 'JWT', alg: 'EdDSA' })}.${part(payload)}.signature`;
}

/** A fresh temp directory, removed when test [t] finishes. */
function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'token-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('writeToken round-trips and leaves no temp files behind', (t) => {
  const dir = tempDir(t);
  const file = path.join(dir, '.refresh_token');
  writeToken(file, 'first');
  writeToken(file, 'second'); // overwrite an existing token
  assert.equal(readToken(file), 'second');
  assert.deepEqual(fs.readdirSync(dir), ['.refresh_token']);
});

test('writeToken makes the file owner-only', { skip: process.platform === 'win32' }, (t) => {
  const file = path.join(tempDir(t), '.refresh_token');
  writeToken(file, 'secret');
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
});

test('readToken returns null for a missing or blank file', (t) => {
  const dir = tempDir(t);
  assert.equal(readToken(path.join(dir, 'missing')), null);
  fs.writeFileSync(path.join(dir, 'blank'), '  \n');
  assert.equal(readToken(path.join(dir, 'blank')), null);
});

test('readToken trims the trailing newline editors add', (t) => {
  const file = path.join(tempDir(t), '.refresh_token');
  fs.writeFileSync(file, 'token-value\n');
  assert.equal(readToken(file), 'token-value');
});

test('tokenExpiryMs decodes the JWT exp claim', () => {
  assert.equal(tokenExpiryMs(fakeJwt({ exp: 1_800_000_000 })), 1_800_000_000_000);
  assert.equal(tokenExpiryMs('not-a-jwt'), null);
  assert.equal(tokenExpiryMs(fakeJwt({ sub: 'no exp' })), null);
  assert.equal(tokenExpiryMs(''), null);
});

test('shouldRenew only inside the renewal window', () => {
  const now = Date.UTC(2026, 9, 6);
  const expiringIn = (ms) => fakeJwt({ exp: Math.floor((now + ms) / 1000) });
  assert.equal(RENEW_WITHIN_MS, 30 * DAY);
  assert.equal(shouldRenew(expiringIn(31 * DAY), now), false);
  assert.equal(shouldRenew(expiringIn(22 * DAY), now), true);
  assert.equal(shouldRenew(expiringIn(-DAY), now), true); // already expired: still try
  // Undecodable tokens don't trigger a daily re-logon loop.
  assert.equal(shouldRenew('garbage', now), false);
});
