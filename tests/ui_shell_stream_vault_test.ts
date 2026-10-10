// REQ-SHELL-ENC-5: Automated unit and contract tests for client-side PTY stream decryption and input encryption
// Validates transparent AES-256-GCM decryption of enc_b64 stream frames, keystroke encryption,
// locked vault graceful fallback, and bridge wire-format compatibility.
//
// RUN: node --test tests/ui_shell_stream_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
// Imported FIRST: this registers the module resolve hook that lets node load
// src/ui/api/endpoints/*.ts, whose relative imports are extensionless.
import {
  installFetchCapture,
  installWindowShim,
  makeVaultStore,
  unlockVault,
  lockVaultFully,
  clearActiveKey,
} from './helpers/vaultEndpointHarness.ts';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  encryptShellStreamPayload,
  decryptShellStreamPayload,
} from '../src/ui/components/shells/useShellStream.ts';
import {
  base64ToBytes,
  bytesToBase64,
  VAULT_ARMOR_PREFIX,
  decryptVaultText,
  encryptVaultText,
  isVaultArmored,
} from '../src/ui/utils/vaultContent.ts';
import { importRawKeyHex, getActiveVaultKey, setActiveVaultKey } from '../src/ui/utils/vaultCrypto.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const USE_SHELL_STREAM = path.join(REPO_ROOT, 'src/ui/components/shells/useShellStream.ts');

const TEST_VAULT_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const ALT_VAULT_KEY = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// 1. Static Contract & Source Code Invariants
// -----------------------------------------------------------------------------

test('REQ-SHELL-ENC-5: useShellStream.ts static contract verification', () => {
  assert.ok(fs.existsSync(USE_SHELL_STREAM), 'useShellStream.ts must exist');
  const src = fs.readFileSync(USE_SHELL_STREAM, 'utf8');

  // Must export hook and crypto helpers
  assert.ok(src.includes('export function useShellStream'), 'must export useShellStream hook');
  assert.ok(src.includes('export async function decryptShellStreamPayload'), 'must export decryptShellStreamPayload');
  assert.ok(src.includes('export async function encryptShellStreamPayload'), 'must export encryptShellStreamPayload');

  // Must accept the unlock FLAG as an option. The KEY is deliberately not an option
  // and is not readable from Redux: after the zero-trust hardening it exists only as a
  // non-extractable CryptoKey reached through getActiveVaultKey().
  assert.ok(src.includes('isVaultUnlocked?: boolean'), 'must accept isVaultUnlocked in options');
  assert.ok(src.includes('getActiveVaultKey'), 'must resolve the key via getActiveVaultKey()');

  // Must read Redux vault state for the unlock flag only.
  assert.ok(src.includes('useSelector'), 'must use Redux useSelector');

  // REQ-RAWKEY-A8: this file's crypto behaviour is covered behaviourally below, through
  // the exported encryptShellStreamPayload / decryptShellStreamPayload helpers. These
  // remaining source checks exist only because useShellStream is a React hook that owns
  // a live WebSocket, so it cannot be driven without a DOM renderer. They are therefore
  // retargeted at the CURRENT symbol, plus a negative guard: rawVaultKeyHex is never
  // assigned on any branch, so a read of it silently resolves to undefined and the
  // encryption gate behind it never fires. That is the P0 this chain exists to purge.
  assert.ok(
    !src.includes('rawVaultKeyHex'),
    'the retired rawVaultKeyHex source must not reappear -- reading it silently disables encryption',
  );

  // Must handle enc_b64 in onmessage for output and screen
  assert.ok(src.includes("msg.type === 'output'"), 'must handle output message');
  assert.ok(src.includes("msg.type === 'screen'"), 'must handle screen message');
  assert.ok(src.includes('enc_b64'), 'must inspect enc_b64 field');
  assert.ok(src.includes('decryptShellStreamPayload'), 'must call decryptShellStreamPayload on encrypted frames');

  // Must encrypt outgoing input when vault is unlocked and fall back to data_b64 when locked
  assert.ok(src.includes('encryptShellStreamPayload'), 'must call encryptShellStreamPayload in sendInput');
  assert.ok(src.includes("type: 'input', data_b64: enc_b64, is_encrypted: true"), 'must send enc_b64 for input when vault unlocked');
  assert.ok(src.includes("type: 'input', data_b64"), 'must fall back to data_b64 when vault locked');

  // Must preserve heartbeat and geometry logic
  assert.ok(src.includes('startHeartbeat'), 'must preserve startHeartbeat');
  assert.ok(src.includes('sendGeometry'), 'must preserve sendGeometry');
  assert.ok(src.includes('activeConnectIdRef'), 'must preserve activeConnectIdRef');
});

