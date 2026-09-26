// REQ-VAULT-CONTENT-LIB-1: Tests for Reusable Content Cryptography Library & Declarative Transformers
// Validates wire format 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>',
// transparent fallback, round-trips, tamper detection, object/list transformers, and cross-platform compatibility.
//
// RUN: node --test tests/ui_vault_content_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  containsVaultArmored,
  isValidBase64,
  bytesToBase64,
  base64ToBytes,
  resolveCryptoKey,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  encryptFields,
  decryptFields,
  decryptList,
  encryptList,
  VAULT_ARMOR_PREFIX,
  MIN_ARMOR_PAYLOAD_BYTES,
} from '../src/ui/utils/vaultContent.ts';
import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
} from '../src/ui/utils/vaultCrypto.ts';

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const ALTERNATIVE_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// 1. Prefix Detection & Base64 Helpers
// -----------------------------------------------------------------------------

test('isVaultArmored accurately detects vault:v1: prefix', () => {
  assert.equal(isVaultArmored('vault:v1:'), true);
  assert.equal(isVaultArmored('vault:v1:AQIDBAUGBwgJCgsM2Ed9...'), true);
  assert.equal(isVaultArmored('vault:v1:payload'), true);

  assert.equal(isVaultArmored('vault:v2:payload'), false);
  assert.equal(isVaultArmored('vault:v1'), false);
  assert.equal(isVaultArmored('vault:'), false);
  assert.equal(isVaultArmored(''), false);
  assert.equal(isVaultArmored('plain text content'), false);
  assert.equal(isVaultArmored(null), false);
  assert.equal(isVaultArmored(undefined), false);
  assert.equal(isVaultArmored(12345), false);
  assert.equal(isVaultArmored({}), false);
});

test('isValidBase64 validates base64 string alphabet and padding', () => {
  assert.equal(isValidBase64(''), false);
  assert.equal(isValidBase64('abc'), false, 'length not multiple of 4');
  assert.equal(isValidBase64('abcd'), true);
  assert.equal(isValidBase64('abcd1234'), true);
  assert.equal(isValidBase64('ab=='), true);
  assert.equal(isValidBase64('abc='), true);
  assert.equal(isValidBase64('a==='), false, 'more than 2 padding chars');
  assert.equal(isValidBase64('ab$d'), false, 'invalid character');
});

test('bytesToBase64 and base64ToBytes round-trip arbitrary byte buffers', () => {
  const sample = new Uint8Array([0, 1, 2, 127, 128, 254, 255, 42, 99]);
  const b64 = bytesToBase64(sample);
  const recovered = base64ToBytes(b64);
  assert.deepEqual(Array.from(recovered), Array.from(sample));

  // Empty buffer
  assert.equal(bytesToBase64(new Uint8Array([])), '');
  assert.deepEqual(Array.from(base64ToBytes('')), []);
});

// -----------------------------------------------------------------------------
// 2. Encryption Envelope & Wire Format
// -----------------------------------------------------------------------------

test('encryptVaultText produces valid vault:v1:<base64> envelope with 12B nonce and 16B auth tag', async () => {
  const plaintext = 'Zero-Knowledge Agent Workspace';
  const armored = await encryptVaultText(plaintext, TEST_KEY_HEX);

  assert.ok(armored.startsWith(VAULT_ARMOR_PREFIX), 'Must begin with vault:v1: prefix');

  const b64 = armored.slice(VAULT_ARMOR_PREFIX.length);
  assert.ok(isValidBase64(b64), 'Payload must be valid base64');

  const payload = base64ToBytes(b64);
  const expectedPlaintextBytes = new TextEncoder().encode(plaintext);
  const expectedTotalBytes = MIN_ARMOR_PAYLOAD_BYTES + expectedPlaintextBytes.length; // 12 + 16 + len

  assert.equal(payload.length, expectedTotalBytes, 'Payload size must be 12B nonce + 16B tag + len(ciphertext)');
});

test('encryptVaultText generates randomized nonces across repeated encryptions (semantic security)', async () => {
  const plaintext = 'Deterministic plaintexts must produce non-deterministic ciphertexts';
  const armored1 = await encryptVaultText(plaintext, TEST_KEY_HEX);
  const armored2 = await encryptVaultText(plaintext, TEST_KEY_HEX);

  assert.notEqual(armored1, armored2, 'Two encryptions of the same plaintext must produce different ciphertexts');

  const payload1 = base64ToBytes(armored1.slice(VAULT_ARMOR_PREFIX.length));
  const payload2 = base64ToBytes(armored2.slice(VAULT_ARMOR_PREFIX.length));

  const nonce1 = payload1.subarray(0, 12);
  const nonce2 = payload2.subarray(0, 12);

  assert.notDeepEqual(Array.from(nonce1), Array.from(nonce2), 'Nonces must be distinct');
});

