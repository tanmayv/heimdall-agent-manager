// REQ-VAULT-UI-CLIENT-FLOW-1: Tests for Vault Onboarding Modal,
// direct 64-hex key import, session persistence, and AppShell integration.
//
// RUN: node --test tests/ui_vault_onboarding_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  AES_GCM_NONCE_BYTES,
  bytesToHex,
  hexToBytes,
} from '../src/ui/utils/vaultCrypto.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  importLocalKey,
  lockVault,
  hydrateVaultFromSession,
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
  validateHexVaultKey,
  importAndValidateCryptoKey,
  readSessionVaultKey,
  writeSessionVaultKey,
  clearSessionVaultKey,
  readOnboardingDismissed,
  writeOnboardingDismissed,
  loadInitialVaultState,
  VAULT_SESSION_KEY,
  VAULT_ONBOARDING_DISMISSED_KEY,
} from '../src/ui/store/vaultSlice.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// Helper to provide an in-memory sessionStorage mock for Node test environment
function setupMockSessionStorage(): Map<string, string> {
  const store = new Map<string, string>();
  const mockStorage: Storage = {
    length: 0,
    clear: () => {
      store.clear();
      mockStorage.length = 0;
    },
    getItem: (key: string) => store.get(key) ?? null,
    key: (index: number) => Array.from(store.keys())[index] ?? null,
    removeItem: (key: string) => {
      store.delete(key);
      mockStorage.length = store.size;
    },
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
      mockStorage.length = store.size;
    },
  };
  (globalThis as any).sessionStorage = mockStorage;
  return store;
}

// -----------------------------------------------------------------------------
// Test 1: Static verification of AppShell.tsx integration
// -----------------------------------------------------------------------------

test('AppShell.tsx mounts VaultOnboardingModal and BottomDock displays vault-header-status-badge', () => {
  const appShellPath = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
  assert.ok(fs.existsSync(appShellPath), 'AppShell.tsx must exist');

  const content = fs.readFileSync(appShellPath, 'utf8');

  // Verify VaultOnboardingModal import
  assert.match(
    content,
    /import\s+VaultOnboardingModal\s+from\s+['"]\.\.\/settings\/VaultOnboardingModal['"]/,
    'AppShell.tsx must import VaultOnboardingModal',
  );

  // Verify Vault selectors / dismissal import
  assert.match(
    content,
    /selectIsVaultConfigured.*selectIsVaultUnlocked/s,
    'AppShell.tsx must import vault selectors from vaultSlice',
  );

  // Verify status badge in BottomDock.tsx (REQ-BOTTOMDOCK-VAULT-2)
  const bottomDockPath = path.join(REPO_ROOT, 'src/ui/components/shell/BottomDock.tsx');
  assert.ok(fs.existsSync(bottomDockPath), 'BottomDock.tsx must exist');
  const bottomDockContent = fs.readFileSync(bottomDockPath, 'utf8');

  assert.match(
    bottomDockContent,
    /data-debug-id=['"]vault-header-status-badge['"]/,
    'BottomDock.tsx must render header status badge with data-debug-id="vault-header-status-badge"',
  );

  // Verify header displays locked/unlocked status
  assert.match(
    bottomDockContent,
    /Vault:\s*\{isVaultUnlocked\s*\?\s*['"]Unlocked['"]/,
    'BottomDock.tsx header status badge must display Locked/Unlocked/Unconfigured status',
  );

  // Verify VaultOnboardingModal mounting
  assert.match(
    content,
    /<VaultOnboardingModal\s+open=\{isOnboardingModalOpen\}\s+onOpenChange=\{setIsOnboardingModalOpen\}\s*\/>/,
    'AppShell.tsx must mount <VaultOnboardingModal /> globally',
  );

  // Verify automated popup condition on first visit
  assert.match(
    content,
    /readOnboardingDismissed/,
    'AppShell.tsx must check readOnboardingDismissed before auto-opening modal',
  );
});

// -----------------------------------------------------------------------------
// Test 2: Static verification of VaultOnboardingModal.tsx debug IDs and flows
// -----------------------------------------------------------------------------

test('VaultOnboardingModal.tsx implements Setup, Unlock, Direct Key Import, and Skip with required debug IDs', () => {
  const modalPath = path.join(REPO_ROOT, 'src/ui/components/settings/VaultOnboardingModal.tsx');
  assert.ok(fs.existsSync(modalPath), 'VaultOnboardingModal.tsx must exist');

  const content = fs.readFileSync(modalPath, 'utf8');

  const requiredDebugIds = [
    'vault-onboarding-modal',
    'vault-onboarding-tab-setup',
    'vault-onboarding-tab-unlock',
    'vault-onboarding-tab-import',
    'vault-onboarding-setup-form',
    'vault-onboarding-unlock-form',
    'vault-onboarding-import-form',
    'vault-onboarding-master-password-input',
    'vault-onboarding-confirm-password-input',
    'vault-onboarding-recovery-words-grid',
    'vault-onboarding-copy-words-btn',
    'vault-onboarding-regenerate-words-btn',
    'vault-onboarding-setup-backup-checkbox',
    'vault-onboarding-setup-submit-btn',
    'vault-onboarding-unlock-password-input',
    'vault-onboarding-unlock-recovery-input',
    'vault-onboarding-unlock-submit-btn',
    'vault-onboarding-hex-key-input',
    'vault-onboarding-import-btn',
    'vault-onboarding-remember-checkbox',
    'vault-onboarding-skip-btn',
  ];

  for (const debugId of requiredDebugIds) {
    assert.ok(
      content.includes(`data-debug-id="${debugId}"`) || content.includes(`data-debug-id={'${debugId}'}`),
      `VaultOnboardingModal.tsx must include data-debug-id="${debugId}"`,
    );
  }

  // Verify direct import dispatches importLocalKey
  assert.match(
    content,
    /importLocalKey\(clean,\s*rememberSession\)/,
    'VaultOnboardingModal.tsx must dispatch importLocalKey with clean hex and rememberSession',
  );

  // Verify skip button writes dismissal
  assert.match(
    content,
    /writeOnboardingDismissed\(true\)/,
    'VaultOnboardingModal.tsx must persist dismissal via writeOnboardingDismissed(true)',
  );
});

// -----------------------------------------------------------------------------
// Test 3: Functional verification of 64-hex key import, WebCrypto import, & Redux
// -----------------------------------------------------------------------------

test('Direct 64-char hex key import validates, imports CryptoKey, and unlocks Redux vault', async () => {
  setupMockSessionStorage();

  // Generate valid 256-bit AES-GCM vault key and export hex
  const vaultKey = await generateVaultKey();
  const validHexKey = await exportRawKeyHex(vaultKey);
  assert.equal(validHexKey.length, 64);
  assert.match(validHexKey, /^[0-9a-f]{64}$/);

  // 1. Validation test
  assert.equal(validateHexVaultKey(validHexKey), validHexKey);
  assert.equal(validateHexVaultKey(`  ${validHexKey.toUpperCase()}  `), validHexKey);

  // Invalid key lengths or characters must throw
  assert.throws(() => validateHexVaultKey(''), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey('1234abcd'), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey('z'.repeat(64)), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey(validHexKey.slice(0, 63)), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey(validHexKey + '0'), /Invalid vault key/);

  // 2. WebCrypto import validation
  const importedKey = await importAndValidateCryptoKey(validHexKey);
  assert.ok(importedKey instanceof CryptoKey);
  assert.equal(importedKey.algorithm.name, 'AES-GCM');

  // Verify key can encrypt & decrypt correctly
  const plaintext = new TextEncoder().encode('Hello, Heimdall Zero-Knowledge Vault!');
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce },
    importedKey,
    plaintext,
  );
  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce },
    importedKey,
    ciphertext,
  );
  assert.equal(new TextDecoder().decode(decrypted), 'Hello, Heimdall Zero-Knowledge Vault!');

  // 3. Redux reducer importLocalKey action without session persistence
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsVaultConfigured({ vault: state }), false);
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  state = vaultReducer(state, importLocalKey(validHexKey, false));
  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal(selectRawVaultKeyHex({ vault: state }), validHexKey);
  assert.equal(readSessionVaultKey(), null, 'Key must not be in sessionStorage when rememberSession is false');

  // Lock vault
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
});

