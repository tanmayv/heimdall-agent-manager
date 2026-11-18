// REQ-SWFIX-*: message-send / stale-context fixes after switching accounts.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_account_switch_fixes_test.ts

import './helpers/vaultEndpointHarness.ts';
import { makeVaultStore, unlockVault, clearActiveKey, installFetchCapture } from './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import { FakeHub, hubApi } from './helpers/vaultDirectoryFixture.ts';
import assert from 'node:assert/strict';

const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');
const session = await import('../src/ui/utils/vaultKeyringSession.ts');
const guard = await import('../src/ui/utils/vaultSendGuard.ts');
const expected = await import('../src/ui/utils/expectedUser.ts');
const { default: deviceVaultReducer, deviceVaultStatusChanged } = await import('../src/ui/store/deviceVaultSlice.ts');

function recorder() {
  const actions: Array<{ type: string; payload?: any }> = [];
  return { actions, dispatch: (a: any) => { actions.push(a); return a; } };
}

test('REQ-SWFIX-VAULT-1: a keyring install is refused after the session generation moved on', async () => {
  const before = session.keyringGeneration();
  session.clearKeyringSession();
  assert.ok(session.keyringGeneration() > before, 'a purge bumps the generation');
  await assert.rejects(
    session.installKeyringFromWrap({ userId: 'usr_a' } as any, {}, { userId: 'usr_a' } as any, before),
    /session changed/,
  );
  assert.equal(session.getKeyringSession(), null);
});

test('REQ-SWFIX-VAULT-1 (RC-1): a valid approved refresh for A suspended inside publishChain never installs A\'s keyring after the switch to B', async () => {
  const hub = new FakeHub('usr_a');
  const inner = ident.memoryDeviceStore();
  const root = await ident.createDeviceIdentity(inner, 'usr_a');
  await hub.genesis(root);
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  let armed = true;
  let suspended!: () => void;
  const reachedPublish = new Promise<void>((resolve) => { suspended = resolve; });
  // publishChain's first await is recordObservedReset -> kv.delete(observed reset key).
  const kv = {
    get: (k: string) => inner.get(k),
    put: (k: string, v: unknown) => inner.put(k, v),
    delete: async (k: string) => {
      if (armed && /observ/i.test(k)) { armed = false; suspended(); await gate; }
      return inner.delete(k);
    },
  };
  let dirCalls = 0;
  const api = hubApi(hub, { fetchVaultDirectory: async () => { dirCalls += 1; if (dirCalls > 1) throw new TypeError('offline (test)'); return hub.dir(); } });
  dv.configureDeviceVault({ kv: kv as any, bridges: null, pollIntervalMs: 1e9, api });
  dv.stopDeviceVault();
  const a = recorder();
  const bootA = dv.bootDeviceVault('usr_a', a.dispatch);
  await reachedPublish; // A's run is now suspended inside publishChain
  dv.stopDeviceVault(a.dispatch); // enterSwitching
  const b = recorder();
  await dv.bootDeviceVault('usr_b', b.dispatch);
  const aAfterStop = a.actions.length;
  release();
  await bootA;
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(a.actions.length, aAfterStop, 'A dispatched nothing after being stopped');
  assert.equal(session.getKeyringSession(), null, 'A\'s keyring was never installed');
  for (const rec of [a, b]) {
    assert.ok(!rec.actions.some((x) => x.type === 'vault/keyringInstalled'));
    assert.ok(!rec.actions.some((x) => x.payload?.status === 'ready'));
  }
  assert.ok(!b.actions.some((x) => x.type === 'deviceVault/deviceVaultDirectoryVerified'), 'A\'s directory never written into B');
  dv.stopDeviceVault();
});

test('REQ-SWFIX-VAULT-1: a stopped refresh suspended in the other-account check dispatches nothing to the next user', async () => {
  const kv0 = ident.memoryDeviceStore();
  await ident.advancePins(kv0, 'usr_previous', { root_device_id: 'dev_root', root_sign_pub: '04' + 'a1'.repeat(64), head_seq: 3, head_hash: 'ab'.repeat(32), max_epoch: 1 });
  let armed = false;
  let suspended!: () => void;
  const reached = new Promise<void>((resolve) => { suspended = resolve; });
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const kv = {
    get: async (k: string) => { if (armed) { armed = false; suspended(); await gate; } return kv0.get(k); },
    put: (k: string, v: unknown) => kv0.put(k, v),
    delete: (k: string) => kv0.delete(k),
  };
  let calls = 0;
  dv.configureDeviceVault({
    kv: kv as any, pollIntervalMs: 1e9,
    api: { fetchVaultDirectory: async () => { calls += 1; if (calls > 1) throw new TypeError('offline (test)'); armed = true; return null; } } as any,
  });
  dv.stopDeviceVault();
  const a = recorder();
  const bootA = dv.bootDeviceVault('usr_a', a.dispatch);
  await reached;
  dv.stopDeviceVault(a.dispatch);
  const b = recorder();
  await dv.bootDeviceVault('usr_b', b.dispatch);
  const aAfterStop = a.actions.length;
  const bAfterBoot = b.actions.length;
  release();
  await bootA;
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(a.actions.length, aAfterStop);
  assert.equal(b.actions.length, bAfterBoot);
  assert.ok(![...a.actions, ...b.actions].some((x) => x.payload?.status === 'other-account'));
  dv.stopDeviceVault();
});