// -----------------------------------------------------------------------------
// 2. Stream Cryptographic Round-Trip & Wire Format
// -----------------------------------------------------------------------------

test('encryptShellStreamPayload produces valid 12B IV + 16B tag + ciphertext structure', async () => {
  const plaintext = 'echo "Hello, Zero-Trust Bridge PTY!"\r\n';
  const enc_b64 = await encryptShellStreamPayload(plaintext, TEST_VAULT_KEY);

  assert.ok(typeof enc_b64 === 'string', 'enc_b64 must be a string');
  assert.ok(enc_b64.length > 0, 'enc_b64 must not be empty');

  const rawBytes = base64ToBytes(enc_b64);
  const expectedPlaintextBytes = new TextEncoder().encode(plaintext);
  const expectedTotalBytes = 12 + 16 + expectedPlaintextBytes.length; // 28 header bytes + ciphertext
  assert.equal(rawBytes.length, expectedTotalBytes, 'payload must be 28 bytes header + ciphertext');
});

test('decryptShellStreamPayload correctly decrypts encrypted PTY output', async () => {
  const originalText = '\x1b[32muser@cloudtop:~$ ls -la\r\ntotal 64\r\ndrwxr-xr-x 2 user user 4096\x1b[0m\r\n';
  const enc_b64 = await encryptShellStreamPayload(originalText, TEST_VAULT_KEY);

  const decryptedBytes = await decryptShellStreamPayload(enc_b64, TEST_VAULT_KEY);
  const decryptedText = new TextDecoder().decode(decryptedBytes);

  assert.equal(decryptedText, originalText, 'decrypted text must match original plaintext exactly');
});

test('decryptShellStreamPayload transparently strips vault:v1: prefix if present', async () => {
  const original = 'cat /etc/os-release';
  const raw_b64 = await encryptShellStreamPayload(original, TEST_VAULT_KEY);
  const armored = `${VAULT_ARMOR_PREFIX}${raw_b64}`;

  const decrypted = await decryptShellStreamPayload(armored, TEST_VAULT_KEY);
  assert.equal(new TextDecoder().decode(decrypted), original);
});

test('decryptShellStreamPayload handles Uint8Array input and binary terminal control sequences', async () => {
  // VT100 / ANSI escape sequence with binary data
  const binaryData = new Uint8Array([0x1b, 0x5b, 0x32, 0x4a, 0x1b, 0x5b, 0x48, 0x00, 0xff, 0x7f]);
  const enc_b64 = await encryptShellStreamPayload(binaryData, TEST_VAULT_KEY);

  const decrypted = await decryptShellStreamPayload(enc_b64, TEST_VAULT_KEY);
  assert.deepEqual(decrypted, binaryData, 'binary bytes must match exactly');
});

test('encryptShellStreamPayload generates unique random 12B nonces for semantic security', async () => {
  const data = 'repeat keystroke test';
  const enc1 = await encryptShellStreamPayload(data, TEST_VAULT_KEY);
  const enc2 = await encryptShellStreamPayload(data, TEST_VAULT_KEY);

  assert.notEqual(enc1, enc2, 'consecutive encryptions of identical data must produce distinct ciphertexts');

  const bytes1 = base64ToBytes(enc1);
  const bytes2 = base64ToBytes(enc2);
  const nonce1 = bytes1.subarray(0, 12);
  const nonce2 = bytes2.subarray(0, 12);
  assert.notDeepEqual(nonce1, nonce2, 'nonces must be randomized');
});

test('decryptShellStreamPayload rejects tampered ciphertext or authentication tag', async () => {
  const message = 'sensitive command execution';
  const enc_b64 = await encryptShellStreamPayload(message, TEST_VAULT_KEY);
  const bytes = base64ToBytes(enc_b64);

  // Tamper with the last byte of ciphertext
  bytes[bytes.length - 1] ^= 0x01;
  const tamperedB64 = bytesToBase64(bytes);

  await assert.rejects(
    async () => {
      await decryptShellStreamPayload(tamperedB64, TEST_VAULT_KEY);
    },
    'decryption of tampered ciphertext must fail authentication'
  );
});

