import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import { importRawKeyHex } from '../utils/vaultCrypto.ts';

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

export function readSessionVaultKey(): string | null {
  try {
    const storage = getSessionStorage();
    if (!storage) return null;
    const key = storage.getItem(VAULT_SESSION_KEY);
    if (key && /^[0-9a-fA-F]{64}$/.test(key.trim())) {
      return key.trim().toLowerCase();
    }
  } catch {}
  return null;
}

export function writeSessionVaultKey(rawHex: string): void {
  try {
    const storage = getSessionStorage();
    if (!storage) return;
    storage.setItem(VAULT_SESSION_KEY, rawHex.trim().toLowerCase());
  } catch {}
}

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

export async function importAndValidateCryptoKey(hexKey: string): Promise<CryptoKey> {
  const clean = validateHexVaultKey(hexKey);
  return await importRawKeyHex(clean);
}

export interface VaultState {
  isConfigured: boolean;
  isUnlocked: boolean;
  rawVaultKeyHex: string | null;
  isUnlockModalOpen?: boolean;
}

export function loadInitialVaultState(): VaultState {
  const savedKey = readSessionVaultKey();
  if (savedKey) {
    return {
      isConfigured: true,
      isUnlocked: true,
      rawVaultKeyHex: savedKey,
      isUnlockModalOpen: false,
    };
  }
  return {
    isConfigured: false,
    isUnlocked: false,
    rawVaultKeyHex: null,
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
        state.rawVaultKeyHex = null;
        state.isUnlockModalOpen = false;
        clearSessionVaultKey();
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
        action: PayloadAction<{ rawVaultKeyHex: string; rememberSession?: boolean }>,
      ) {
        const cleanKey = action.payload.rawVaultKeyHex.trim().toLowerCase();
        state.isConfigured = true;
        state.isUnlocked = true;
        state.rawVaultKeyHex = cleanKey;
        state.isUnlockModalOpen = false;
        if (action.payload.rememberSession === true) {
          writeSessionVaultKey(cleanKey);
        } else if (action.payload.rememberSession === false) {
          clearSessionVaultKey();
        }
      },
      prepare(
        payloadOrHex: string | { rawVaultKeyHex: string; rememberSession?: boolean },
        maybeRemember?: boolean,
      ) {
        if (typeof payloadOrHex === 'string') {
          return {
            payload: {
              rawVaultKeyHex: payloadOrHex,
              rememberSession: maybeRemember,
            },
          };
        }
        return {
          payload: {
            rawVaultKeyHex: payloadOrHex.rawVaultKeyHex,
            rememberSession: payloadOrHex.rememberSession,
          },
        };
      },
    },
    importLocalKey: {
      reducer(
        state,
        action: PayloadAction<{ hexKey: string; rememberSession?: boolean }>,
      ) {
        const cleanKey = validateHexVaultKey(action.payload.hexKey);
        state.isConfigured = true;
        state.isUnlocked = true;
        state.rawVaultKeyHex = cleanKey;
        state.isUnlockModalOpen = false;
        if (action.payload.rememberSession) {
          writeSessionVaultKey(cleanKey);
        } else {
          clearSessionVaultKey();
        }
      },
      prepare(
        payloadOrHex: string | { hexKey: string; rememberSession?: boolean },
        maybeRemember?: boolean,
      ) {
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
            rememberSession: Boolean(payloadOrHex.rememberSession),
          },
        };
      },
    },
    hydrateVaultFromSession(state) {
      const savedKey = readSessionVaultKey();
      if (savedKey) {
        state.isConfigured = true;
        state.isUnlocked = true;
        state.rawVaultKeyHex = savedKey;
      }
    },
    lockVault(state) {
      state.isUnlocked = false;
      state.rawVaultKeyHex = null;
      state.isUnlockModalOpen = false;
      clearSessionVaultKey();
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

export const selectVaultState = (state: { vault?: VaultState }) => state?.vault;
export const selectIsVaultConfigured = (state: { vault?: VaultState }) => Boolean(state?.vault?.isConfigured);
export const selectIsVaultUnlocked = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlocked);
export const selectRawVaultKeyHex = (state: { vault?: VaultState }) => state?.vault?.rawVaultKeyHex ?? null;
export const selectIsUnlockModalOpen = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlockModalOpen);

export default vaultSlice.reducer;