test('REQ-SWFIX-VAULT-3: stopDeviceVault clears the pending hint-revocation timer', async () => {
  const kv = ident.memoryDeviceStore();
  const identity = await ident.createDeviceIdentity(kv, 'usr_a');
  dv.configureDeviceVault({ kv, api: { fetchVaultDirectory: async () => { throw new TypeError('offline (test)'); } } as any });
  dv.stopDeviceVault();
  await dv.bootDeviceVault('usr_a', recorder().dispatch);
  dv.scheduleHintRevocation({ trusted: new Map([[identity.deviceId, { kind: 'browser' }]]), retiredHints: [] } as any);
  assert.equal(dv.hintRevocationTimerArmed(), true);
  dv.stopDeviceVault();
  assert.equal(dv.hintRevocationTimerArmed(), false);
});

test('REQ-SWFIX-VAULT-3: fetchVerifiedChain after stop throws a plain error, not a TypeError', async () => {
  dv.stopDeviceVault();
  await assert.rejects(dv.fetchVerifiedChain(), (err: any) => !(err instanceof TypeError) && /not started/.test(err.message));
});

test('REQ-SWFIX-VAULT-4: booting the running user does not rebuild the context', async () => {
  const kv = ident.memoryDeviceStore();
  dv.configureDeviceVault({ kv, api: { fetchVaultDirectory: async () => { throw new TypeError('offline (test)'); } } as any });
  dv.stopDeviceVault();
  const rec = recorder();
  await dv.bootDeviceVault('usr_a', rec.dispatch);
  await dv.bootDeviceVault('usr_a', rec.dispatch);
  const initializing = rec.actions.filter((x) => x.payload?.status === 'initializing');
  assert.equal(initializing.length, 1, 'no status flicker to initializing on a same-user boot');
  dv.stopDeviceVault();
});

test('REQ-SWFIX-SEND-1: guard table', () => {
  const key = { userId: 'usr_a' };
  // Foreign key never encrypts for B.
  assert.equal(guard.vaultSendBlock({ activeKey: key, isUnlocked: true, currentUserId: 'usr_b' })?.code, 'vault_foreign_key');
  // Own key, ready: proceed.
  assert.equal(guard.vaultSendBlock({ activeKey: key, isUnlocked: true, currentUserId: 'usr_a', deviceVault: { status: 'ready' } }), null);
  // Not ready (initializing after a switch): blocked, no plaintext fallback.
  assert.equal(guard.vaultSendBlock({ activeKey: null, isUnlocked: false, currentUserId: 'usr_b', deviceVault: { status: 'initializing' } })?.code, 'vault_unlocking');
  assert.match(guard.VAULT_UNLOCKING_MESSAGE, /Vault unlocking/);
  // No vault expected: unchanged behaviour.
  assert.equal(guard.vaultSendBlock({ activeKey: null, isUnlocked: false, currentUserId: 'usr_b', deviceVault: { status: 'unsupported' } }), null);
  assert.equal(guard.vaultSendBlock({ activeKey: null, isUnlocked: false, currentUserId: 'usr_b' }), null);
});

test('REQ-SWFIX-SEND-1: sendConversationMessage never reaches the wire when blocked', async () => {
  const capture = installFetchCapture();
  const store = await makeVaultStore({ extraReducers: { deviceVault: deviceVaultReducer } });
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  await import('../src/ui/api/endpoints/chats.ts');
  const send = (body: string) => store.dispatch((heimdallApi.endpoints as any).sendConversationMessage.initiate({ conversationId: 'c1', body }));
  try {
    // A's key is installed while this context is B.
    await unlockVault(store, 'ab'.repeat(32));
    store.dispatch(deviceVaultStatusChanged({ status: 'ready', userId: 'usr_b' }));
    const foreignId = (await import('../src/ui/utils/vaultCrypto.ts')).getActiveVaultKey()!.userId;
    expected.setExpectedUserId(foreignId + '-other');
    let result = await send('hello');
    assert.match(String(result.error?.error), /another account/);
    assert.equal(capture.requests.filter((r) => /messages/.test(r.url)).length, 0);

    // B's vault is initializing: no key, no plaintext fallback.
    await clearActiveKey();
    store.dispatch(deviceVaultStatusChanged({ status: 'initializing', userId: 'usr_b' }));
    result = await send('hello');
    assert.match(String(result.error?.error), /Vault unlocking/);
    assert.equal(result.error?.code, 'vault_unlocking');
    assert.equal(capture.requests.filter((r) => /messages/.test(r.url)).length, 0);
  } finally {
    expected.setExpectedUserId('');
    await clearActiveKey();
  }
});

test('REQ-SWFIX-STALE-1: account_mismatch detection and header exemptions', async () => {
  const mismatch = new Response(JSON.stringify({ error: { code: 'account_mismatch', message: 'x' } }), { status: 409 });
  assert.equal(await expected.isAccountMismatchResponse(mismatch), true);
  assert.equal(await mismatch.json().then((b: any) => b.error.code), 'account_mismatch', 'body still readable');
  assert.equal(await expected.isAccountMismatchResponse(new Response(JSON.stringify({ error: { code: 'conflict' } }), { status: 409 })), false);
  assert.equal(await expected.isAccountMismatchResponse(new Response('{}', { status: 403 })), false);
  assert.equal(expected.isAccountNeutralPath('/api/v1/me'), true);
  assert.equal(expected.isAccountNeutralPath('/api/v1/auth/switch'), true);
  assert.equal(expected.isAccountNeutralPath('/api/v1/chats'), false);
  expected.setExpectedUserId(' usr_a ');
  assert.equal(expected.getExpectedUserId(), 'usr_a');
  expected.setExpectedUserId(null);
  assert.equal(expected.getExpectedUserId(), '');
});