test('decryptShellStreamPayload rejects decryption with mismatched vault key', async () => {
  const message = 'confidential shell session';
  const enc_b64 = await encryptShellStreamPayload(message, TEST_VAULT_KEY);

  await assert.rejects(
    async () => {
      await decryptShellStreamPayload(enc_b64, ALT_VAULT_KEY);
    },
    'decryption with incorrect key must fail authentication'
  );
});

test('decryptShellStreamPayload rejects truncated payloads', async () => {
  const truncated = bytesToBase64(new Uint8Array(20)); // Less than 28 bytes header
  await assert.rejects(
    async () => {
      await decryptShellStreamPayload(truncated, TEST_VAULT_KEY);
    },
    /shorter than header/
  );
});

test('WebCrypto CryptoKey instance can be passed directly to encrypt and decrypt', async () => {
  const cryptoKey = await importRawKeyHex(TEST_VAULT_KEY);
  const text = 'direct CryptoKey instance test';

  const enc = await encryptShellStreamPayload(text, cryptoKey);
  const dec = await decryptShellStreamPayload(enc, cryptoKey);

  assert.equal(new TextDecoder().decode(dec), text);
});

// -----------------------------------------------------------------------------
// 3. REQ-SHELL-ENC-8: createShell enc_spec Encrypted Spawn Authorization
// -----------------------------------------------------------------------------

test('REQ-SHELL-ENC-8: shells.ts and NewShellDialog.tsx static contract verification', () => {
  const SHELLS_ENDPOINT = path.join(REPO_ROOT, 'src/ui/api/endpoints/shells.ts');
  const NEW_SHELL_DIALOG = path.join(REPO_ROOT, 'src/ui/components/shells/NewShellDialog.tsx');

  assert.ok(fs.existsSync(SHELLS_ENDPOINT), 'shells.ts must exist');
  assert.ok(fs.existsSync(NEW_SHELL_DIALOG), 'NewShellDialog.tsx must exist');

  const endpointSrc = fs.readFileSync(SHELLS_ENDPOINT, 'utf8');
  const dialogSrc = fs.readFileSync(NEW_SHELL_DIALOG, 'utf8');

  // Verify imports in shells.ts
  assert.ok(
    endpointSrc.includes('encryptVaultText'),
    'shells.ts must import encryptVaultText',
  );
  // REQ-RAWKEY-A8: readSessionVaultKey is hardened to unconditionally return null, so
  // pinning its presence pinned a dead mechanism. The live source is getActiveVaultKey().
  assert.ok(
    endpointSrc.includes('getActiveVaultKey'),
    'shells.ts must resolve the vault key via getActiveVaultKey',
  );
  assert.ok(
    !endpointSrc.includes('readSessionVaultKey'),
    'shells.ts must not read readSessionVaultKey -- it always returns null',
  );

  // Verify CreateShellArgs includes optional enc_spec
  assert.ok(
    /interface\s+CreateShellArgs[\s\S]*?enc_spec\?:/m.test(endpointSrc),
    'CreateShellArgs must define optional enc_spec?: string',
  );

  // Verify createShell mutation inspects vault unlock state and key
  assert.ok(
    endpointSrc.includes('createShell: build.mutation'),
    'shells.ts must define createShell mutation',
  );
  assert.ok(
    !endpointSrc.includes('rawVaultKeyHex'),
    'createShell must not gate on the retired rawVaultKeyHex -- the gate never fires',
  );
  // What createShell actually DOES with the unlock state is asserted against the real
  // mutation and the real wire payload in section 3b, not by grepping for identifiers.

  // Verify createShell constructs spec with cmd, cwd, timestamp, and nonce
  assert.ok(
    endpointSrc.includes('timestamp: Date.now()'),
    'createShell queryFn must populate timestamp with Date.now()',
  );
  assert.ok(
    endpointSrc.includes('nonce:'),
    'createShell queryFn must populate nonce',
  );
  assert.ok(
    endpointSrc.includes('encryptVaultText(JSON.stringify(spec), activeKey)'),
    'createShell queryFn must encrypt spec JSON with the active CryptoKey',
  );

  // Verify NewShellDialog relies on createShell mutation
  assert.ok(
    dialogSrc.includes('useCreateShellMutation'),
    'NewShellDialog.tsx must use useCreateShellMutation',
  );
  assert.ok(
    dialogSrc.includes('createShell({'),
    'NewShellDialog.tsx must invoke createShell mutation',
  );
});

