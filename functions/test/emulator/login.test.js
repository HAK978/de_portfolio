// End-to-end tests of the Steam login callables against the Firestore
// and Auth emulators. Steam itself is faked by intercepting fetch calls
// to its OpenID endpoint; everything else (session storage, one-time
// use, token minting) is the real code path.
//
// Run with `npm run test:emulator`.

const {test, beforeEach, afterEach} = require('node:test');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {getFirestore, Timestamp} = require('firebase-admin/firestore');
const {beginSteamLogin, createCustomToken} = require('../../lib/index');
const {STEAM_ENDPOINT} = require('../../lib/steamAuth');

const STEAM_ID = '76561198000000001';
const NS = 'http://specs.openid.net/auth/2.0';

const realFetch = globalThis.fetch;
let steamAnswer; // body Steam returns for check_authentication
let steamCalls;

beforeEach(() => {
  steamAnswer = `ns:${NS}\nis_valid:true\n`;
  steamCalls = 0;
  globalThis.fetch = async (url, init) => {
    if (String(url) !== STEAM_ENDPOINT) return realFetch(url, init);
    steamCalls++;
    return new Response(steamAnswer);
  };
});

afterEach(() => {
  globalThis.fetch = realFetch;
});

/** What Steam would append to return_to after a successful login. */
function assertionFor(login, overrides = {}) {
  const identity = `https://steamcommunity.com/openid/id/${STEAM_ID}`;
  return {
    'openid.ns': NS,
    'openid.mode': 'id_res',
    'openid.op_endpoint': STEAM_ENDPOINT,
    'openid.claimed_id': identity,
    'openid.identity': identity,
    'openid.return_to': login.returnTo,
    'openid.response_nonce': `${new Date().toISOString().slice(0, 19)}Zabc123`,
    'openid.assoc_handle': '1234567890',
    'openid.signed': 'signed,op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle',
    'openid.sig': 'c2lnbmF0dXJl',
    ...overrides,
  };
}

const sessionDoc = (sessionId) => getFirestore().collection('steamLoginSessions')
  .doc(createHash('sha256').update(sessionId).digest('hex'));

function decodeJwt(token) {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
}

async function rejectsWith(promise, code) {
  await assert.rejects(promise, (err) => {
    assert.equal(err.code, code);
    return true;
  });
}

test('a verified Steam login mints a token for that account, once', async () => {
  const login = await beginSteamLogin.run({});
  const result = await createCustomToken.run({data: {sessionId: login.sessionId, assertion: assertionFor(login)}});

  assert.equal(result.steamId, STEAM_ID);
  const claims = decodeJwt(result.token);
  assert.equal(claims.uid, STEAM_ID);
  assert.equal(claims.claims.steamVerified, true);
  assert.equal(steamCalls, 1);

  // The session is consumed: replaying the same assertion fails.
  assert.equal((await sessionDoc(login.sessionId).get()).exists, false);
  await rejectsWith(
    createCustomToken.run({data: {sessionId: login.sessionId, assertion: assertionFor(login)}}),
    'unauthenticated');
});

test('only a hash of the session ID is stored server-side', async () => {
  const login = await beginSteamLogin.run({});
  assert.match(login.sessionId, /^[a-f0-9]{64}$/);
  const stored = await sessionDoc(login.sessionId).get();
  assert.equal(stored.exists, true);
  assert.notEqual(stored.id, login.sessionId);
  assert.equal(stored.data().returnTo, login.returnTo);
});

test('an expired session is refused before Steam is contacted', async () => {
  const login = await beginSteamLogin.run({});
  await sessionDoc(login.sessionId).update({expiresAt: Timestamp.fromMillis(Date.now() - 1000)});
  await rejectsWith(
    createCustomToken.run({data: {sessionId: login.sessionId, assertion: assertionFor(login)}}),
    'unauthenticated');
  assert.equal(steamCalls, 0);
});

test('an assertion made for another session is refused', async () => {
  const mine = await beginSteamLogin.run({});
  const theirs = await beginSteamLogin.run({});
  await rejectsWith(
    createCustomToken.run({data: {sessionId: mine.sessionId, assertion: assertionFor(theirs)}}),
    'unauthenticated');
  assert.equal(steamCalls, 0);
});

test('when Steam rejects the assertion, no token is issued and the session survives for a retry', async () => {
  const login = await beginSteamLogin.run({});
  steamAnswer = `ns:${NS}\nis_valid:false\n`;
  await rejectsWith(
    createCustomToken.run({data: {sessionId: login.sessionId, assertion: assertionFor(login)}}),
    'unauthenticated');
  assert.equal((await sessionDoc(login.sessionId).get()).exists, true);

  steamAnswer = `ns:${NS}\nis_valid:true\n`;
  const result = await createCustomToken.run({data: {sessionId: login.sessionId, assertion: assertionFor(login)}});
  assert.equal(result.steamId, STEAM_ID);
});

test('unknown or malformed session IDs are refused', async () => {
  const login = await beginSteamLogin.run({});
  await rejectsWith(
    createCustomToken.run({data: {sessionId: 'f'.repeat(64), assertion: assertionFor(login)}}),
    'unauthenticated');
  await rejectsWith(
    createCustomToken.run({data: {sessionId: '../steamLoginSessions', assertion: assertionFor(login)}}),
    'invalid-argument');
  // The old API (just a Steam ID) is gone.
  await rejectsWith(createCustomToken.run({data: {steamId: STEAM_ID}}), 'invalid-argument');
});
