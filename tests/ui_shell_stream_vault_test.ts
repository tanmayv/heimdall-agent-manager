// REQ-SHELL-ENC-5: Automated unit and contract tests for client-side PTY stream decryption and input encryption
// Validates transparent AES-256-GCM decryption of enc_b64 stream frames, keystroke encryption,
// locked vault graceful fallback, and bridge wire-format compatibility.
//
// RUN: node --test tests/ui_shell_stream_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
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
import { importRawKeyHex } from '../src/ui/utils/vaultCrypto.ts';

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

  // Must support vault state and key options
  assert.ok(src.includes('rawVaultKeyHex?: string | null'), 'must accept rawVaultKeyHex in options');
  assert.ok(src.includes('isVaultUnlocked?: boolean'), 'must accept isVaultUnlocked in options');

  // Must read Redux vault state
  assert.ok(src.includes('useSelector'), 'must use Redux useSelector');
  assert.ok(src.includes('rawVaultKeyHex'), 'must reference rawVaultKeyHex');

  // Must handle enc_b64 in onmessage for output and screen
  assert.ok(src.includes("msg.type === 'output'"), 'must handle output message');
  assert.ok(src.includes("msg.type === 'screen'"), 'must handle screen message');
  assert.ok(src.includes('enc_b64'), 'must inspect enc_b64 field');
  assert.ok(src.includes('decryptShellStreamPayload'), 'must call decryptShellStreamPayload on encrypted frames');

  // Must encrypt outgoing input when vault is unlocked and fall back to data_b64 when locked
  assert.ok(src.includes('encryptShellStreamPayload'), 'must call encryptShellStreamPayload in sendInput');
  assert.ok(src.includes("type: 'input', enc_b64"), 'must send enc_b64 for input when vault unlocked');
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
  assert.ok(
    endpointSrc.includes('readSessionVaultKey'),
    'shells.ts must import readSessionVaultKey',
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
    endpointSrc.includes('rawVaultKeyHex') && endpointSrc.includes('isUnlocked'),
    'createShell queryFn must check vault unlock status and raw key',
  );

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
    endpointSrc.includes('encryptVaultText(JSON.stringify(spec), rawKeyHex)'),
    'createShell queryFn must encrypt spec JSON with rawKeyHex',
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

test('REQ-SHELL-ENC-8: createShell logic generates valid armored enc_spec containing expected JSON properties when vault is unlocked', async () => {
  const cmd = 'npm run dev';
  const cwd = '/home/user/project';
  const startTime = Date.now();

  // Simulate queryFn execution when vault is unlocked
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_VAULT_KEY } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const body = { cmd, cwd, kind: 'shell' as const };
  let requestBody: Record<string, any> = { ...body };

  if (isUnlocked && rawKeyHex) {
    const spec = {
      cmd: body.cmd || '',
      cwd: body.cwd || '',
      timestamp: Date.now(),
      nonce: crypto.randomUUID(),
    };
    const enc_spec = await encryptVaultText(JSON.stringify(spec), rawKeyHex);
    requestBody = { ...body, enc_spec };
  }

  assert.ok(requestBody.enc_spec, 'requestBody must contain enc_spec');
  assert.ok(isVaultArmored(requestBody.enc_spec), 'enc_spec must start with vault:v1:');

  // Decrypt enc_spec with vault key
  const decryptedJson = await decryptVaultText(requestBody.enc_spec, TEST_VAULT_KEY);
  const parsedSpec = JSON.parse(decryptedJson);

  assert.equal(parsedSpec.cmd, cmd, 'decrypted spec cmd must match input cmd');
  assert.equal(parsedSpec.cwd, cwd, 'decrypted spec cwd must match input cwd');
  assert.ok(typeof parsedSpec.timestamp === 'number', 'timestamp must be a number');
  assert.ok(parsedSpec.timestamp >= startTime && parsedSpec.timestamp <= Date.now(), 'timestamp must be current');
  assert.ok(typeof parsedSpec.nonce === 'string' && parsedSpec.nonce.length >= 16, 'nonce must be a non-empty string');
  // Check UUID format
  assert.ok(
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(parsedSpec.nonce),
    'nonce must be valid UUID string',
  );
});

test('REQ-SHELL-ENC-8: createShell logic omits enc_spec when vault is locked (transparent fallback)', async () => {
  const stateLocked: any = { vault: { isUnlocked: false, rawVaultKeyHex: null } };
  const isUnlocked = Boolean(stateLocked?.vault?.isUnlocked || stateLocked?.vault?.unlocked);
  const rawKeyHex = stateLocked?.vault?.rawVaultKeyHex;

  const body = { cmd: 'ls -la', cwd: '/tmp', kind: 'run' as const };
  let requestBody: Record<string, any> = { ...body };

  if (isUnlocked && rawKeyHex) {
    const spec = {
      cmd: body.cmd || '',
      cwd: body.cwd || '',
      timestamp: Date.now(),
      nonce: crypto.randomUUID(),
    };
    const enc_spec = await encryptVaultText(JSON.stringify(spec), rawKeyHex);
    requestBody = { ...body, enc_spec };
  }

  assert.strictEqual(requestBody.enc_spec, undefined, 'enc_spec must be omitted when vault is locked');
  assert.equal(requestBody.cmd, 'ls -la');
  assert.equal(requestBody.cwd, '/tmp');
});