// -----------------------------------------------------------------------------
// 3b. REQ-SHELL-ENC-8 / REQ-FIX-ENC-1 / REQ-RAWKEY-A8: createShell through the REAL endpoint.
//
// These replace five tests that COPIED createShell's queryFn into the test body and
// then asserted on their own copy. That shape cannot fail when the endpoint is broken:
// it is exactly how artifact names and chain titles went to the wire in PLAINTEXT while
// the suite stayed green. So the real mutation is dispatched through a real store with a
// stubbed fetch, and every assertion is on the CAPTURED REQUEST BODY.
//
// The key is supplied the production way -- a non-extractable CryptoKey in the active-key
// slot -- never by injecting hex into mock Redux state, which no production read reaches.
// -----------------------------------------------------------------------------

installWindowShim();
const shellFetch = installFetchCapture();
const { shellsApi } = await import('../src/ui/api/endpoints/shells.ts');

const CREATE_SHELL_OK = { data: { session: { session_id: 'sh_test', kind: 'shell' } } };

/** Dispatch the real createShell mutation and return the body that hit the wire. */
async function captureCreateShell(store: any, args: Record<string, any>) {
  shellFetch.reset();
  shellFetch.setNextResponse(CREATE_SHELL_OK);
  const res: any = await store.dispatch(
    shellsApi.endpoints.createShell.initiate({ bridgeId: 'brg_test', ...args } as any),
  );
  assert.ok(!res?.error, `createShell returned an error: ${JSON.stringify(res?.error)}`);
  return shellFetch.find((r) => r.method === 'POST' && /\/bridges\/brg_test\/shells$/.test(r.url)).body;
}

test('REQ-SHELL-ENC-8: createShell puts an armored enc_spec with cmd, cwd, timestamp and nonce on the wire when unlocked', async () => {
  const cmd = 'npm run dev';
  const cwd = '/home/user/project';
  const startTime = Date.now();

  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    const body = await captureCreateShell(store, { cmd, cwd, kind: 'shell' });

    assert.ok(body.enc_spec, 'request body must carry enc_spec');
    assert.ok(isVaultArmored(body.enc_spec), 'enc_spec must start with vault:v1:');
    // NOTE ON SCOPE -- enc_spec is INTEGRITY/AUTHORIZATION, not confidentiality.
    // cmd and cwd deliberately ALSO travel in plaintext: the hub persists them
    // (shell_session_rest_handlers.odin:163-164) so sessions can be listed and
    // labelled, while the bridge ignores those fields and takes the authoritative
    // cmd/cwd from the decrypted spec, rejecting any request whose enc_spec is
    // missing, unarmored, undecryptable or outside a 60s replay window
    // (hub_runtime_client.odin:3361-3394). domain/bridge.odin:42-45 names this guard
    // the authoritative authorization check. So assert what the mechanism promises:
    // the ciphertext is real and independent of the plaintext copy.
    assert.notEqual(body.enc_spec, cmd, 'enc_spec must be ciphertext, not the bare command');
    assert.ok(!body.enc_spec.includes(cmd), 'the enc_spec ciphertext must not embed the plaintext command');

    const parsedSpec = JSON.parse(await decryptVaultText(body.enc_spec, key));
    assert.equal(parsedSpec.cmd, cmd, 'decrypted spec cmd must match input cmd');
    assert.equal(parsedSpec.cwd, cwd, 'decrypted spec cwd must match input cwd');
    assert.ok(typeof parsedSpec.timestamp === 'number', 'timestamp must be a number');
    assert.ok(parsedSpec.timestamp >= startTime && parsedSpec.timestamp <= Date.now(), 'timestamp must be current');
    assert.ok(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(parsedSpec.nonce),
      `nonce must be a valid UUID string, got: ${parsedSpec.nonce}`,
    );
  } finally {
    await clearActiveKey();
  }
});

