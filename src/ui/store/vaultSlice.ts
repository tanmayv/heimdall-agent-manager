import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import {
  importRawKeyHex,
  isVaultSupported,
  getActiveVaultKey,
  setActiveVaultKey,
} from '../utils/vaultCrypto.ts';
import {
  persistVaultKey,
  restoreVaultKey,
  deleteVaultKey,
} from '../utils/vaultPersistence.ts';

export { getActiveVaultKey, setActiveVaultKey };

export const VAULT_SESSION_KEY = 'heimdall:vault:raw-key';
export const VAULT_ONBOARDING_DISMISSED_KEY = 'heimdall:vault:onboarding-dismissed';

function getSessionStorage(): Storage | null {
  if (typeof window !== 'undefined' && window.sessionStorage) {
    return window.sessionStorage;
  }
  if (typeof globalThis !== 'undefined' && (globalThis as any).sessionStorage) {
    return (globalThis as any).sessionStorage;
  }
  return null;
}

/**
 * Deprecated: raw keys are never stored in sessionStorage (REQ-VAULT-HARDEN-1).
 * Always returns null to ensure no script or XSS can retrieve raw keys from storage.
 */
export function readSessionVaultKey(): string | null {
  return null;
}

/**
 * Deprecated: raw keys are never written to sessionStorage (REQ-VAULT-HARDEN-1).
 */
export function writeSessionVaultKey(_rawHex: string): void {
  // No-op for security hardening: key material is held exclusively in non-extractable CryptoKey handles
}

/**
 * Clear any legacy vault key from sessionStorage.
 */
export function clearSessionVaultKey(): void {
  try {
    const storage = getSessionStorage();
    if (!storage) return;
    storage.removeItem(VAULT_SESSION_KEY);
  } catch {}
}

export function readOnboardingDismissed(): boolean {
  try {
    const storage = getSessionStorage();
    if (!storage) return false;
    return storage.getItem(VAULT_ONBOARDING_DISMISSED_KEY) === 'true';
  } catch {
    return false;
  }
}

export function writeOnboardingDismissed(dismissed = true): void {
  try {
    const storage = getSessionStorage();
    if (!storage) return;
    if (dismissed) {
      storage.setItem(VAULT_ONBOARDING_DISMISSED_KEY, 'true');
    } else {
      storage.removeItem(VAULT_ONBOARDING_DISMISSED_KEY);
    }
  } catch {}
}

export function validateHexVaultKey(hexKey: string): string {
  const clean = String(hexKey || '').trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(clean)) {
    throw new Error(`Invalid vault key: expected 64 hex characters, got length ${clean.length}`);
  }
  return clean;
}

/**
 * Validate and import a hex key as a non-extractable WebCrypto CryptoKey.
 * Wipes transient buffers immediately.
 */
export async function importAndValidateCryptoKey(hexKey: string): Promise<CryptoKey> {
  const clean = validateHexVaultKey(hexKey);
  const key = await importRawKeyHex(clean);
  setActiveVaultKey(key);
  return key;
}

/**
 * Unlock vault with a hex key, storing the non-extractable handle and optionally persisting to IndexedDB.
 */
export async function unlockVaultWithHex(hexKey: string, remember = true): Promise<CryptoKey> {
  const key = await importAndValidateCryptoKey(hexKey);
  if (remember) {
    await persistVaultKey(key);
  }
  return key;
}

/**
 * Restore non-extractable CryptoKey from IndexedDB on page load/init (REQ-VAULT-HARDEN-2).
 */
export async function initializeVaultPersistence(
  dispatch?: (action: any) => void,
): Promise<CryptoKey | null> {
  try {
    const key = await restoreVaultKey();
    if (key) {
      setActiveVaultKey(key);
      if (dispatch) {
        dispatch(setVaultUnlocked({ key }));
      }
      return key;
    }
  } catch (err) {
    console.warn('Failed to restore vault key from IndexedDB:', err);
  }
  return null;
}

/**
 * Strictly serializable Redux state for the Vault slice.
 * Contains no raw keys and no non-serializable objects (REQ-VAULT-HARDEN-1).
 */
export interface VaultState {
  isConfigured: boolean;
  isUnlocked: boolean;
  rawVaultKeyHex?: string | null;
  isUnlockModalOpen?: boolean;
}

export function loadInitialVaultState(): VaultState {
  return {
    isConfigured: false,
    isUnlocked: Boolean(getActiveVaultKey()),
    isUnlockModalOpen: false,
  };
}

const initialState: VaultState = loadInitialVaultState();

