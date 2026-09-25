// REQ-VAULT-CRYPTO-LIB-1: Tests for WebCrypto User Vault Client Library,
// BIP-39 mnemonic phrase generation, envelope wrapping/unwrapping, and Redux vaultSlice.
//
// RUN: node --test tests/ui_vault_crypto_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { BIP39_WORDS } from '../src/ui/utils/bip39Words.ts';
import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  generateSaltHex,
  generateNonceHex,
  bytesToHex,
  hexToBytes,
  DEFAULT_KDF_ITERATIONS,
  VAULT_KEY_BYTES,
  AES_GCM_NONCE_BYTES,
  AES_GCM_TAG_BYTES,
} from '../src/ui/utils/vaultCrypto.ts';
import { configureStore } from '@reduxjs/toolkit';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  selectVaultState,
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';

// -----------------------------------------------------------------------------
// 1. BIP-39 Word List
// -----------------------------------------------------------------------------

test('BIP-39 English wordlist contains exactly 2048 words with proper bounds', () => {
  assert.equal(BIP39_WORDS.length, 2048, 'Word list must contain exactly 2048 words');
  assert.equal(BIP39_WORDS[0], 'abandon', 'First word in BIP-39 English is abandon');
  assert.equal(BIP39_WORDS[2047], 'zoo', 'Last word in BIP-39 English is zoo');

  const uniqueWords = new Set(BIP39_WORDS);
  assert.equal(uniqueWords.size, 2048, 'All words in BIP-39 list must be unique');

  for (const word of BIP39_WORDS) {
    assert.ok(word.length > 0, 'Word must not be empty');
    assert.equal(word, word.toLowerCase(), 'Word must be lowercase');
    assert.ok(!/\s/.test(word), 'Word must not contain whitespace');
  }
});

// -----------------------------------------------------------------------------
// 2. Hex and Buffer Utilities
// -----------------------------------------------------------------------------

test('hex conversion helpers correctly encode and decode bytes', () => {
  const sample = new Uint8Array([0x00, 0x0f, 0x10, 0xab, 0xff]);
  const hex = bytesToHex(sample);
  assert.equal(hex, '000f10abff');
  const decoded = hexToBytes(hex);
  assert.deepEqual(Array.from(decoded), Array.from(sample));

  // Invalid hex error cases
  assert.throws(() => hexToBytes('abc'), /even length/);
  assert.throws(() => hexToBytes('0g'), /Invalid hex/);
});

test('generateSaltHex and generateNonceHex return correct lengths', () => {
  const salt = generateSaltHex(16);
  assert.equal(salt.length, 32, '16-byte salt must be 32 hex characters');

  const nonce = generateNonceHex(12);
  assert.equal(nonce.length, 24, '12-byte nonce must be 24 hex characters');
});

// -----------------------------------------------------------------------------
// 3. Vault Key Generation, Hex Export, and Import
// -----------------------------------------------------------------------------

test('generateVaultKey creates an extractable 256-bit AES-GCM key', async () => {
  const key = await generateVaultKey();
  assert.equal(key.type, 'secret');
  assert.equal(key.algorithm.name, 'AES-GCM');
  assert.equal((key.algorithm as any).length, 256);
  assert.equal(key.extractable, true);
});

test('exportRawKeyHex and importRawKeyHex round-trip successfully', async () => {
  const originalKey = await generateVaultKey();
  const hex = await exportRawKeyHex(originalKey);

  assert.equal(hex.length, VAULT_KEY_BYTES * 2, 'Raw key hex must be 64 characters');
  assert.ok(/^[0-9a-f]{64}$/.test(hex), 'Raw key hex must be lowercase hex characters');

  const importedKey = await importRawKeyHex(hex);
  const reExportedHex = await exportRawKeyHex(importedKey);

  assert.equal(reExportedHex, hex, 'Re-exported key hex must match original');

  // Input validation
  await assert.rejects(async () => {
    await importRawKeyHex('abcd');
  }, /expected 32 bytes/);
});

// -----------------------------------------------------------------------------
// 4. PBKDF2 Password Derivation
// -----------------------------------------------------------------------------

test('deriveKeyFromPassword deterministically derives 256-bit AES-GCM key', async () => {
  const password = 'SuperSecretMasterPassword!2026';
  const saltHex = generateSaltHex(16);

  const key1 = await deriveKeyFromPassword(password, saltHex, 10_000);
  const key2 = await deriveKeyFromPassword(password, saltHex, 10_000);

  const raw1 = await exportRawKeyHex(key1);
  const raw2 = await exportRawKeyHex(key2);
  assert.equal(raw1, raw2, 'Same password and salt must derive identical keys');

  // Different password produces different key
  const keyDiffPass = await deriveKeyFromPassword('DifferentPassword!2026', saltHex, 10_000);
  const rawDiffPass = await exportRawKeyHex(keyDiffPass);
  assert.notEqual(raw1, rawDiffPass, 'Different password must derive different key');

  // Different salt produces different key
  const saltHex2 = generateSaltHex(16);
  const keyDiffSalt = await deriveKeyFromPassword(password, saltHex2, 10_000);
  const rawDiffSalt = await exportRawKeyHex(keyDiffSalt);
  assert.notEqual(raw1, rawDiffSalt, 'Different salt must derive different key');
});

