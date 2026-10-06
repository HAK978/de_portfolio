const {test} = require('node:test');
const assert = require('node:assert/strict');
const {newSteamLogin, sessionKey, verifySteamAssertion, STEAM_ENDPOINT} = require('../lib/steamAuth');

const now = Date.parse('2026-09-16T12:00:00Z');
const login = newSteamLogin('https://example.com/steamLoginReturn');
const identity = 'https://steamcommunity.com/openid/id/76561198000000001';
const valid = () => ({
  'openid.ns': 'http://specs.openid.net/auth/2.0',
  'openid.mode': 'id_res',
  'openid.op_endpoint': STEAM_ENDPOINT,
  'openid.claimed_id': identity,
  'openid.identity': identity,
  'openid.return_to': login.returnTo,
  'openid.response_nonce': '2026-09-16T12:00:00Zunique',
  'openid.signed': 'op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle',
  'openid.assoc_handle': 'handle',
  'openid.sig': 'signed-by-steam',
});

test('each login has an unpredictable, bound session and fixed Steam endpoint', () => {
  const other = newSteamLogin('https://example.com/steamLoginReturn');
  assert.notEqual(login.sessionId, other.sessionId);
  assert.equal(new URL(login.returnTo).searchParams.get('state'), login.sessionId);
  assert.equal(new URL(login.loginUrl).origin, 'https://steamcommunity.com');
  assert.equal(new URL(login.loginUrl).searchParams.get('openid.return_to'), login.returnTo);
  assert.throws(() => sessionKey('76561198000000001'));
});

test('identity is returned only after Steam verifies the signed assertion', async () => {
  const id = await verifySteamAssertion(valid(), login.returnTo, now, async (url, options) => {
    assert.equal(url, STEAM_ENDPOINT);
    assert.equal(options.redirect, 'error');
    assert.equal(options.body.get('openid.mode'), 'check_authentication');
    assert.equal(options.body.get('openid.claimed_id'), identity);
    return new Response('ns:http://specs.openid.net/auth/2.0\nis_valid:true\n');
  });
  assert.equal(id, '76561198000000001');
});

for (const [label, patch] of [
  ['another session', {'openid.return_to': 'https://example.com/steamLoginReturn?state=other'}],
  ['unsigned identity', {'openid.signed': 'return_to,response_nonce'}],
  ['another provider', {'openid.op_endpoint': 'https://attacker.example/login'}],
  ['different identity', {'openid.identity': identity + '2'}],
  ['expired assertion', {'openid.response_nonce': '2026-09-16T11:49:59Zold'}],
  ['future assertion', {'openid.response_nonce': '2026-09-16T13:00:00Zfuture'}],
  ['public profile URL', {'openid.claimed_id': 'https://steamcommunity.com/profiles/76561198000000001'}],
]) {
  test(`rejects ${label} before contacting an endpoint`, async () => {
    await assert.rejects(verifySteamAssertion({...valid(), ...patch}, login.returnTo, now,
      async () => { assert.fail('must reject locally'); }));
  });
}

test('rejects a Steam rejection and misleading response text', async () => {
  for (const body of ['is_valid:false\n', 'not_is_valid:true\n']) {
    await assert.rejects(verifySteamAssertion(valid(), login.returnTo, now,
      async () => new Response(body)));
  }
});

test('legacy Steam-ID-only callable requests cannot mint tokens', async () => {
  const {createCustomToken} = require('../lib/index');
  await assert.rejects(createCustomToken.run({data: {steamId: '76561198000000001'}}),
    {code: 'invalid-argument'});
});
