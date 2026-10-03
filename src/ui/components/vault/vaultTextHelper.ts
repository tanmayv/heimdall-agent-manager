import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  decryptList,
} from '../../utils/vaultContent.ts';

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

export interface DecryptedMarkdownResolved {
  text: string;
  isArmored: boolean;
  isLocked: boolean;
}

/**
 * Pure helper function to resolve DecryptedMarkdown content reactively.
 */
export async function resolveDecryptedMarkdownContent(
  source: string | null | undefined,
  rawKeyHex: string | null | undefined,
  isUnlocked: boolean,
  fallback = '',
): Promise<DecryptedMarkdownResolved> {
  const raw = source ?? '';
  const isArmored = isVaultArmored(raw);
  const isEmbedded = !isArmored && containsVaultArmored(raw);
  const hasVault = isArmored || isEmbedded;

  if (!hasVault) {
    return {
      text: raw || fallback,
      isArmored: false,
      isLocked: false,
    };
  }

  if (!isUnlocked || !rawKeyHex) {
    return {
      text: raw.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]'),
      isArmored: true,
      isLocked: true,
    };
  }

  const decrypted = isArmored
    ? await decryptVaultText(raw, rawKeyHex)
    : await decryptEmbeddedVaultTokens(raw, rawKeyHex);

  return {
    text: decrypted.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]'),
    isArmored: true,
    isLocked: false,
  };
}

export {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  decryptList,
};
