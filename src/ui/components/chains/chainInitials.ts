import { isVaultArmored } from '../../utils/vaultContent.ts';

/**
 * Extracts first letter of first two words, uppercase.
 * If 1 word, first 2 letters uppercase. If single char, 1 letter. If empty/whitespace, "TC".
 * If title is vault-armored ciphertext (starts with vault:v1:), returns 'TC' (neutral fallback) instead of 'VA'.
 */
export function chainAvatarInitials(title: string): string {
  const trimmed = (title || '').trim();
  if (!trimmed) return 'TC';
  if (isVaultArmored(trimmed)) return 'TC';
  const words = trimmed.split(/\s+/).filter(Boolean);
  if (words.length >= 2) {
    return (words[0][0] + words[1][0]).toUpperCase();
  }
  return trimmed.slice(0, 2).toUpperCase();
}

export interface CollapsedChainAvatarModel {
  initials: string;
  isLocked: boolean;
  tooltip: string;
}

/**
 * Resolves avatar display initials, lock status, and tooltip for a pinned chain item.
 */
export function resolveCollapsedPinnedChainAvatar(
  title: string | null | undefined,
  decryptedText: string,
  isLocked: boolean,
): CollapsedChainAvatarModel {
  const isArmored = isVaultArmored(title || '');
  const locked = isArmored && isLocked;
  return {
    initials: locked ? '🔒' : chainAvatarInitials(decryptedText),
    isLocked: locked,
    tooltip: decryptedText || title || 'Untitled chain',
  };
}
