// Security-rules tests: run the real firestore.rules in the Firestore
// emulator and check who can read/write what.
//
// Run with `npm run test:emulator` (needs Java for the emulator).

const {test, describe, before, after, beforeEach} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {doc, getDoc, getDocs, collection, setDoc, updateDoc, deleteDoc} = require('firebase/firestore');

const OWNER = '76561198369694237'; // the only account allowed to write shared prices
const OTHER = '76561198000000002';

let env;

/** Firestore client signed in as [uid], with or without the steamVerified claim. */
const asUser = (uid, {verified = true} = {}) =>
  env.authenticatedContext(uid, verified ? {steamVerified: true} : {}).firestore();
const asAnonymous = () => env.unauthenticatedContext().firestore();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-cs2-portfolio',
    firestore: {rules: fs.readFileSync(path.join(__dirname, '../../../firestore.rules'), 'utf8')},
  });
});

after(() => env?.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `inventories/${OWNER}`), {itemCount: 1});
    await setDoc(doc(db, `inventories/${OWNER}/items/ak`), {currentPrice: 12.5});
    await setDoc(doc(db, `users/${OWNER}`), {displayName: 'Owner'});
    await setDoc(doc(db, 'prices/AK-47 | Redline (Field-Tested)'), {currentPrice: 12.5});
    await setDoc(doc(db, 'meta/priceRefresh'), {updated: 1});
    await setDoc(doc(db, 'priceHistory/ak'), {samples: []});
    await setDoc(doc(db, 'steamLoginSessions/abc'), {returnTo: 'x'});
    await setDoc(doc(db, 'alerts/owner-alert'), {steamId: OWNER, threshold: 10});
  });
});

describe('inventories', () => {
  test('owners can read and write their own inventory and items', async () => {
    const db = asUser(OWNER);
    await assertSucceeds(getDoc(doc(db, `inventories/${OWNER}`)));
    await assertSucceeds(getDocs(collection(db, `inventories/${OWNER}/items`)));
    await assertSucceeds(setDoc(doc(db, `inventories/${OWNER}/items/m4`), {currentPrice: 3}));
    await assertSucceeds(deleteDoc(doc(db, `inventories/${OWNER}/items/ak`)));
  });

  test('another verified user cannot read or write someone else\'s inventory', async () => {
    const db = asUser(OTHER);
    await assertFails(getDoc(doc(db, `inventories/${OWNER}`)));
    await assertFails(getDocs(collection(db, `inventories/${OWNER}/items`)));
    await assertFails(setDoc(doc(db, `inventories/${OWNER}/items/ak`), {currentPrice: 0}));
  });

  test('tokens from the old unverified login get nothing, even for their own UID', async () => {
    const db = asUser(OWNER, {verified: false});
    await assertFails(getDoc(doc(db, `inventories/${OWNER}`)));
    await assertFails(getDocs(collection(db, `inventories/${OWNER}/items`)));
    await assertFails(setDoc(doc(db, `inventories/${OWNER}/items/ak`), {currentPrice: 0}));
  });

  test('signed-out clients get nothing', async () => {
    await assertFails(getDoc(doc(asAnonymous(), `inventories/${OWNER}/items/ak`)));
  });
});

describe('users', () => {
  test('only the owner of a profile can read or write it', async () => {
    await assertSucceeds(setDoc(doc(asUser(OWNER), `users/${OWNER}`), {displayName: 'Me'}));
    await assertFails(getDoc(doc(asUser(OTHER), `users/${OWNER}`)));
    await assertFails(getDoc(doc(asUser(OWNER, {verified: false}), `users/${OWNER}`)));
  });
});

describe('prices (shared)', () => {
  const priceDoc = (db) => doc(db, 'prices/AK-47 | Redline (Field-Tested)');

  test('any verified user can read prices', async () => {
    await assertSucceeds(getDoc(priceDoc(asUser(OTHER))));
    await assertSucceeds(getDocs(collection(asUser(OTHER), 'prices')));
  });

  test('only the app owner can write them', async () => {
    await assertSucceeds(setDoc(priceDoc(asUser(OWNER)), {currentPrice: 13}));
    await assertFails(setDoc(priceDoc(asUser(OTHER)), {currentPrice: 9999}));
    await assertFails(updateDoc(priceDoc(asUser(OWNER, {verified: false})), {currentPrice: 9999}));
  });

  test('signed-out clients cannot read them', async () => {
    await assertFails(getDoc(priceDoc(asAnonymous())));
  });
});

describe('server-only data', () => {
  test('meta is readable by verified users but never client-writable', async () => {
    await assertSucceeds(getDoc(doc(asUser(OTHER), 'meta/priceRefresh')));
    await assertFails(setDoc(doc(asUser(OWNER), 'meta/priceRefresh'), {lastRun: 0}));
    await assertFails(getDoc(doc(asUser(OWNER, {verified: false}), 'meta/priceRefresh')));
  });

  test('login sessions and price history are invisible to every client', async () => {
    for (const db of [asUser(OWNER), asUser(OTHER), asAnonymous()]) {
      await assertFails(getDoc(doc(db, 'steamLoginSessions/abc')));
      await assertFails(setDoc(doc(db, 'steamLoginSessions/new'), {returnTo: 'https://evil.example'}));
      await assertFails(getDoc(doc(db, 'priceHistory/ak')));
      await assertFails(setDoc(doc(db, 'priceHistory/ak'), {samples: []}));
    }
  });

  test('collections without a rule are denied', async () => {
    await assertFails(setDoc(doc(asUser(OWNER), 'anything/else'), {x: 1}));
  });
});

describe('alerts', () => {
  test('users can create, read and delete only their own alerts', async () => {
    const db = asUser(OTHER);
    await assertSucceeds(setDoc(doc(db, 'alerts/mine'), {steamId: OTHER, threshold: 5}));
    await assertSucceeds(getDoc(doc(db, 'alerts/mine')));
    await assertSucceeds(deleteDoc(doc(db, 'alerts/mine')));
    await assertFails(setDoc(doc(db, 'alerts/forged'), {steamId: OWNER, threshold: 5}));
    await assertFails(getDoc(doc(db, 'alerts/owner-alert')));
    await assertFails(deleteDoc(doc(db, 'alerts/owner-alert')));
  });

  test('an alert cannot be handed over to another user', async () => {
    const db = asUser(OWNER);
    await assertSucceeds(updateDoc(doc(db, 'alerts/owner-alert'), {threshold: 20}));
    await assertFails(updateDoc(doc(db, 'alerts/owner-alert'), {steamId: OTHER}));
  });
});