// -----------------------------------------------------------------------------
// Test 4: Functional verification of session persistence & hydration
// -----------------------------------------------------------------------------

test('Session persistence saves key to sessionStorage and hydrates on initial load', async () => {
  const store = setupMockSessionStorage();

  const vaultKey = await generateVaultKey();
  const hexKey = await exportRawKeyHex(vaultKey);

  // 1. Import with rememberSession = true
  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, importLocalKey(hexKey, true));

  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal(selectRawVaultKeyHex({ vault: state }), hexKey);

  // Verify sessionStorage content
  assert.equal(store.get(VAULT_SESSION_KEY), hexKey);
  assert.equal(readSessionVaultKey(), hexKey);

  // 2. Simulate page reload: loadInitialVaultState() should hydrate unlocked state
  const reloadedInitialState = loadInitialVaultState();
  assert.equal(reloadedInitialState.isConfigured, true);
  assert.equal(reloadedInitialState.isUnlocked, true);
  assert.equal(reloadedInitialState.rawVaultKeyHex, hexKey);

  // 3. hydrateVaultFromSession action test
  let emptyState = {
    isConfigured: false,
    isUnlocked: false,
    rawVaultKeyHex: null,
  };
  emptyState = vaultReducer(emptyState, hydrateVaultFromSession());
  assert.equal(emptyState.isConfigured, true);
  assert.equal(emptyState.isUnlocked, true);
  assert.equal(emptyState.rawVaultKeyHex, hexKey);

  // 4. Locking the vault clears sessionStorage
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
  assert.equal(store.get(VAULT_SESSION_KEY), undefined, 'lockVault must remove key from sessionStorage');
  assert.equal(readSessionVaultKey(), null);

  // 5. Setting vault configured to false also clears sessionStorage
  writeSessionVaultKey(hexKey);
  assert.equal(readSessionVaultKey(), hexKey);
  state = vaultReducer(state, setVaultConfigured(false));
  assert.equal(readSessionVaultKey(), null, 'setVaultConfigured(false) must clear sessionStorage');
});

// -----------------------------------------------------------------------------
// Test 5: Functional verification of onboarding dismissal
// -----------------------------------------------------------------------------

test('Onboarding dismissal flag prevents aggressive re-popping in current session', () => {
  const store = setupMockSessionStorage();

  // Initially not dismissed
  assert.equal(readOnboardingDismissed(), false);

  // Dismiss for session
  writeOnboardingDismissed(true);
  assert.equal(store.get(VAULT_ONBOARDING_DISMISSED_KEY), 'true');
  assert.equal(readOnboardingDismissed(), true);

  // Reset dismissal
  writeOnboardingDismissed(false);
  assert.equal(store.get(VAULT_ONBOARDING_DISMISSED_KEY), undefined);
  assert.equal(readOnboardingDismissed(), false);
});