// -----------------------------------------------------------------------------
// 5. 12-Word Mnemonic Generation and BIP-39 Checksum Validation
// -----------------------------------------------------------------------------

test('generate12RecoveryWords generates valid 12 BIP-39 words with valid checksum', () => {
  const result = generate12RecoveryWords();
  assert.equal(result.words.length, 12, 'Must generate exactly 12 words');
  assert.equal(result.entropyHex.length, 32, '128-bit entropy must be 32 hex chars');

  for (const word of result.words) {
    assert.ok(BIP39_WORDS.includes(word), `Word ${word} must be in BIP-39 wordlist`);
  }

  const isValid = validateRecoveryWords(result.words);
  assert.equal(isValid, true, 'Generated mnemonic must pass checksum validation');
});

test('validateRecoveryWords matches official BIP-39 test vector', () => {
  // BIP-39 test vector for 16 zero bytes (128-bit 0):
  // 11 x 'abandon' + 'about'
  const zeroEntropy = new Uint8Array(16);
  const vector = generate12RecoveryWords(zeroEntropy);

  assert.equal(vector.entropyHex, '00000000000000000000000000000000');
  assert.deepEqual(vector.words.slice(0, 11), Array(11).fill('abandon'));
  assert.equal(vector.words[11], 'about');

  assert.equal(validateRecoveryWords(vector.words), true);

  // Altering the last word invalidates the checksum
  const corrupted = [...vector.words];
  corrupted[11] = 'abandon';
  assert.equal(validateRecoveryWords(corrupted), false, 'Corrupted checksum word must fail');

  // Invalid word outside wordlist
  const unknownWord = [...vector.words];
  unknownWord[0] = 'notabip39word';
  assert.equal(validateRecoveryWords(unknownWord), false, 'Unknown word must fail');

  // Wrong number of words
  assert.equal(validateRecoveryWords(vector.words.slice(0, 11)), false);
});

// -----------------------------------------------------------------------------
// 6. Envelope Wrapping and Unwrapping (Master Password)
// -----------------------------------------------------------------------------

test('encryptVaultKeyEnvelope and decryptVaultKeyEnvelope round-trip with password', async () => {
  const vaultKey = await generateVaultKey();
  const originalVaultHex = await exportRawKeyHex(vaultKey);

  const saltHex = generateSaltHex(16);
  const password = 'CorrectHorseBatteryStaple#42';
  const masterKey = await deriveKeyFromPassword(password, saltHex, 50_000);

  const envelope = await encryptVaultKeyEnvelope(masterKey, vaultKey);
  assert.equal(envelope.ciphertextHex.length, VAULT_KEY_BYTES * 2, 'Ciphertext must be 32 bytes hex');
  assert.equal(envelope.nonceHex.length, AES_GCM_NONCE_BYTES * 2, 'Nonce must be 12 bytes hex');
  assert.equal(envelope.tagHex.length, AES_GCM_TAG_BYTES * 2, 'Tag must be 16 bytes hex');

  // Successful decryption
  const decryptedVaultKey = await decryptVaultKeyEnvelope(
    masterKey,
    envelope.ciphertextHex,
    envelope.nonceHex,
    envelope.tagHex,
  );
  const decryptedVaultHex = await exportRawKeyHex(decryptedVaultKey);
  assert.equal(decryptedVaultHex, originalVaultHex, 'Decrypted vault key hex must match original');

  // Wrong password fails
  const wrongKey = await deriveKeyFromPassword('WrongPassword', saltHex, 50_000);
  await assert.rejects(async () => {
    await decryptVaultKeyEnvelope(
      wrongKey,
      envelope.ciphertextHex,
      envelope.nonceHex,
      envelope.tagHex,
    );
  });

  // Tampered tag fails
  const tamperedTag = '00' + envelope.tagHex.slice(2);
  await assert.rejects(async () => {
    await decryptVaultKeyEnvelope(
      masterKey,
      envelope.ciphertextHex,
      envelope.nonceHex,
      tamperedTag,
    );
  });

  // Tampered ciphertext fails
  const tamperedCiphertext = '00' + envelope.ciphertextHex.slice(2);
  await assert.rejects(async () => {
    await decryptVaultKeyEnvelope(
      masterKey,
      tamperedCiphertext,
      envelope.nonceHex,
      envelope.tagHex,
    );
  });
});