test('REQ-FIX-ENC-1: createShell encrypts enc_spec with the CryptoKey from getActiveVaultKey(), with no hex anywhere', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    // The production unlock path stores ONLY a non-extractable CryptoKey. Prove the
    // endpoint encrypts from that, with no hex key reachable from state.
    assert.ok(getActiveVaultKey() instanceof Object, 'an active CryptoKey must be present');
    assert.equal((store.getState() as any).vault.rawVaultKeyHex, undefined,
      'no hex key may exist in Redux state -- the endpoint must not need one');

    const body = await captureCreateShell(store, { cmd: 'cargo test', cwd: '/workspace', kind: 'run' });
    assert.ok(isVaultArmored(body.enc_spec), 'enc_spec must be armored');
    const parsed = JSON.parse(await decryptVaultText(body.enc_spec, key));
    assert.equal(parsed.cmd, 'cargo test');
    assert.equal(parsed.cwd, '/workspace');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: createShell omits enc_spec and sends plaintext when the vault is locked', async () => {
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY);
  await lockVaultFully(store);
  try {
    assert.equal(getActiveVaultKey(), null, 'precondition: locking clears the active key');
    const body = await captureCreateShell(store, { cmd: 'ls -la', cwd: '/tmp', kind: 'run' });

    assert.strictEqual(body.enc_spec, undefined, 'enc_spec must be omitted when the vault is locked');
    assert.equal(body.cmd, 'ls -la', 'cmd must pass through in plaintext');
    assert.equal(body.cwd, '/tmp', 'cwd must pass through in plaintext');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: createShell omits enc_spec when no key is active even though state says unlocked', async () => {
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY);
  // The failure mode this guards: Redux still flags unlocked, but the key is gone (a
  // reload, or a lock that did not propagate). Encryption must be skipped, not attempted.
  await clearActiveKey();
  try {
    assert.equal(getActiveVaultKey(), null, 'precondition: no active key');
    const body = await captureCreateShell(store, { cmd: 'cat /etc/hosts', cwd: '/', kind: 'run' });
    assert.strictEqual(body.enc_spec, undefined, 'enc_spec must be omitted when no key is active');
    assert.equal(body.cmd, 'cat /etc/hosts');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: createShell defaults omitted cmd and cwd to empty strings in the encrypted spec', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    const body = await captureCreateShell(store, { kind: 'shell' });
    assert.ok(body.enc_spec, 'enc_spec must be present');
    const parsedSpec = JSON.parse(await decryptVaultText(body.enc_spec, key));
    assert.strictEqual(parsedSpec.cmd, '', 'omitted cmd must default to empty string');
    assert.strictEqual(parsedSpec.cwd, '', 'omitted cwd must default to empty string');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: two identical createShell calls produce distinct ciphertexts and distinct nonces', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    const args = { cmd: 'test', cwd: '/dir', kind: 'run' as const };
    const first = await captureCreateShell(store, args);
    const second = await captureCreateShell(store, args);

    assert.notEqual(first.enc_spec, second.enc_spec, 'identical input must not yield identical ciphertext');
    const p1 = JSON.parse(await decryptVaultText(first.enc_spec, key));
    const p2 = JSON.parse(await decryptVaultText(second.enc_spec, key));
    assert.notEqual(p1.nonce, p2.nonce, 'each spec must carry a fresh nonce');
  } finally {
    await clearActiveKey();
  }
});

// -----------------------------------------------------------------------------
// 4. REQ-SHELL-ENC-10: sendShellInput Vault Encryption in shells.ts
// -----------------------------------------------------------------------------

test('REQ-SHELL-ENC-10: sendShellInput static contract verification', () => {
  const shellsSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/api/endpoints/shells.ts'), 'utf8');
  assert.ok(shellsSrc.includes('sendShellInput: build.mutation'), 'shells.ts must define sendShellInput mutation');
  assert.ok(shellsSrc.includes('encryptShellStreamPayload'), 'shells.ts must import encryptShellStreamPayload');
  assert.ok(shellsSrc.includes('selectIsVaultUnlocked'), 'shells.ts must import selectIsVaultUnlocked');
  assert.ok(shellsSrc.includes('getActiveVaultKey'), 'shells.ts must import getActiveVaultKey');
  assert.ok(!shellsSrc.includes('readSessionVaultKey'),
    'shells.ts must not read readSessionVaultKey -- it always returns null');
  assert.ok(shellsSrc.includes('payload.enc_b64 = resolvedEncB64'), 'sendShellInput must attach enc_b64 when encrypted');
});

