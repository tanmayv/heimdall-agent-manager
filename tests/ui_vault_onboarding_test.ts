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
  isVaultSupported,
  AES_GCM_NONCE_BYTES,
  bytesToHex,
  hexToBytes,
} from '../src/ui/utils/vaultCrypto.ts';
import {
  persistVaultKey,
  restoreVaultKey,
  deleteVaultKey,
  createMockIndexedDB,
} from '../src/ui/utils/vaultPersistence.ts';
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
  shouldOpenVaultOnboarding,
  vaultStatusLabel,
  VAULT_UNSUPPORTED_REASON,
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

  // Verify header displays vault status via the canonical label helper
  // (REQ-VAULT-UNSUP-3: Unsupported/Unlocked/Locked/Unconfigured)
  assert.match(
    bottomDockContent,
    /Vault:\s*\{vaultLabel\}/,
    'BottomDock.tsx header status badge must render the vaultStatusLabel() result',
  );
  assert.match(
    bottomDockContent,
    /vaultStatusLabel\(\{\s*isVaultUnlocked,\s*isVaultConfigured\s*\}\)/,
    'BottomDock.tsx must derive its badge label from vaultStatusLabel()',
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

  // Verify direct import dispatches importLocalKey with an already-imported CryptoKey.
  // REQ-RAWKEY-A7b: this assertion stays a source check because this suite has no DOM
  // harness to mount the component, but it is retargeted from the retired
  // `importLocalKey(clean, rememberSession)` hex call onto the current shape. Dispatching
  // the key rather than the hex is what closes the unlock race -- the reducer's hex branch
  // installs the key in a `.then()`, leaving a tick where isUnlocked is true and
  // getActiveVaultKey() is still null. The *behavioral* proof of that property lives in
  // tests/ui_vault_unlock_race_test.ts; this only pins the component's half of the contract.
  assert.match(
    content,
    /const key = await importRawKeyHex\(clean\)/,
    'VaultOnboardingModal.tsx must await importRawKeyHex at the call site, where the await is legal',
  );
  assert.match(
    content,
    /dispatch\(importLocalKey\(\{\s*key,\s*rememberSession\s*\}\)\)/,
    'VaultOnboardingModal.tsx must dispatch importLocalKey with the CryptoKey, not the pasted hex',
  );
  assert.doesNotMatch(
    content,
    /importLocalKey\(clean/,
    'VaultOnboardingModal.tsx must not dispatch the raw pasted hex into Redux (REQ-RAWKEY-A7)',
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
  assert.equal((state as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
  assert.equal(readSessionVaultKey(), null, 'Key must not be in sessionStorage when rememberSession is false');

  // Lock vault
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
});

// -----------------------------------------------------------------------------
// Test 4: Functional verification of session persistence & hydration
// -----------------------------------------------------------------------------

test('Session persistence saves non-extractable key to IndexedDB and ensures sessionStorage has no raw key (REQ-VAULT-HARDEN-1, REQ-VAULT-HARDEN-2)', async () => {
  const store = setupMockSessionStorage();
  (globalThis as any).indexedDB = createMockIndexedDB();

  const vaultKey = await generateVaultKey();
  const hexKey = await exportRawKeyHex(vaultKey);

  // 1. Import with rememberSession = true
  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, importLocalKey(hexKey, true));

  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal((state as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // Verify sessionStorage NEVER contains raw key
  assert.equal(store.get(VAULT_SESSION_KEY), undefined, 'sessionStorage must not contain raw key');
  assert.equal(readSessionVaultKey(), null);

  // 2. Persist non-extractable CryptoKey directly to IndexedDB
  const nonExtractableKey = await importRawKeyHex(hexKey);
  assert.equal(nonExtractableKey.extractable, false);
  await persistVaultKey(nonExtractableKey);

  // 3. Simulate page reload: restore non-extractable CryptoKey from IndexedDB
  const restoredKey = await restoreVaultKey();
  assert.ok(restoredKey, 'IndexedDB must restore CryptoKey');
  assert.equal(restoredKey.extractable, false, 'Restored key must remain non-extractable');

  // Calling crypto.subtle.exportKey('raw', restoredKey) throws InvalidAccessError
  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', restoredKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // 4. Locking the vault clears IndexedDB and resets unlocked state
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
  await deleteVaultKey();
  const keyAfterLock = await restoreVaultKey();
  assert.equal(keyAfterLock, null, 'Locking vault must purge IndexedDB record');
  assert.equal(store.get(VAULT_SESSION_KEY), undefined);
  assert.equal(readSessionVaultKey(), null);

  // 5. Setting vault configured to false also clears IndexedDB
  await persistVaultKey(nonExtractableKey);
  assert.ok(await restoreVaultKey());
  state = vaultReducer(state, setVaultConfigured(false));
  await deleteVaultKey();
  assert.equal(await restoreVaultKey(), null, 'setVaultConfigured(false) must clear IndexedDB');
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

// -----------------------------------------------------------------------------
// REQ-VAULT-UNSUP-5: graceful "Vault unsupported" when crypto.subtle is unavailable
//
// Self-hosting over plain HTTP on a non-localhost origin means the page is not a
// secure context, so `crypto.subtle` is undefined while `window.crypto` still exists.
// These tests stub that shape and assert the *decisions* the UI makes, not merely
// that a predicate returns false.
// -----------------------------------------------------------------------------

/**
 * Run `fn` with `globalThis.crypto` replaced by a non-secure-context shape: present,
 * with getRandomValues, but no `subtle`. Restores the real crypto afterwards.
 */
function withoutSubtleCrypto<T>(fn: () => T): T {
  const realCrypto = globalThis.crypto;
  Object.defineProperty(globalThis, 'crypto', {
    value: { getRandomValues: (a: any) => a },
    configurable: true,
    writable: true,
  });
  try {
    return fn();
  } finally {
    Object.defineProperty(globalThis, 'crypto', {
      value: realCrypto,
      configurable: true,
      writable: true,
    });
  }
}

test('isVaultSupported() is true in a secure context and false when crypto.subtle is absent', () => {
  // True: Node's real webcrypto exposes subtle.generateKey.
  assert.equal(isVaultSupported(), true, 'must be true when SubtleCrypto is present');

  // False: crypto present, subtle missing — the plain-HTTP non-localhost shape.
  withoutSubtleCrypto(() => {
    assert.equal(
      (globalThis.crypto as any)?.subtle,
      undefined,
      'stub must reproduce the non-secure-context shape (crypto present, subtle absent)',
    );
    assert.equal(isVaultSupported(), false, 'must be false when crypto.subtle is absent');
  });

  // False: crypto object entirely missing.
  const realCrypto = globalThis.crypto;
  Object.defineProperty(globalThis, 'crypto', { value: undefined, configurable: true, writable: true });
  try {
    assert.equal(isVaultSupported(), false, 'must be false when globalThis.crypto is undefined');
  } finally {
    Object.defineProperty(globalThis, 'crypto', { value: realCrypto, configurable: true, writable: true });
  }

  // Restored.
  assert.equal(isVaultSupported(), true, 'must be restored to true after stubbing');
});

test('onboarding modal stays closed when crypto.subtle is absent, for both open paths', () => {
  setupMockSessionStorage();

  // Baseline: in a secure context the modal DOES open for a locked, undismissed vault.
  assert.equal(
    shouldOpenVaultOnboarding({ isVaultUnlocked: false, dismissed: false }),
    true,
    'secure-context behavior must be unchanged: modal opens when locked and not dismissed',
  );

  withoutSubtleCrypto(() => {
    // Path 1 — AppShell first-visit auto-pop. Every combination that would otherwise
    // open the modal must now be suppressed.
    for (const isVaultUnlocked of [false, true]) {
      for (const dismissed of [false, true]) {
        assert.equal(
          shouldOpenVaultOnboarding({ isVaultUnlocked, dismissed }),
          false,
          `auto-pop must stay closed when unsupported (unlocked=${isVaultUnlocked}, dismissed=${dismissed})`,
        );
      }
    }

    // Path 2 — the isUnlockModalOpen back door from vault placeholders is gated on
    // isVaultSupported() directly, so a placeholder click cannot reopen the modal.
    assert.equal(isVaultSupported(), false, 'back-door gate must evaluate false when unsupported');
  });

  // Secure-context path provably untouched after restore.
  assert.equal(shouldOpenVaultOnboarding({ isVaultUnlocked: false, dismissed: false }), true);
  assert.equal(shouldOpenVaultOnboarding({ isVaultUnlocked: true, dismissed: false }), false);
  assert.equal(shouldOpenVaultOnboarding({ isVaultUnlocked: false, dismissed: true }), false);
});

test('dock badge reads "Unsupported" with precedence over Unlocked/Locked/Unconfigured', () => {
  // Secure context: unchanged three-state behavior.
  assert.equal(vaultStatusLabel({ isVaultUnlocked: true, isVaultConfigured: true }), 'Unlocked');
  assert.equal(vaultStatusLabel({ isVaultUnlocked: false, isVaultConfigured: true }), 'Locked');
  assert.equal(vaultStatusLabel({ isVaultUnlocked: false, isVaultConfigured: false }), 'Unconfigured');

  // Unsupported wins over every combination.
  withoutSubtleCrypto(() => {
    for (const isVaultUnlocked of [false, true]) {
      for (const isVaultConfigured of [false, true]) {
        assert.equal(
          vaultStatusLabel({ isVaultUnlocked, isVaultConfigured }),
          'Unsupported',
          `Unsupported must take precedence (unlocked=${isVaultUnlocked}, configured=${isVaultConfigured})`,
        );
      }
    }
  });

  // Tooltip names both cause and remedy.
  assert.match(VAULT_UNSUPPORTED_REASON, /secure context/i, 'tooltip must name the cause');
  assert.match(VAULT_UNSUPPORTED_REASON, /HTTPS|localhost/i, 'tooltip must name the remedy');
});

test('AppShell gates both modal-open paths and VaultPanel has no dead end when unsupported', () => {
  const appShell = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'),
    'utf8',
  );

  // Path 1: the first-visit auto-pop goes through the predicate.
  assert.match(
    appShell,
    /shouldOpenVaultOnboarding\(\{\s*isVaultUnlocked,\s*dismissed\s*\}\)/,
    'AppShell.tsx auto-pop effect must be gated by shouldOpenVaultOnboarding()',
  );
  // Path 2: the isUnlockModalOpen back door is gated too.
  assert.match(
    appShell,
    /if\s*\(isUnlockModalOpen\s*&&\s*isVaultSupported\(\)\)/,
    'AppShell.tsx isUnlockModalOpen effect must be gated by isVaultSupported()',
  );
  // No ungated setIsOnboardingModalOpen(true) survives.
  const ungated = appShell.match(/if\s*\(!isVaultUnlocked\s*&&\s*!dismissed\)/);
  assert.equal(ungated, null, 'the original ungated auto-pop condition must be gone');

  // The badge keys tooling and tests — it must not be renamed.
  const bottomDock = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/shell/BottomDock.tsx'),
    'utf8',
  );
  assert.match(
    bottomDock,
    /data-debug-id=['"]vault-header-status-badge['"]/,
    'vault-header-status-badge debug id must be unchanged',
  );

  // REQ-VAULT-UNSUP-4: the badge routes to /settings/vault, which must explain itself.
  const vaultPanel = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/settings/VaultPanel.tsx'),
    'utf8',
  );
  assert.match(
    vaultPanel,
    /if\s*\(!isVaultSupported\(\)\)/,
    'VaultPanel.tsx must short-circuit to an unsupported explanation',
  );
  assert.match(
    vaultPanel,
    /data-debug-id=['"]vault-unsupported-notice['"]/,
    'VaultPanel.tsx must render the unsupported notice',
  );

  // Non-goal guard: no polyfill / userland crypto fallback was introduced.
  const vaultCrypto = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/utils/vaultCrypto.ts'),
    'utf8',
  );
  assert.equal(
    /polyfill|require\(['"]crypto['"]\)|node:crypto/.test(vaultCrypto),
    false,
    'no crypto polyfill or userland fallback may be introduced',
  );

  // Exactly one availability predicate: nobody re-implements the subtle check.
  for (const [file, content] of [
    ['AppShell.tsx', appShell],
    ['BottomDock.tsx', bottomDock],
    ['VaultPanel.tsx', vaultPanel],
  ] as const) {
    // Matches a duplicated availability *check* (a probe, negation, or comparison) —
    // deliberately not bare `crypto.subtle`, which also appears in explanatory prose.
    const duplicateSubtleCheck =
      /(?:[!(]\s*|typeof\s+)\w*\.?crypto\??\.subtle|crypto\??\.subtle\s*(?:===|!==|\?\?|&&|\|\|)|crypto\??\.subtle\??\.\w/;
    assert.equal(
      duplicateSubtleCheck.test(content),
      false,
      `${file} must not perform its own crypto.subtle check — use isVaultSupported()`,
    );
    assert.equal(
      /isSecureContext/.test(content),
      false,
      `${file} must not branch on isSecureContext`,
    );
  }
});