// -----------------------------------------------------------------------------
// 3. Decryption & Transparent Fallback
// -----------------------------------------------------------------------------

test('decryptVaultText accurately round-trips with 64-character hex key string', async () => {
  const original = 'Secret task prompt: refactor database indexing strategy';
  const armored = await encryptVaultText(original, TEST_KEY_HEX);
  const decrypted = await decryptVaultText(armored, TEST_KEY_HEX);

  assert.equal(decrypted, original);
});

test('decryptVaultText accurately round-trips with WebCrypto CryptoKey instance', async () => {
  const key = await generateVaultKey();
  const original = 'In-memory CryptoKey instance test payload';
  const armored = await encryptVaultText(original, key);
  const decrypted = await decryptVaultText(armored, key);

  assert.equal(decrypted, original);
});

test('decryptVaultText handles empty strings and edge-case text', async () => {
  // Empty string
  const armoredEmpty = await encryptVaultText('', TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredEmpty));
  const decryptedEmpty = await decryptVaultText(armoredEmpty, TEST_KEY_HEX);
  assert.equal(decryptedEmpty, '');

  // Multiline & special characters
  const multiline = "Line 1: Special chars: !@#$%^&*()_+-=[]{}|;':\",./<>?\nLine 2: Tab\there\r\nLine 3: End.";
  const armoredMulti = await encryptVaultText(multiline, TEST_KEY_HEX);
  const decryptedMulti = await decryptVaultText(armoredMulti, TEST_KEY_HEX);
  assert.equal(decryptedMulti, multiline);

  // Unicode & Emoji
  const unicode = '🔐 Zero-Knowledge Heimdall: 🚀 🤖 日本語 • 中文 • Español • Deutsch';
  const armoredUnicode = await encryptVaultText(unicode, TEST_KEY_HEX);
  const decryptedUnicode = await decryptVaultText(armoredUnicode, TEST_KEY_HEX);
  assert.equal(decryptedUnicode, unicode);

  // Large payload (16KB)
  const largeText = 'A'.repeat(16384);
  const armoredLarge = await encryptVaultText(largeText, TEST_KEY_HEX);
  const decryptedLarge = await decryptVaultText(armoredLarge, TEST_KEY_HEX);
  assert.equal(decryptedLarge, largeText);
});

test('decryptVaultText transparently falls back to unarmored string as-is without error', async () => {
  const plain = 'Legacy plain text without armor prefix';
  const result = await decryptVaultText(plain, TEST_KEY_HEX);
  assert.equal(result, plain, 'Unarmored text must be returned as-is');

  assert.equal(await decryptVaultText('', TEST_KEY_HEX), '');
  assert.equal(await decryptVaultText('vault:v2:unsupported-version', TEST_KEY_HEX), 'vault:v2:unsupported-version');
});

// -----------------------------------------------------------------------------
// 4. Tamper Detection & Security Checks
// -----------------------------------------------------------------------------

test('decryptVaultText rejects tampered ciphertext or authentication tag', async () => {
  const original = 'Authentic payload to be tampered with';
  const armored = await encryptVaultText(original, TEST_KEY_HEX);

  const b64 = armored.slice(VAULT_ARMOR_PREFIX.length);
  const payload = base64ToBytes(b64);

  // 1. Tamper with ciphertext (last byte)
  const tamperedCiphertext = new Uint8Array(payload);
  tamperedCiphertext[tamperedCiphertext.length - 1] ^= 0x01;
  const tamperedArmored1 = `${VAULT_ARMOR_PREFIX}${bytesToBase64(tamperedCiphertext)}`;

  await assert.rejects(
    async () => {
      await decryptVaultText(tamperedArmored1, TEST_KEY_HEX);
    },
    /operation|mac|tag|decrypt/i,
    'Tampered ciphertext must cause decryption to fail authentication',
  );

  // 2. Tamper with auth tag (byte 15, within tag range 12..27)
  const tamperedTag = new Uint8Array(payload);
  tamperedTag[15] ^= 0x42;
  const tamperedArmored2 = `${VAULT_ARMOR_PREFIX}${bytesToBase64(tamperedTag)}`;

  await assert.rejects(
    async () => {
      await decryptVaultText(tamperedArmored2, TEST_KEY_HEX);
    },
    /operation|mac|tag|decrypt/i,
    'Tampered authentication tag must cause decryption to fail authentication',
  );

  // 3. Tamper with nonce (byte 0)
  const tamperedNonce = new Uint8Array(payload);
  tamperedNonce[0] ^= 0x99;
  const tamperedArmored3 = `${VAULT_ARMOR_PREFIX}${bytesToBase64(tamperedNonce)}`;

  await assert.rejects(
    async () => {
      await decryptVaultText(tamperedArmored3, TEST_KEY_HEX);
    },
    /operation|mac|tag|decrypt/i,
    'Tampered nonce must cause decryption to fail authentication',
  );
});

