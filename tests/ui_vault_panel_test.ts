// REQ-VAULT-UI-SETTINGS-1: Tests for Settings VaultPanel component,
// AppShell navigation & routing, and Zero-Knowledge setup/unlock flow.
//
// RUN: node --test tests/ui_vault_panel_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  generateVaultKey,
  exportRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  generateSaltHex,
  DEFAULT_KDF_ITERATIONS,
} from '../src/ui/utils/vaultCrypto.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// -----------------------------------------------------------------------------
// Test 1: Static verification of AppShell.tsx routing and navigation
// -----------------------------------------------------------------------------

test('AppShell.tsx correctly registers /settings/vault in SETTINGS_NAV and wires routing', () => {
  const appShellPath = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
  assert.ok(fs.existsSync(appShellPath), 'AppShell.tsx must exist');

  const content = fs.readFileSync(appShellPath, 'utf8');

  // Verify SETTINGS_NAV includes User Vault
  assert.match(
    content,
    /\{\s*path:\s*['"]\/settings\/vault['"],\s*label:\s*['"]User Vault['"]\s*\}/,
    'SETTINGS_NAV must include { path: "/settings/vault", label: "User Vault" }',
  );

  // Verify VaultPanel import
  assert.match(
    content,
    /import\s+VaultPanel\s+from\s+['"]\.\.\/settings\/VaultPanel['"]/,
    'AppShell.tsx must import VaultPanel',
  );

  // Verify route title
  assert.match(
    content,
    /path\.startsWith\(['"]\/settings\/vault['"]\)/,
    'routeTitle must handle /settings/vault',
  );

  // Verify component rendering
  assert.match(
    content,
    /path === ['"]\/settings\/vault['"]\s*\?\s*\(\s*<VaultPanel\s*\/>/,
    'AppShell must render <VaultPanel /> when path === "/settings/vault"',
  );
});

// -----------------------------------------------------------------------------
// Test 2: Static verification of VaultPanel.tsx design system and debug IDs
// -----------------------------------------------------------------------------

test('VaultPanel.tsx implements Setup Wizard, Unlock dialog, and hex Vault Key viewer with required data-debug-ids', () => {
  const vaultPanelPath = path.join(REPO_ROOT, 'src/ui/components/settings/VaultPanel.tsx');
  assert.ok(fs.existsSync(vaultPanelPath), 'VaultPanel.tsx must exist');

  const content = fs.readFileSync(vaultPanelPath, 'utf8');

  // Required debug IDs
  const requiredDebugIds = [
    'settings-vault-panel',
    'vault-setup-wizard',
    'vault-setup-form',
    'vault-master-password-input',
    'vault-confirm-password-input',
    'vault-recovery-words-grid',
    'vault-copy-words-btn',
    'vault-setup-backup-checkbox',
    'vault-setup-submit-btn',
    'vault-unlock-view',
    'vault-open-unlock-dialog-btn',
    'vault-unlock-modal',
    'vault-unlock-password-input',
    'vault-unlock-password-btn',
    'vault-unlock-recovery-input',
    'vault-unlock-recovery-btn',
    'vault-unlocked-view',
    'vault-status-badge',
    'vault-lock-btn',
    'vault-key-viewer',
    'vault-key-hex-display',
    'vault-key-toggle-visibility-btn',
    'vault-key-copy-btn',
    'vault-bridge-instructions',
    'vault-bridge-cmd-display',
    'vault-bridge-cmd-copy-btn',
  ];

  for (const debugId of requiredDebugIds) {
    assert.ok(
      content.includes(`data-debug-id="${debugId}"`) || content.includes(`data-debug-id={'${debugId}'}`),
      `VaultPanel.tsx must include data-debug-id="${debugId}"`,
    );
  }

  // Verify CLI Bridge setup command template
  assert.match(
    content,
    /ham-ctl vault set-key/,
    'VaultPanel.tsx must include copyable ham-ctl vault set-key command',
  );

  // Verify 12 recovery words grid logic
  assert.match(
    content,
    /generate12RecoveryWords/,
    'VaultPanel.tsx must generate 12 BIP-39 recovery words',
  );

  // Verify WebCrypto envelope derivation & encryption
  assert.match(
    content,
    /encryptVaultKeyEnvelope/,
    'VaultPanel.tsx must encrypt envelopes client-side',
  );
  assert.match(
    content,
    /decryptVaultKeyEnvelope/,
    'VaultPanel.tsx must decrypt envelopes client-side',
  );
});

// -----------------------------------------------------------------------------
// Test 3: Functional verification of Setup Wizard envelope creation & Dual Unlock
// -----------------------------------------------------------------------------

test('End-to-End Vault lifecycle: Setup -> Master Password Unlock -> Recovery Phrase Unlock', async () => {
  // 1. Setup Wizard: generate keys and envelopes
  const password = 'CorrectHorseBatteryStaple123!';
  const { words, entropyHex } = generate12RecoveryWords();
  assert.equal(words.length, 12);
  assert.ok(validateRecoveryWords(words));

  const vaultKey = await generateVaultKey();
  const rawVaultKeyHex = await exportRawKeyHex(vaultKey);
  assert.equal(rawVaultKeyHex.length, 64);

  // Derive Master Wrapping Key (KM)
  const kdfSalt = generateSaltHex(16);
  const km = await deriveKeyFromPassword(password, kdfSalt, DEFAULT_KDF_ITERATIONS);
  const pwEnvelope = await encryptVaultKeyEnvelope(km, vaultKey);

  // Derive Recovery Wrapping Key (KR)
  const recoverySalt = generateSaltHex(16);
  const kr = await deriveKeyFromRecoveryWords(words, recoverySalt, DEFAULT_KDF_ITERATIONS);
  const recoveryEnvelope = await encryptVaultKeyEnvelope(kr, vaultKey);

  // Simulating POST /api/v1/user/vault payload
  const storedVaultRecord = {
    encrypted_vault_key: pwEnvelope.ciphertextHex,
    vault_key_nonce: pwEnvelope.nonceHex,
    vault_key_tag: pwEnvelope.tagHex,
    kdf_algorithm: 'PBKDF2-SHA256',
    kdf_salt: kdfSalt,
    kdf_iterations: DEFAULT_KDF_ITERATIONS,
    recovery_encrypted_vault_key: recoveryEnvelope.ciphertextHex,
    recovery_nonce: recoveryEnvelope.nonceHex,
    recovery_tag: recoveryEnvelope.tagHex,
    recovery_salt: recoverySalt,
  };

  // 2. Unlock with correct Master Password
  const kmUnlock = await deriveKeyFromPassword(
    password,
    storedVaultRecord.kdf_salt,
    storedVaultRecord.kdf_iterations,
  );
  const decryptedVaultKeyPw = await decryptVaultKeyEnvelope(
    kmUnlock,
    storedVaultRecord.encrypted_vault_key,
    storedVaultRecord.vault_key_nonce,
    storedVaultRecord.vault_key_tag,
  );
  const unlockedHexPw = await exportRawKeyHex(decryptedVaultKeyPw);
  assert.equal(unlockedHexPw, rawVaultKeyHex, 'Password unlock must yield identical 256-bit vault key hex');

  // 3. Unlock with wrong Master Password must fail
  const kmWrong = await deriveKeyFromPassword(
    'WrongPassword!',
    storedVaultRecord.kdf_salt,
    storedVaultRecord.kdf_iterations,
  );
  await assert.rejects(
    async () => {
      await decryptVaultKeyEnvelope(
        kmWrong,
        storedVaultRecord.encrypted_vault_key,
        storedVaultRecord.vault_key_nonce,
        storedVaultRecord.vault_key_tag,
      );
    },
    /operation failed|decryption failed|OperationError/i,
    'Decryption with incorrect password must fail',
  );

  // 4. Unlock with 12 Recovery Words
  const krUnlock = await deriveKeyFromRecoveryWords(
    words,
    storedVaultRecord.recovery_salt,
    storedVaultRecord.kdf_iterations,
  );
  const decryptedVaultKeyRec = await decryptVaultKeyEnvelope(
    krUnlock,
    storedVaultRecord.recovery_encrypted_vault_key,
    storedVaultRecord.recovery_nonce,
    storedVaultRecord.recovery_tag,
  );
  const unlockedHexRec = await exportRawKeyHex(decryptedVaultKeyRec);
  assert.equal(unlockedHexRec, rawVaultKeyHex, 'Recovery words unlock must yield identical 256-bit vault key hex');

  // 5. Redux state transitions
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsVaultConfigured({ vault: state }), false);
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // Configure & Unlock
  state = vaultReducer(state, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked(rawVaultKeyHex));
  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal(selectRawVaultKeyHex({ vault: state }), rawVaultKeyHex);

  // Lock
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
});