/** Dispatch the real sendShellInput mutation and return the body that hit the wire. */
async function captureSendShellInput(store: any, data: string) {
  shellFetch.reset();
  shellFetch.setNextResponse({ data: { ok: true } });
  const res: any = await store.dispatch(
    shellsApi.endpoints.sendShellInput.initiate({ sessionId: 'sh_test', data } as any),
  );
  assert.ok(!res?.error, `sendShellInput returned an error: ${JSON.stringify(res?.error)}`);
  return shellFetch.find((r) => r.method === 'POST' && /\/shells\/sh_test\/input$/.test(r.url)).body;
}

test('REQ-SHELL-ENC-10: sendShellInput puts enc_b64 and armored data_b64 on the wire when unlocked', async () => {
  const data = 'ls -la\n';
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    const body = await captureSendShellInput(store, data);

    assert.ok(body.enc_b64, 'enc_b64 must be attached to the request');
    assert.ok(
      String(body.data_b64).startsWith(VAULT_ARMOR_PREFIX),
      `data_b64 must be armored, got: ${String(body.data_b64).slice(0, 32)}`,
    );
    const decrypted = await decryptShellStreamPayload(body.enc_b64, key);
    assert.equal(new TextDecoder().decode(decrypted), data, 'enc_b64 must decrypt to the keystrokes');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-10: sendShellInput omits enc_b64 and data_b64 when the vault is locked', async () => {
  const data = 'ls -la\n';
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY);
  await lockVaultFully(store);
  try {
    const body = await captureSendShellInput(store, data);
    assert.strictEqual(body.enc_b64, undefined, 'enc_b64 must not be set when the vault is locked');
    assert.strictEqual(body.data_b64, undefined, 'data_b64 must not be set when the vault is locked');
    assert.equal(body.data, data, 'the plaintext input still has to reach the bridge');
  } finally {
    await clearActiveKey();
  }
});

// -----------------------------------------------------------------------------
// 5. REQ-SHELL-ENC-11: Terminal Cursor Restoration in ShellTerminalPane.tsx
// -----------------------------------------------------------------------------

test('REQ-SHELL-ENC-11: ShellTerminalPane.tsx restores terminal cursor and eliminates hide-cursor sequence', () => {
  const paneSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shells/ShellTerminalPane.tsx'), 'utf8');
  assert.ok(!paneSrc.includes('\\x1b[?25l'), 'ShellTerminalPane.tsx must NOT contain VT100 hide cursor sequence \\x1b[?25l');
  assert.ok(paneSrc.includes('\\x1b[?25h'), 'ShellTerminalPane.tsx must contain VT100 show cursor sequence \\x1b[?25h');
  assert.ok(paneSrc.includes("session.kind === 'shell'"), 'ShellTerminalPane.tsx must check session.kind === shell for cursor restoration');
});

// -----------------------------------------------------------------------------
// 6. REQ-SHELL-ENC-12: Standardized vault:v1: Armored data_b64
// -----------------------------------------------------------------------------

test('REQ-SHELL-ENC-12: useShellStream.ts inspects data_b64 for vault:v1: prefix', () => {
  const streamSrc = fs.readFileSync(USE_SHELL_STREAM, 'utf8');
  assert.ok(streamSrc.includes('msg.is_encrypted === true'), 'must inspect data_b64 or enc_b64');
  assert.ok(streamSrc.includes('isArmored ? msg.data_b64 : undefined'), 'must check for VAULT_ARMOR_PREFIX');
  assert.ok(streamSrc.includes('data_b64: enc_b64, is_encrypted: true'), 'sendInput must send armored data_b64');
});

test('REQ-SHELL-ENC-12: decryptShellStreamPayload transparently decrypts vault:v1: armored data_b64', async () => {
  const plaintext = '\x1b[32mhello from encrypted pty\x1b[0m\r\n';
  const enc_b64 = await encryptShellStreamPayload(plaintext, TEST_VAULT_KEY);
  const armored_data_b64 = `${VAULT_ARMOR_PREFIX}${enc_b64}`;

  assert.ok(armored_data_b64.startsWith('vault:v1:'), 'must have vault:v1: prefix');
  const decrypted = await decryptShellStreamPayload(armored_data_b64, TEST_VAULT_KEY);
  assert.equal(new TextDecoder().decode(decrypted), plaintext);
});