test('decryptVaultText rejects decryption with incorrect key', async () => {
  const original = 'Encrypted with Key A, attempted decrypt with Key B';
  const armored = await encryptVaultText(original, TEST_KEY_HEX);

  await assert.rejects(
    async () => {
      await decryptVaultText(armored, ALTERNATIVE_KEY_HEX);
    },
    /operation|mac|tag|decrypt/i,
    'Decryption with wrong key must fail authentication',
  );
});

test('decryptVaultText rejects truncated payloads and malformed base64', async () => {
  // Truncated payload less than 28 bytes
  const shortPayload = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  const shortArmored = `${VAULT_ARMOR_PREFIX}${bytesToBase64(shortPayload)}`;

  await assert.rejects(
    async () => {
      await decryptVaultText(shortArmored, TEST_KEY_HEX);
    },
    /less than header/i,
  );

  // Malformed base64 string
  await assert.rejects(
    async () => {
      await decryptVaultText(`${VAULT_ARMOR_PREFIX}not-valid-base64!!`, TEST_KEY_HEX);
    },
    /malformed base64/i,
  );
});

// -----------------------------------------------------------------------------
// 5. Declarative Object & List Transformers
// -----------------------------------------------------------------------------

interface TaskModel {
  task_id: string;
  chain_id: string;
  title: string;
  description: string;
  status: string;
  priority: number;
}

test('encryptFields transforms targeted string fields and preserves unencrypted fields', async () => {
  const task: TaskModel = {
    task_id: 'task_100',
    chain_id: 'chain_200',
    title: 'Secret Task Title',
    description: 'Highly sensitive task instructions for autonomous agent',
    status: 'in_progress',
    priority: 1,
  };

  const encrypted = await encryptFields(task, ['title', 'description'], TEST_KEY_HEX);

  // Preserved non-targeted fields
  assert.equal(encrypted.task_id, 'task_100');
  assert.equal(encrypted.chain_id, 'chain_200');
  assert.equal(encrypted.status, 'in_progress');
  assert.equal(encrypted.priority, 1);

  // Encrypted targeted fields
  assert.ok(isVaultArmored(encrypted.title), 'title must be armored');
  assert.ok(isVaultArmored(encrypted.description), 'description must be armored');

  // Immutability: original task must remain untouched
  assert.equal(task.title, 'Secret Task Title');
  assert.equal(task.description, 'Highly sensitive task instructions for autonomous agent');
});

test('encryptFields is idempotent and does not double-encrypt already-armored fields', async () => {
  const task: TaskModel = {
    task_id: 'task_101',
    chain_id: 'chain_201',
    title: 'Initial Title',
    description: 'Initial Description',
    status: 'open',
    priority: 2,
  };

  const enc1 = await encryptFields(task, ['title', 'description'], TEST_KEY_HEX);
  const enc2 = await encryptFields(enc1, ['title', 'description'], TEST_KEY_HEX);

  assert.equal(enc1.title, enc2.title, 'Already-armored title should not be re-encrypted');
  assert.equal(enc1.description, enc2.description, 'Already-armored description should not be re-encrypted');
});

test('decryptFields restores targeted fields and leaves unencrypted fields intact', async () => {
  const originalTask: TaskModel = {
    task_id: 'task_102',
    chain_id: 'chain_202',
    title: 'Plan Sprint',
    description: 'Define sprint backlog items and deliverables',
    status: 'in_validation',
    priority: 0,
  };

  const encrypted = await encryptFields(originalTask, ['title', 'description'], TEST_KEY_HEX);
  const decrypted = await decryptFields(encrypted, ['title', 'description'], TEST_KEY_HEX);

  assert.deepEqual(decrypted, originalTask);
  assert.notEqual(decrypted, encrypted, 'decryptFields must return a new object instance');
});

test('decryptFields handles mixed unarmored fields gracefully (transparent fallback)', async () => {
  const mixed: TaskModel = {
    task_id: 'task_103',
    chain_id: 'chain_203',
    title: 'Unencrypted Legacy Title', // not armored
    description: await encryptVaultText('Encrypted Description Body', TEST_KEY_HEX), // armored
    status: 'done',
    priority: 1,
  };

  const decrypted = await decryptFields(mixed, ['title', 'description'], TEST_KEY_HEX);

  assert.equal(decrypted.title, 'Unencrypted Legacy Title', 'Unarmored field must be preserved as-is');
  assert.equal(decrypted.description, 'Encrypted Description Body', 'Armored field must be decrypted');
});

