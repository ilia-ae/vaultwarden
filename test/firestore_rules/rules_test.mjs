// Security-rules test for ../../firestore.rules (settings cloud sync, R2/A15).
//
// No npm dependencies: talks to the Firestore emulator's REST API with the
// emulator's unsigned test tokens. Run from the repository root:
//
//   sh test/firestore_rules/run.sh
//
// Writes mirror the app: set(..., merge: true) of every field with
// updatedAt = FieldValue.serverTimestamp() (SettingsSyncService.push).

const host = process.env.FIRESTORE_EMULATOR_HOST ?? '127.0.0.1:18480';
const project = process.env.GCLOUD_PROJECT ?? 'demo-vaultapprover';
const root = `projects/${project}/databases/(default)/documents`;
const api = `http://${host}/v1/${root}`;

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function idToken(uid) {
  const now = Math.floor(Date.now() / 1000);
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
    iss: `https://securetoken.google.com/${project}`,
    aud: project,
    auth_time: now,
    iat: now,
    exp: now + 3600,
    sub: uid,
    user_id: uid,
    firebase: { identities: {}, sign_in_provider: 'custom' },
  })}.`;
}

function value(v) {
  if (v === null) return { nullValue: null };
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (Number.isInteger(v)) return { integerValue: String(v) };
  return { doubleValue: v };
}

const fields = (data) =>
  Object.fromEntries(Object.entries(data).map(([k, v]) => [k, value(v)]));

async function call(method, url, auth, body) {
  const headers = { 'Content-Type': 'application/json' };
  if (auth) headers.Authorization = `Bearer ${auth}`;
  const res = await fetch(url, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.status;
}

/** set(data, merge: true) + updatedAt serverTimestamp, as the app does. */
function mergeWrite(auth, uid, data, { serverTimestamp = true } = {}) {
  return call('POST', `${api}:commit`, auth, {
    writes: [
      {
        update: { name: `${root}/users/${uid}`, fields: fields(data) },
        updateMask: { fieldPaths: Object.keys(data) },
        ...(serverTimestamp
          ? {
              updateTransforms: [
                { fieldPath: 'updatedAt', setToServerValue: 'REQUEST_TIME' },
              ],
            }
          : {}),
      },
    ],
  });
}

const read = (auth, uid) => call('GET', `${api}/users/${uid}`, auth);
const remove = (auth, uid) => call('DELETE', `${api}/users/${uid}`, auth);
/** Admin write that bypasses the rules (seeds documents of older clients). */
const seed = (uid, data) =>
  call('PATCH', `${api}/users/${uid}`, 'owner', { fields: fields(data) });

const valid = {
  themeMode: 'dark',
  locale: 'zh-Hans',
  lockTimeout: 60,
  pollInterval: 15,
};

let failures = 0;
async function expectStatus(name, promise, allowed) {
  const status = await promise;
  const ok = allowed ? status === 200 : status === 403;
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name} → HTTP ${status}`);
}

const alice = idToken('alice');
const bob = idToken('bob');

await call('DELETE', `http://${host}/emulator/v1/${root}`);

await expectStatus('owner writes valid settings (merge + serverTimestamp)',
  mergeWrite(alice, 'alice', valid), true);
await expectStatus('owner reads own settings', read(alice, 'alice'), true);
await expectStatus('locale null (follow system) is accepted',
  mergeWrite(alice, 'alice', { ...valid, locale: null }), true);
await expectStatus('write without lockTimeout (local "never") is accepted',
  mergeWrite(alice, 'alice', { themeMode: 'light', locale: null, pollInterval: 30 }), true);
await expectStatus('every offered lock timeout is accepted',
  Promise.all([0, 15, 60, 300, 900, -1].map((t) =>
    mergeWrite(alice, 'alice', { ...valid, lockTimeout: t }))).then((s) =>
    (s.every((x) => x === 200) ? 200 : 403)), true);
await expectStatus('every offered poll interval is accepted',
  Promise.all([5, 15, 30, 60].map((p) =>
    mergeWrite(alice, 'alice', { ...valid, pollInterval: p }))).then((s) =>
    (s.every((x) => x === 200) ? 200 : 403)), true);

await expectStatus('pollInterval 0 is rejected',
  mergeWrite(alice, 'alice', { ...valid, pollInterval: 0 }), false);
await expectStatus('negative pollInterval is rejected',
  mergeWrite(alice, 'alice', { ...valid, pollInterval: -5 }), false);
await expectStatus('pollInterval outside the offered set is rejected',
  mergeWrite(alice, 'alice', { ...valid, pollInterval: 7 }), false);
await expectStatus('unknown lockTimeout is rejected',
  mergeWrite(alice, 'alice', { ...valid, lockTimeout: 42 }), false);
await expectStatus('unknown themeMode is rejected',
  mergeWrite(alice, 'alice', { ...valid, themeMode: 'neon' }), false);
await expectStatus('non-string locale is rejected',
  mergeWrite(alice, 'alice', { ...valid, locale: 7 }), false);
await expectStatus('unknown field is rejected',
  mergeWrite(alice, 'alice', { ...valid, accessToken: 'x' }), false);
await expectStatus('updatedAt that is not a timestamp is rejected',
  mergeWrite(alice, 'alice', { ...valid, updatedAt: 'yesterday' },
    { serverTimestamp: false }), false);

// A document written by an older client ("never" synced) stays writable.
await seed('carol', { themeMode: 'system', locale: null, lockTimeout: -1, pollInterval: 5 });
await expectStatus('merge onto an older client\'s document (lockTimeout -1)',
  mergeWrite(idToken('carol'), 'carol', { themeMode: 'dark', locale: null, pollInterval: 15 }),
  true);

// Sub-collections stay owner-only and do not unlock the settings document.
const sub = (auth, uid) => call('PATCH', `${api}/users/${uid}/devices/d1`, auth,
  { fields: fields({ any: 'thing' }) });
await expectStatus('owner may use a sub-collection', sub(alice, 'alice'), true);
await expectStatus('another user cannot use a sub-collection',
  sub(bob, 'alice'), false);

await expectStatus('another user cannot read', read(bob, 'alice'), false);
await expectStatus('another user cannot write',
  mergeWrite(bob, 'alice', valid), false);
await expectStatus('unauthenticated read is denied', read(null, 'alice'), false);
await expectStatus('unauthenticated write is denied',
  mergeWrite(null, 'alice', valid), false);
await expectStatus('another user cannot delete', remove(bob, 'alice'), false);
await expectStatus('owner can delete own document', remove(alice, 'alice'), true);

if (failures > 0) {
  console.error(`${failures} rules check(s) failed`);
  process.exit(1);
}
console.log('All firestore.rules checks passed');