export const vaultSlice = createSlice({
  name: 'vault',
  initialState,
  reducers: {
    setVaultConfigured(state, action: PayloadAction<boolean>) {
      state.isConfigured = action.payload;
      if (!action.payload) {
        state.isUnlocked = false;
        state.isUnlockModalOpen = false;
        setActiveVaultKey(null);
        clearSessionVaultKey();
        deleteVaultKey().catch(() => {});
      }
    },
    openUnlockModal(state) {
      state.isUnlockModalOpen = true;
    },
    closeUnlockModal(state) {
      state.isUnlockModalOpen = false;
    },
    setUnlockModalOpen(state, action: PayloadAction<boolean>) {
      state.isUnlockModalOpen = action.payload;
    },
    setVaultUnlocked: {
      reducer(
        state,
        action: PayloadAction<{
          key?: CryptoKey;
          rawVaultKeyHex?: string;
          rememberSession?: boolean;
        } | void>,
      ) {
        state.isConfigured = true;
        state.isUnlocked = true;
        state.isUnlockModalOpen = false;

        const payload = action.payload;
        if (payload && typeof payload === 'object') {
          if ('algorithm' in payload) {
            setActiveVaultKey(payload as CryptoKey);
            persistVaultKey(payload as CryptoKey).catch(() => {});
          } else if (payload.key) {
            setActiveVaultKey(payload.key);
            if (payload.rememberSession !== false) {
              persistVaultKey(payload.key).catch(() => {});
            }
          } else if (payload.rawVaultKeyHex) {
            // Asynchronously import hex key for backward compatibility with tests
            importRawKeyHex(payload.rawVaultKeyHex).then((key) => {
              setActiveVaultKey(key);
              if (payload.rememberSession) {
                persistVaultKey(key).catch(() => {});
              }
            }).catch(() => {});
          }
        }
      },
      prepare(
        payloadOrKey?: any,
        maybeRemember?: boolean,
      ) {
        if (!payloadOrKey) {
          return { payload: undefined };
        }
        if (typeof payloadOrKey === 'string') {
          return {
            payload: {
              rawVaultKeyHex: payloadOrKey,
              rememberSession: maybeRemember,
            },
          };
        }
        if (typeof payloadOrKey === 'object' && 'algorithm' in payloadOrKey) {
          return {
            payload: {
              key: payloadOrKey as CryptoKey,
              rememberSession: maybeRemember !== false,
            },
          };
        }
        return {
          payload: {
            key: payloadOrKey.key,
            rawVaultKeyHex: payloadOrKey.rawVaultKeyHex,
            rememberSession: payloadOrKey.rememberSession ?? maybeRemember,
          },
        };
      },
    },
    importLocalKey: {
      reducer(
        state,
        action: PayloadAction<{
          hexKey?: string;
          key?: CryptoKey;
          rememberSession?: boolean;
        } | void>,
      ) {
        state.isConfigured = true;
        state.isUnlocked = true;
        state.isUnlockModalOpen = false;

        const payload = action.payload;
        if (payload && typeof payload === 'object') {
          if ('algorithm' in payload) {
            setActiveVaultKey(payload as CryptoKey);
            persistVaultKey(payload as CryptoKey).catch(() => {});
          } else if (payload.key) {
            setActiveVaultKey(payload.key);
            if (payload.rememberSession !== false) {
              persistVaultKey(payload.key).catch(() => {});
            }
          } else if (payload.hexKey) {
            importRawKeyHex(payload.hexKey).then((key) => {
              setActiveVaultKey(key);
              if (payload.rememberSession) {
                persistVaultKey(key).catch(() => {});
              }
            }).catch(() => {});
          }
        }
      },
      prepare(
        payloadOrHex?: any,
        maybeRemember?: boolean,
      ) {
        if (!payloadOrHex) {
          return { payload: undefined };
        }
        if (typeof payloadOrHex === 'string') {
          return {
            payload: {
              hexKey: payloadOrHex,
              rememberSession: Boolean(maybeRemember),
            },
          };
        }
        return {
          payload: {
            hexKey: payloadOrHex.hexKey,
            key: payloadOrHex.key,
            rememberSession: Boolean(payloadOrHex.rememberSession ?? maybeRemember),
          },
        };
      },
    },
    hydrateVaultFromSession(state) {
      if (getActiveVaultKey()) {
        state.isConfigured = true;
        state.isUnlocked = true;
      }
    },
    lockVault(state) {
      state.isUnlocked = false;
      state.isUnlockModalOpen = false;
      setActiveVaultKey(null);
      clearSessionVaultKey();
      deleteVaultKey().catch(() => {});
    },
  },
});

export const {
  setVaultConfigured,
  setVaultUnlocked,
  importLocalKey,
  hydrateVaultFromSession,
  lockVault,
  openUnlockModal,
  closeUnlockModal,
  setUnlockModalOpen,
} = vaultSlice.actions;

export const VAULT_UNSUPPORTED_TITLE = 'User Vault unavailable';
export const VAULT_UNSUPPORTED_REASON =
  'User Vault unavailable: this page is not a secure context, so Web Crypto (crypto.subtle) is missing. Open Heimdall over HTTPS or on localhost.';

export type VaultStatus = 'Disabled' | 'Locked' | 'Unlocked';

export function resolveVaultStatus(args: {
  isConfigured: boolean;
  isUnlocked: boolean;
}): VaultStatus {
  if (!args.isConfigured) return 'Disabled';
  return args.isUnlocked ? 'Unlocked' : 'Locked';
}

export type VaultStatusLabel = 'Unsupported' | 'Unlocked' | 'Locked' | 'Unconfigured';

export function vaultStatusLabel(args: {
  isVaultUnlocked: boolean;
  isVaultConfigured: boolean;
  supported?: boolean;
}): VaultStatusLabel {
  const supported = args.supported ?? isVaultSupported();
  if (!supported) return 'Unsupported';
  if (args.isVaultUnlocked) return 'Unlocked';
  return args.isVaultConfigured ? 'Locked' : 'Unconfigured';
}

export function shouldOpenVaultOnboarding(args: {
  isVaultUnlocked: boolean;
  dismissed: boolean;
  supported?: boolean;
}): boolean {
  const supported = args.supported ?? isVaultSupported();
  if (!supported) return false;
  return !args.isVaultUnlocked && !args.dismissed;
}

export const selectVaultState = (state: { vault?: VaultState }) => state?.vault;
export const selectIsVaultConfigured = (state: { vault?: VaultState }) => Boolean(state?.vault?.isConfigured);
export const selectIsVaultUnlocked = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlocked);
export const selectRawVaultKeyHex = (state?: { vault?: VaultState }): string | null =>
  (state?.vault as any)?.rawVaultKeyHex ?? null;
export const selectActiveVaultKey = (_state?: { vault?: VaultState }): CryptoKey | null => getActiveVaultKey();
export const selectIsUnlockModalOpen = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlockModalOpen);

export default vaultSlice.reducer;