// -----------------------------------------------------------------------------
// 7. Envelope Wrapping and Unwrapping (12 Recovery Words)
// -----------------------------------------------------------------------------

test('deriveKeyFromRecoveryWords enables full recovery envelope round-trip', async () => {
  const vaultKey = await generateVaultKey();
  const originalVaultHex = await exportRawKeyHex(vaultKey);

  const { words } = generate12RecoveryWords();
  const recoverySaltHex = generateSaltHex(16);

  const recoveryKey = await deriveKeyFromRecoveryWords(words, recoverySaltHex, 50_000);
  const recoveryEnvelope = await encryptVaultKeyEnvelope(recoveryKey, vaultKey);

  // Recover vault key using recovery words
  const recoveryKey2 = await deriveKeyFromRecoveryWords(words, recoverySaltHex, 50_000);
  const recoveredVaultKey = await decryptVaultKeyEnvelope(
    recoveryKey2,
    recoveryEnvelope.ciphertextHex,
    recoveryEnvelope.nonceHex,
    recoveryEnvelope.tagHex,
  );

  const recoveredVaultHex = await exportRawKeyHex(recoveredVaultKey);
  assert.equal(recoveredVaultHex, originalVaultHex, 'Recovered vault key must match original');

  // Wrong recovery phrase fails
  const otherWords = [...words];
  otherWords[0] = otherWords[0] === 'abandon' ? 'ability' : 'abandon';
  const wrongRecoveryKey = await deriveKeyFromRecoveryWords(otherWords, recoverySaltHex, 50_000);
  await assert.rejects(async () => {
    await decryptVaultKeyEnvelope(
      wrongRecoveryKey,
      recoveryEnvelope.ciphertextHex,
      recoveryEnvelope.nonceHex,
      recoveryEnvelope.tagHex,
    );
  });
});

// -----------------------------------------------------------------------------
// 8. Redux vaultSlice State Management
// -----------------------------------------------------------------------------

test('vaultSlice transitions between unconfigured, configured, unlocked, and locked', () => {
  let state = vaultReducer(undefined, { type: '@@init' });
  assert.equal(state.isConfigured, false);
  assert.equal(state.isUnlocked, false);
  assert.equal(state.rawVaultKeyHex, null);

  // Configure vault
  state = vaultReducer(state, setVaultConfigured(true));
  assert.equal(state.isConfigured, true);
  assert.equal(state.isUnlocked, false);
  assert.equal(state.rawVaultKeyHex, null);

  // Unlock vault
  const sampleKeyHex = 'a'.repeat(64);
  state = vaultReducer(state, setVaultUnlocked(sampleKeyHex));
  assert.equal(state.isConfigured, true);
  assert.equal(state.isUnlocked, true);
  assert.equal(state.rawVaultKeyHex, sampleKeyHex);

  // Lock vault
  state = vaultReducer(state, lockVault());
  assert.equal(state.isConfigured, true);
  assert.equal(state.isUnlocked, false);
  assert.equal(state.rawVaultKeyHex, null);

  // Reset configured state to false resets unlocked state and key
  state = vaultReducer(state, setVaultUnlocked(sampleKeyHex));
  assert.equal(state.isUnlocked, true);
  state = vaultReducer(state, setVaultConfigured(false));
  assert.equal(state.isConfigured, false);
  assert.equal(state.isUnlocked, false);
  assert.equal(state.rawVaultKeyHex, null);
});

test('store mounts vaultSlice and selectors work correctly', () => {
  const testStore = configureStore({
    reducer: {
      vault: vaultReducer,
    },
  });

  const rootState = testStore.getState();
  assert.ok('vault' in rootState, 'vault slice must be mounted in root store');

  const vault = selectVaultState(rootState);
  assert.equal(selectIsVaultConfigured(rootState), vault.isConfigured);
  assert.equal(selectIsVaultUnlocked(rootState), vault.isUnlocked);
  assert.equal(selectRawVaultKeyHex(rootState), vault.rawVaultKeyHex);

  // Dispatch actions to store
  const sampleKey = 'f'.repeat(64);
  testStore.dispatch(setVaultConfigured(true));
  testStore.dispatch(setVaultUnlocked(sampleKey));

  const updatedState = testStore.getState();
  assert.equal(selectIsVaultConfigured(updatedState), true);
  assert.equal(selectIsVaultUnlocked(updatedState), true);
  assert.equal(selectRawVaultKeyHex(updatedState), sampleKey);

  testStore.dispatch(lockVault());
  const lockedState = testStore.getState();
  assert.equal(selectIsVaultUnlocked(lockedState), false);
  assert.equal(selectRawVaultKeyHex(lockedState), null);
});