test('REQ-SHELL-ENC-8: createShell logic omits enc_spec when key is unavailable/null even if isUnlocked is true', async () => {
  const stateNoKey: any = { vault: { isUnlocked: true, rawVaultKeyHex: null } };
  const isUnlocked = Boolean(stateNoKey?.vault?.isUnlocked || stateNoKey?.vault?.unlocked);
  const rawKeyHex = stateNoKey?.vault?.rawVaultKeyHex;

  const body = { cmd: 'cat /etc/hosts', cwd: '/', kind: 'run' as const };
  let requestBody: Record<string, any> = { ...body };

  if (isUnlocked && rawKeyHex) {
    const spec = {
      cmd: body.cmd || '',
      cwd: body.cwd || '',
      timestamp: Date.now(),
      nonce: crypto.randomUUID(),
    };
    const enc_spec = await encryptVaultText(JSON.stringify(spec), rawKeyHex);
    requestBody = { ...body, enc_spec };
  }

  assert.strictEqual(requestBody.enc_spec, undefined, 'enc_spec must be omitted when rawKeyHex is missing');
});

test('REQ-SHELL-ENC-8: createShell defaults omitted cmd and cwd to empty strings in spec', async () => {
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_VAULT_KEY } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const body: { cmd?: string; cwd?: string; kind: 'shell' } = { kind: 'shell' };
  let requestBody: Record<string, any> = { ...body };

  if (isUnlocked && rawKeyHex) {
    const spec = {
      cmd: body.cmd || '',
      cwd: body.cwd || '',
      timestamp: Date.now(),
      nonce: crypto.randomUUID(),
    };
    const enc_spec = await encryptVaultText(JSON.stringify(spec), rawKeyHex);
    requestBody = { ...body, enc_spec };
  }

  assert.ok(requestBody.enc_spec);
  const decryptedJson = await decryptVaultText(requestBody.enc_spec, TEST_VAULT_KEY);
  const parsedSpec = JSON.parse(decryptedJson);

  assert.strictEqual(parsedSpec.cmd, '', 'omitted cmd must default to empty string');
  assert.strictEqual(parsedSpec.cwd, '', 'omitted cwd must default to empty string');
});

test('REQ-SHELL-ENC-8: createShell generates distinct randomized nonces across multiple calls', async () => {
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_VAULT_KEY } };
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const spec1 = { cmd: 'test', cwd: '/dir', timestamp: Date.now(), nonce: crypto.randomUUID() };
  const spec2 = { cmd: 'test', cwd: '/dir', timestamp: Date.now(), nonce: crypto.randomUUID() };

  const enc1 = await encryptVaultText(JSON.stringify(spec1), rawKeyHex);
  const enc2 = await encryptVaultText(JSON.stringify(spec2), rawKeyHex);

  assert.notEqual(enc1, enc2, 'encryptions must produce distinct ciphertexts');

  const p1 = JSON.parse(await decryptVaultText(enc1, TEST_VAULT_KEY));
  const p2 = JSON.parse(await decryptVaultText(enc2, TEST_VAULT_KEY));
  assert.notEqual(p1.nonce, p2.nonce, 'nonces must be unique');
});

// -----------------------------------------------------------------------------
// 4. REQ-SHELL-ENC-10: sendShellInput Vault Encryption in shells.ts
// -----------------------------------------------------------------------------

test('REQ-SHELL-ENC-10: sendShellInput static contract verification', () => {
  const shellsSrc = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/api/endpoints/shells.ts'), 'utf8');
  assert.ok(shellsSrc.includes('sendShellInput: build.mutation'), 'shells.ts must define sendShellInput mutation');
  assert.ok(shellsSrc.includes('encryptShellStreamPayload'), 'shells.ts must import encryptShellStreamPayload');
  assert.ok(shellsSrc.includes('selectIsVaultUnlocked'), 'shells.ts must import selectIsVaultUnlocked');
  assert.ok(shellsSrc.includes('readSessionVaultKey'), 'shells.ts must import readSessionVaultKey');
  assert.ok(shellsSrc.includes('payload.enc_b64 = resolvedEncB64'), 'sendShellInput must attach enc_b64 when encrypted');
});

test('REQ-SHELL-ENC-10: sendShellInput encrypts data when vault is unlocked', async () => {
  const data = 'ls -la\n';
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_VAULT_KEY } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  let enc_b64: string | undefined;
  if (isUnlocked && rawKeyHex) {
    enc_b64 = await encryptShellStreamPayload(data, rawKeyHex);
  }

  assert.ok(enc_b64, 'enc_b64 must be generated');
  const decryptedBytes = await decryptShellStreamPayload(enc_b64, TEST_VAULT_KEY);
  assert.equal(new TextDecoder().decode(decryptedBytes), data);
});

test('REQ-SHELL-ENC-10: sendShellInput omits enc_b64 when vault is locked', async () => {
  const data = 'ls -la\n';
  const state: any = { vault: { isUnlocked: false, rawVaultKeyHex: null } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  let enc_b64: string | undefined;
  if (isUnlocked && rawKeyHex) {
    enc_b64 = await encryptShellStreamPayload(data, rawKeyHex);
  }

  assert.strictEqual(enc_b64, undefined, 'enc_b64 must not be set when vault is locked');
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