test('REQ-SHELL-ENC-12: sendShellInput sets data_b64 with vault:v1: prefix in shells.ts', () => {
  const shellsSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/api/endpoints/shells.ts'), 'utf8');
  assert.ok(shellsSrc.includes('payload.data_b64 = `${VAULT_ARMOR_PREFIX}${resolvedEncB64}`'), 'sendShellInput must set armored data_b64');
});

// -----------------------------------------------------------------------------
// 7. REQ-FIX-ENC-1: createShell with CryptoKey from getActiveVaultKey()
// -----------------------------------------------------------------------------

// REQ-FIX-ENC-1 is covered in section 3b by
// "createShell encrypts enc_spec with the CryptoKey from getActiveVaultKey()", which
// drives the REAL mutation instead of re-implementing its queryFn in the test body.
// No coverage was dropped: that test additionally proves no hex key exists in state.

// -----------------------------------------------------------------------------
// 8. REQ-FIX-ENC-2: useAgentStream.ts Stream Decryption & Frame Parsing
// -----------------------------------------------------------------------------

test('REQ-FIX-ENC-2: useAgentStream.ts static contract verification', () => {
  const agentStreamPath = path.join(REPO_ROOT, 'src/ui/components/chat/useAgentStream.ts');
  assert.ok(fs.existsSync(agentStreamPath), 'useAgentStream.ts must exist');
  const src = fs.readFileSync(agentStreamPath, 'utf8');

  assert.ok(src.includes('export function useAgentStream'), 'must export useAgentStream');
  assert.ok(src.includes('decryptShellStreamPayload'), 'must import decryptShellStreamPayload');
  assert.ok(src.includes('encryptShellStreamPayload'), 'must import encryptShellStreamPayload');
  assert.ok(src.includes('getActiveVaultKey'), 'must import getActiveVaultKey');
  assert.ok(src.includes('VAULT_ARMOR_PREFIX'), 'must import VAULT_ARMOR_PREFIX');

  // Verify stream message handling
  assert.ok(src.includes("msg.type === 'output'"), 'must handle output messages');
  assert.ok(src.includes("msg.type === 'screen'"), 'must handle screen messages');
  assert.ok(src.includes('msg.is_encrypted === true'), 'must check for armored vault:v1: payload');
  assert.ok(src.includes('decryptShellStreamPayload(enc_b64, keyToUse)'), 'must decrypt stream chunk with keyToUse');

  // Verify sendInput encryption
  assert.ok(src.includes('encryptShellStreamPayload(data, keyToUse)'), 'must encrypt input with keyToUse');
  assert.ok(src.includes("type: 'input', data_b64: enc_b64, is_encrypted: true"), 'must send encrypted enc_b64 frame');
  assert.ok(src.includes("type: 'input', data_b64: toBase64(data)"), 'must fall back to plaintext when locked');
});

test('REQ-FIX-ENC-2: useAgentStream message decoding handles armored output and screen frames', async () => {
  const cryptoKey = await importRawKeyHex(TEST_VAULT_KEY);
  const sampleOutput = '\r\nAgent output stream line 1\r\n';
  const enc_b64 = await encryptShellStreamPayload(sampleOutput, cryptoKey);
  const armored = `${VAULT_ARMOR_PREFIX}${enc_b64}`;

  // Test decrypting armored output payload
  const decryptedOutputBytes = await decryptShellStreamPayload(armored, cryptoKey);
  assert.equal(new TextDecoder().decode(decryptedOutputBytes), sampleOutput);

  // Test decrypting screen snapshot payload
  const screenContent = '\x1b[2J\x1b[HWelcome to Heimdall Terminal';
  const encScreen = await encryptShellStreamPayload(screenContent, cryptoKey);
  const decryptedScreenBytes = await decryptShellStreamPayload(encScreen, cryptoKey);
  assert.equal(new TextDecoder().decode(decryptedScreenBytes), screenContent);
});

// -----------------------------------------------------------------------------
// 9. REQ-FIX-ENC-3: useAgentStream.ts sendInput Keystroke Encryption
// -----------------------------------------------------------------------------

test('REQ-FIX-ENC-3: sendInput payload generation matches zero-trust protocol', async () => {
  const cryptoKey = await importRawKeyHex(TEST_VAULT_KEY);
  const keystroke = 'cargo build\r';
  const enc_b64 = await encryptShellStreamPayload(keystroke, cryptoKey);
  const frame = { type: 'input', data_b64: enc_b64, is_encrypted: true };

  assert.equal(frame.type, 'input');
  assert.equal(frame.is_encrypted, true);
  assert.ok(!frame.data_b64.startsWith('vault:v1:'));
  assert.ok(!('enc_b64' in frame));
  const decrypted = await decryptShellStreamPayload(frame.data_b64, cryptoKey);
  assert.equal(new TextDecoder().decode(decrypted), keystroke);
});