test('decryptList transforms an array of objects', async () => {
  const items: TaskModel[] = [
    {
      task_id: 'task_1',
      chain_id: 'chain_1',
      title: 'Task One',
      description: 'Description One',
      status: 'open',
      priority: 1,
    },
    {
      task_id: 'task_2',
      chain_id: 'chain_1',
      title: 'Task Two',
      description: 'Description Two',
      status: 'done',
      priority: 2,
    },
  ];

  const encryptedList = await encryptList(items, ['title', 'description'], TEST_KEY_HEX);
  assert.equal(encryptedList.length, 2);
  assert.ok(isVaultArmored(encryptedList[0].title));
  assert.ok(isVaultArmored(encryptedList[1].description));

  const decryptedList = await decryptList(encryptedList, ['title', 'description'], TEST_KEY_HEX);
  assert.deepEqual(decryptedList, items);
});

// -----------------------------------------------------------------------------
// 6. Cross-Platform WebCrypto / Odin Interoperability Test Vector
// -----------------------------------------------------------------------------

test('decryptVaultText successfully decrypts pre-computed test vector', async () => {
  // Generated with:
  // Key: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  // Nonce: 0102030405060708090a0b0c
  // Plaintext: "Hello, Heimdall Zero-Knowledge Vault!"
  const precomputedArmored = 'vault:v1:AQIDBAUGBwgJCgsM2Ed9QrWXWA/eSrkLieecc4/Y9yN6j/zgFPZJ0LLE5YuYHQC++IdmUyTVIwWlu20gv78kDuk=';

  const decrypted = await decryptVaultText(precomputedArmored, TEST_KEY_HEX);
  assert.equal(decrypted, 'Hello, Heimdall Zero-Knowledge Vault!');
});

// -----------------------------------------------------------------------------
// 7. Embedded Vault Token Detection & Decryption (REQ-INDIRECT-DECRYPT-UI-1)
// -----------------------------------------------------------------------------

test('containsVaultArmored accurately detects embedded vault:v1:... tokens', () => {
  assert.equal(containsVaultArmored('vault:v1:AQIDBAUGBwgJCgsM2Ed9'), true);
  assert.equal(containsVaultArmored('You: vault:v1:AQIDBAUGBwgJCgsM2Ed9'), true);
  assert.equal(containsVaultArmored('Action: vault:v1:AQIDBAUGBwgJCgsM2Ed9 approved'), true);
  assert.equal(containsVaultArmored('vault:v1:token1 and vault:v1:token2'), true);

  assert.equal(containsVaultArmored('plain text without vault tokens'), false);
  assert.equal(containsVaultArmored('vault:v2:notmatching'), false);
  assert.equal(containsVaultArmored('vault:'), false);
  assert.equal(containsVaultArmored(''), false);
  assert.equal(containsVaultArmored(null), false);
  assert.equal(containsVaultArmored(undefined), false);
  assert.equal(containsVaultArmored(12345), false);
});

test('decryptEmbeddedVaultTokens decrypts single and multiple embedded tokens while preserving surroundings', async () => {
  const secret1 = 'Secret Message Alpha';
  const secret2 = 'Confidential Action Beta';
  const armored1 = await encryptVaultText(secret1, TEST_KEY_HEX);
  const armored2 = await encryptVaultText(secret2, TEST_KEY_HEX);

  // Single embedded token with sender prefix (e.g. "You: vault:v1:...")
  const prefixed = `You: ${armored1}`;
  const decryptedPrefixed = await decryptEmbeddedVaultTokens(prefixed, TEST_KEY_HEX);
  assert.equal(decryptedPrefixed, `You: ${secret1}`);

  // Multiple embedded tokens
  const multi = `Notice: ${armored1} was executed during ${armored2}!`;
  const decryptedMulti = await decryptEmbeddedVaultTokens(multi, TEST_KEY_HEX);
  assert.equal(decryptedMulti, `Notice: ${secret1} was executed during ${secret2}!`);

  // Unarmored text returned as-is
  const plain = 'Completely plain text without tokens.';
  assert.equal(await decryptEmbeddedVaultTokens(plain, TEST_KEY_HEX), plain);

  // Missing or invalid key returns text without crashing
  assert.equal(await decryptEmbeddedVaultTokens(prefixed, ''), prefixed);
  assert.equal(await decryptEmbeddedVaultTokens(prefixed, null as any), prefixed);
});
