// Zero-Knowledge VaultText Resolver and Helper Logic
// REQ-VAULT-ISSUES-UI-1

import { isVaultArmored, decryptVaultText, decryptList } from '../../utils/vaultContent.ts';

export interface VaultTextModelProps {
  value?: string | null;
  fallback?: string;
  as?: 'span' | 'p' | 'div';
  className?: string;
  onUnlockClick?: () => void;
  title?: string;
}

export type VaultTextMode = 'plaintext' | 'locked' | 'unlocked';

export interface VaultTextResolved {
  mode: VaultTextMode;
  isArmored: boolean;
  displayText: string;
  dataDebugId?: string;
  isLocked: boolean;
}

/**
 * Pure function to resolve VaultText state and placeholder configuration.
 */
export function resolveVaultText(
  value: string | null | undefined,
  isUnlocked: boolean,
  fallback = '',
): VaultTextResolved {
  const raw = value ?? '';
  const armored = isVaultArmored(raw);
  if (!armored) {
    return {
      mode: 'plaintext',
      isArmored: false,
      displayText: raw || fallback,
      isLocked: false,
    };
  }
  if (!isUnlocked) {
    return {
      mode: 'locked',
      isArmored: true,
      displayText: '[🔒 Encrypted content - click to unlock]',
      dataDebugId: 'vault-locked-placeholder',
      isLocked: true,
    };
  }
  return {
    mode: 'unlocked',
    isArmored: true,
    displayText: raw,
    isLocked: false,
  };
}

/**
 * Async decryption helper for vault armored text strings.
 */
export async function decryptVaultTextContent(
  value: string | null | undefined,
  rawKeyHex: string | null | undefined,
  fallback = '',
): Promise<string> {
  const raw = value ?? '';
  if (!isVaultArmored(raw)) return raw || fallback;
  if (!rawKeyHex) return fallback || '[Locked content]';
  return await decryptVaultText(raw, rawKeyHex);
}

export { isVaultArmored, decryptVaultText, decryptList };