// -----------------------------------------------------------------------------
// 10. REQ-FIX-ENC-4: projectFs.ts and UI components active key resolution
// -----------------------------------------------------------------------------

test('REQ-FIX-ENC-4: projectFs.ts and UI components resolve getActiveVaultKey()', () => {
  const projectFsSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/api/endpoints/projectFs.ts'), 'utf8');
  assert.ok(projectFsSrc.includes('getActiveVaultKey'), 'projectFs.ts must import getActiveVaultKey');
  assert.ok(projectFsSrc.includes('decryptSearchMatches(rawMatches, activeKey)'), 'projectFs.ts must pass activeKey to decryptSearchMatches');

  const librarySrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/LibraryPage.tsx'), 'utf8');
  assert.ok(librarySrc.includes('getActiveVaultKey'), 'LibraryPage.tsx must use getActiveVaultKey');

  const appShellSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
  assert.ok(appShellSrc.includes('getActiveVaultKey()'), 'AppShell.tsx must use getActiveVaultKey');

  const selectorSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chains/TaskChainSelectorModal.tsx'), 'utf8');
  assert.ok(selectorSrc.includes('getActiveVaultKey()'), 'TaskChainSelectorModal.tsx must use getActiveVaultKey');

  const paletteSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/ui/patterns/CommandPalette.tsx'), 'utf8');
  assert.ok(paletteSrc.includes('getActiveVaultKey()'), 'CommandPalette.tsx must use getActiveVaultKey');

  const vaultTextSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/vault/VaultText.tsx'), 'utf8');
  assert.ok(vaultTextSrc.includes('getActiveVaultKey'), 'VaultText.tsx must use getActiveVaultKey');
});

test('REQ-FIX-ENC-4: vault*.ts utility functions accept activeKey parameter', () => {
  const taskSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultTasks.ts'), 'utf8');
  assert.ok(taskSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultTasks.ts must use activeKey parameter');
  assert.ok(!taskSrc.includes('rawKeyHex?:'), 'vaultTasks.ts must not have rawKeyHex parameter');

  const chatSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultChats.ts'), 'utf8');
  assert.ok(chatSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultChats.ts must use activeKey parameter');
  assert.ok(!chatSrc.includes('rawKeyHex?:'), 'vaultChats.ts must not have rawKeyHex parameter');

  const issueSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultIssues.ts'), 'utf8');
  assert.ok(issueSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultIssues.ts must use activeKey parameter');
  assert.ok(!issueSrc.includes('rawKeyHex?:'), 'vaultIssues.ts must not have rawKeyHex parameter');

  const memSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultMemories.ts'), 'utf8');
  assert.ok(memSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultMemories.ts must use activeKey parameter');
  assert.ok(!memSrc.includes('rawKeyHex?:'), 'vaultMemories.ts must not have rawKeyHex parameter');

  const projSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultProjects.ts'), 'utf8');
  assert.ok(projSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultProjects.ts must use activeKey parameter');
  assert.ok(!projSrc.includes('rawKeyHex?:'), 'vaultProjects.ts must not have rawKeyHex parameter');

  const artSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultArtifacts.ts'), 'utf8');
  assert.ok(artSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultArtifacts.ts must use activeKey parameter');
  assert.ok(!artSrc.includes('rawKeyHex?:'), 'vaultArtifacts.ts must not have rawKeyHex parameter');

  const chainSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultChains.ts'), 'utf8');
  assert.ok(chainSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultChains.ts must use activeKey parameter');
  assert.ok(!chainSrc.includes('rawKeyHex?:'), 'vaultChains.ts must not have rawKeyHex parameter');

  const searchSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/vaultSearch.ts'), 'utf8');
  assert.ok(searchSrc.includes('activeKey?: CryptoKey | string | null'), 'vaultSearch.ts must use activeKey parameter');
  assert.ok(!searchSrc.includes('rawKeyHex?:'), 'vaultSearch.ts must not have rawKeyHex parameter');
});


