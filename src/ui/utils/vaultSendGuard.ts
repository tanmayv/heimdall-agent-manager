// REQ-SWFIX-SEND-1: a message is encrypted only under the CURRENT account's vault key,
// and never falls back to plain text while this account's vault is expected but not ready.

import type { VaultKeyring } from './vaultCrypto.ts';

export const VAULT_UNLOCKING_MESSAGE = 'Vault unlocking… your draft is kept. Try again in a moment.';
export const VAULT_FOREIGN_KEY_MESSAGE = 'The vault belongs to another account. Wait for this account to finish unlocking, then send again.';

export class VaultSendBlockedError extends Error {
  readonly code: 'vault_unlocking' | 'vault_foreign_key';
  constructor(code: 'vault_unlocking' | 'vault_foreign_key') {
    super(code === 'vault_unlocking' ? VAULT_UNLOCKING_MESSAGE : VAULT_FOREIGN_KEY_MESSAGE);
    this.name = 'VaultSendBlockedError';
    this.code = code;
  }
}

export interface VaultSendInputs {
  /** The module-level active keyring (may belong to the previous account). */
  activeKey: Pick<VaultKeyring, 'userId'> | null;
  /** Redux `vault.isUnlocked`. */
  isUnlocked: boolean;
  /** The authenticated account of this context ('' when unknown, e.g. tests). */
  currentUserId: string;
  /** Redux `deviceVault`, when present. */
  deviceVault?: { status?: string; userId?: string } | null;
}

/**
 * `null` when the send may proceed (encrypt when a key is usable, plain text only when
 * no vault is expected), otherwise the reason it must be blocked.
 */
export function vaultSendBlock(input: VaultSendInputs): VaultSendBlockedError | null {
  const { activeKey, isUnlocked, currentUserId, deviceVault } = input;
  if (activeKey && currentUserId && activeKey.userId !== currentUserId) return new VaultSendBlockedError('vault_foreign_key');
  if (activeKey && isUnlocked) return null;
  const status = deviceVault?.status;
  // Unknown slice (tests, bare stores) or a browser that cannot run a vault: unchanged behaviour.
  if (!status || status === 'unsupported') return null;
  return new VaultSendBlockedError('vault_unlocking');
}

/** Redux-state flavour used by the mutations and the composer. */
export function vaultSendBlockFromState(state: any, activeKey: Pick<VaultKeyring, 'userId'> | null, currentUserId: string): VaultSendBlockedError | null {
  return vaultSendBlock({ activeKey, isUnlocked: Boolean(state?.vault?.isUnlocked), currentUserId, deviceVault: state?.deviceVault });
}
