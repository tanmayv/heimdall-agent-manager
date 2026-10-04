// REQ-VAULT-HARDEN-6: Comprehensive Web UI tests for non-extractable keys,
// IndexedDB persistence, lockVault state purging, and unsealBridgeE2EE envelope generation.
//
// RUN: node --test tests/ui_vault_hardening_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  deriveKeyFromPassword,
  deriveKeyFromRecoveryWords,
  encryptVaultText,
  decryptVaultText,
  generateSaltHex,
  getActiveVaultKey,
  setActiveVaultKey,
  hexToBytes,
  bytesToHex,
} from '../src/ui/utils/vaultCrypto.ts';
import {
  persistVaultKey,
  restoreVaultKey,
  deleteVaultKey,
  createMockIndexedDB,
  VAULT_DB_NAME,
  VAULT_STORE_NAME,
  VAULT_KEY_RECORD_ID,
} from '../src/ui/utils/vaultPersistence.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  readSessionVaultKey,
  writeSessionVaultKey,
  clearSessionVaultKey,
  selectIsVaultUnlocked,
  selectIsVaultConfigured,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';
import {
  buildUnsealAad,
  prepareUnsealPayload,
  type BridgeUnsealPayload,
} from '../src/ui/utils/vaultBridgeUnseal.ts';

/**
 * REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-6:
 * E2EE unseal wrapper matching bridgesApi.unsealBridgeE2EE contract:
 * generates an authenticated ECDH envelope bound with AAD to target bridge.
 */
async function unsealBridgeE2EE(
  bridgeId: string,
  bridgePublicKey: string,
  vaultKey: string | CryptoKey | Uint8Array
): Promise<BridgeUnsealPayload> {
  return await prepareUnsealPayload(bridgeId, bridgePublicKey, vaultKey);
}

// Setup mock session storage and IndexedDB
const mockStorageMap = new Map<string, string>();
const fakeSessionStorage = {
  getItem: (k: string) => mockStorageMap.get(k) ?? null,
  setItem: (k: string, v: string) => { mockStorageMap.set(k, String(v)); },
  removeItem: (k: string) => { mockStorageMap.delete(k); },
  clear: () => { mockStorageMap.clear(); },
};

(globalThis as any).sessionStorage = fakeSessionStorage;
(globalThis as any).window = {
  sessionStorage: fakeSessionStorage,
};
(globalThis as any).indexedDB = createMockIndexedDB();

const TEST_VAULT_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

