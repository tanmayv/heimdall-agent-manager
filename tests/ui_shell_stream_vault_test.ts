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