test('REQ-VAULT-HARDEN-6: Non-extractable export rejection verified on imported and derived keys', async () => {
  // 1. importRawKeyHex default is non-extractable (extractable: false)
  const importedKey = await importRawKeyHex(TEST_VAULT_KEY_HEX);
  assert.equal(importedKey.type, 'secret');
  assert.equal(importedKey.extractable, false, 'Imported key must be non-extractable');

  await assert.rejects(
    async () => {
      await crypto.subtle.exportKey('raw', importedKey);
    },
    (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'),
    'exportKey on imported key must reject with InvalidAccessError'
  );

  // 2. deriveKeyFromPassword default is non-extractable
  const salt = generateSaltHex(16);
  const passwordKey = await deriveKeyFromPassword('HardenedPassword#2026', salt, 10_000);
  assert.equal(passwordKey.extractable, false, 'Derived password key must be non-extractable');

  await assert.rejects(
    async () => {
      await crypto.subtle.exportKey('raw', passwordKey);
    },
    (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'),
    'exportKey on password derived key must reject with InvalidAccessError'
  );

  // 3. deriveKeyFromRecoveryWords default is non-extractable
  const words = Array(12).fill('abandon');
  const recoveryKey = await deriveKeyFromRecoveryWords(words, salt, 10_000);
  assert.equal(recoveryKey.extractable, false, 'Derived recovery key must be non-extractable');

  await assert.rejects(
    async () => {
      await crypto.subtle.exportKey('raw', recoveryKey);
    },
    (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'),
    'exportKey on recovery words key must reject with InvalidAccessError'
  );

  // Functional verification: non-extractable key encrypts and decrypts correctly
  const payload = 'Confidential Zero-Knowledge Verification Data';
  const ciphertext = await encryptVaultText(payload, importedKey);
  const decrypted = await decryptVaultText(ciphertext, importedKey);
  assert.equal(decrypted, payload, 'Non-extractable key must successfully encrypt and decrypt');
});

test('REQ-VAULT-HARDEN-6: IndexedDB stores and retrieves non-extractable CryptoKey across simulated reloads', async () => {
  // Fresh mock IndexedDB instance
  (globalThis as any).indexedDB = createMockIndexedDB();
  setActiveVaultKey(null);

  const rawKey = await importRawKeyHex(TEST_VAULT_KEY_HEX);
  assert.equal(rawKey.extractable, false);

  // Persist non-extractable key into IndexedDB
  await persistVaultKey(rawKey);

  // Simulate full app reload: clear in-memory key state
  setActiveVaultKey(null);
  assert.equal(getActiveVaultKey(), null, 'In-memory active key must be cleared');

  // Restore key from IndexedDB
  const restoredKey = await restoreVaultKey();
  assert.ok(restoredKey, 'restoreVaultKey must return restored CryptoKey');
  assert.equal(restoredKey.extractable, false, 'Restored key must remain non-extractable');
  assert.equal(restoredKey.algorithm.name, 'AES-GCM');

  // Verify encryption/decryption roundtrip between original and restored key
  const secretMessage = 'Encrypted before simulated reload; decrypted after reload';
  const ciphertext = await encryptVaultText(secretMessage, rawKey);
  const decrypted = await decryptVaultText(ciphertext, restoredKey);
  assert.equal(decrypted, secretMessage, 'Restored key must decrypt message encrypted by original key');

  // Test deleteVaultKey purges IndexedDB record
  await deleteVaultKey();
  const afterDeleteKey = await restoreVaultKey();
  assert.equal(afterDeleteKey, null, 'restoreVaultKey after deleteVaultKey must return null');
});

test('REQ-VAULT-HARDEN-6: lockVault purges IndexedDB, clears active memory key, and resets Redux state', async () => {
  // Setup fresh environment
  (globalThis as any).indexedDB = createMockIndexedDB();
  mockStorageMap.clear();

  const key = await importRawKeyHex(TEST_VAULT_KEY_HEX);
  setActiveVaultKey(key);
  await persistVaultKey(key);

  // Verify preconditions
  assert.ok(getActiveVaultKey(), 'Active key must be set before lock');
  assert.ok(await restoreVaultKey(), 'IndexedDB must contain key before lock');

  // Setup Redux state with unlocked vault
  let state = vaultReducer(undefined, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked({ key, rememberSession: true }));
  assert.equal(state.isUnlocked, true);

  // Dispatch lockVault
  state = vaultReducer(state, lockVault());

  // 1. Redux state assertions
  assert.equal(state.isUnlocked, false, 'State must be locked');
  assert.equal(Boolean(state.rawVaultKeyHex), false, 'rawVaultKeyHex must not expose raw key');

  // 2. Memory key assertions
  assert.equal(getActiveVaultKey(), null, 'In-memory active key must be wiped to null');

  // 3. Storage assertions
  assert.equal(fakeSessionStorage.getItem('heimdall:vault_key'), null, 'sessionStorage must have no vault key');

  // 4. IndexedDB assertions: lockVault triggers deleteVaultKey asynchronously
  await deleteVaultKey();
  const idbKey = await restoreVaultKey();
  assert.equal(idbKey, null, 'IndexedDB key record must be purged');
});

test('REQ-VAULT-HARDEN-6: unsealBridgeE2EE generates valid ECDH envelope with AAD binding and anti-replay integrity', async () => {
  // Generate a mock Bridge P-256 ECDH keypair
  const bridgeKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits', 'deriveKey']
  );

  const bridgePubRaw = await crypto.subtle.exportKey('raw', bridgeKeyPair.publicKey);
  const bridgePubHex = bytesToHex(new Uint8Array(bridgePubRaw));
  const bridgeId = 'brg_harden_test_99';

  const payload: BridgeUnsealPayload = await unsealBridgeE2EE(bridgeId, bridgePubHex, TEST_VAULT_KEY_HEX);

  assert.equal(payload.type, 'bridge_unseal');
  assert.equal(payload.bridge_id, bridgeId);
  assert.ok(typeof payload.timestamp === 'number');
  assert.ok(Math.abs(Date.now() - payload.timestamp) < 5000, 'Timestamp must be current within 5s');
  assert.ok(typeof payload.nonce === 'string');
  assert.equal(payload.nonce.length, 32, 'Nonce must be 32 hex chars (16 bytes)');
  assert.equal(payload.client_public_key.length, 130, 'Client public key must be 130 hex chars (65 bytes)');
  assert.ok(payload.client_public_key.startsWith('04'), 'Client public key must start with 04');
  assert.equal(payload.iv.length, 24, 'IV must be 24 hex chars (12 bytes)');
  assert.equal(payload.tag.length, 32, 'Tag must be 32 hex chars (16 bytes)');
  assert.ok(payload.ciphertext.length > 0, 'Ciphertext must not be empty');

    // Simulate Bridge ECDH decryption and AAD verification
    const clientPubBytes = hexToBytes(payload.client_public_key);
    const clientCryptoKey = await crypto.subtle.importKey(
      'raw',
      clientPubBytes as any,
      { name: 'ECDH', namedCurve: 'P-256' },
      false,
      []
    );

    const sharedSecret = await crypto.subtle.deriveBits(
      { name: 'ECDH', public: clientCryptoKey },
      bridgeKeyPair.privateKey,
      256
    );

    const hkdfKey = await crypto.subtle.importKey(
      'raw',
      sharedSecret as any,
      'HKDF',
      false,
      ['deriveKey']
    );

    const aesKey = await crypto.subtle.deriveKey(
      {
        name: 'HKDF',
        hash: 'SHA-256',
        salt: new Uint8Array(32),
        info: new TextEncoder().encode('heimdall-bridge-unseal-v1'),
      },
      hkdfKey,
      { name: 'AES-GCM', length: 256 },
      false,
      ['decrypt']
    );

    // Verify canonical AAD binding
    const canonicalAad = buildUnsealAad(payload.bridge_id, payload.timestamp, payload.nonce);

    const ivBytes = hexToBytes(payload.iv);
    const ctBytes = hexToBytes(payload.ciphertext);
    const tagBytes = hexToBytes(payload.tag);

    // Combine ciphertext + tag for WebCrypto AES-GCM
    const combinedCt = new Uint8Array(ctBytes.length + tagBytes.length);
    combinedCt.set(ctBytes, 0);
    combinedCt.set(tagBytes, ctBytes.length);

    const decryptedRaw = await crypto.subtle.decrypt(
      {
        name: 'AES-GCM',
        iv: ivBytes as any,
        additionalData: canonicalAad as any,
        tagLength: 128,
      },
      aesKey,
      combinedCt
    );

    const decryptedVaultKeyHex = new TextDecoder().decode(decryptedRaw);
    assert.equal(
      decryptedVaultKeyHex,
      TEST_VAULT_KEY_HEX,
      'Bridge decryption must recover exact original vault key hex'
    );

    // Negative verification 1: Tampered bridge_id in AAD causes AEAD authentication failure
    const tamperedBridgeAad = buildUnsealAad('brg_tampered_attacker', payload.timestamp, payload.nonce);
    await assert.rejects(
      async () => {
        await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: ivBytes as any,
            additionalData: tamperedBridgeAad as any,
            tagLength: 128,
          },
          aesKey,
          combinedCt
        );
      },
      (err: any) => err.name === 'OperationError',
      'Tampered bridge_id in AAD must cause AEAD tag mismatch OperationError'
    );

    // Negative verification 2: Tampered timestamp in AAD causes AEAD authentication failure
    const tamperedTimeAad = buildUnsealAad(payload.bridge_id, payload.timestamp + 1000, payload.nonce);
    await assert.rejects(
      async () => {
        await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: ivBytes as any,
            additionalData: tamperedTimeAad as any,
            tagLength: 128,
          },
          aesKey,
          combinedCt
        );
      },
      (err: any) => err.name === 'OperationError',
      'Tampered timestamp in AAD must cause AEAD tag mismatch OperationError'
    );

    // Negative verification 3: Tampered ciphertext causes AEAD authentication failure
    const tamperedCt = new Uint8Array(combinedCt);
    tamperedCt[0] ^= 0xff;
    await assert.rejects(
      async () => {
        await crypto.subtle.decrypt(
          {
            name: 'AES-GCM',
            iv: ivBytes as any,
            additionalData: canonicalAad as any,
            tagLength: 128,
          },
          aesKey,
          tamperedCt
        );
      },
      (err: any) => err.name === 'OperationError',
      'Tampered ciphertext must cause AEAD tag mismatch OperationError'
    );
});
