// Opens fetched artifact content bytes for display. The hub holds no vault key and serves
// an encrypted artifact's stored `vault:v2:` token as the body (with the artifact's own
// Content-Type, e.g. image/png), so every reader must decrypt before making an object URL.
// Shared by useArtifactContentState (ArtifactViewer) and useArtifactPreview (thumbnails,
// review-card screenshots, chat and comment attachments).

import {
  VAULT_ARMOR_PREFIX,
  VAULT_LOCKED_MARKER,
  VAULT_OTHER_VAULT_MARKER,
  containsVaultArmored,
  decryptVaultBytes,
  isVaultArmored,
  type VaultKeyring,
} from './vaultCrypto.ts';

export type ArtifactLockReason = '' | 'locked' | 'other_vault';

export type OpenedArtifactContent = {
  /** The decrypted content (binary-exact), or the fetched payload when it is not armored or could not be opened. */
  blob: Blob;
  /** The payload is vault-armored and could not be opened: `blob` is ciphertext and must not be displayed. */
  locked: boolean;
  /** Why `locked` is set: no key for the payload's epoch (vault locked), or it was sealed by another vault. */
  lockReason: ArtifactLockReason;
};

/**
 * Decrypt a fetched artifact body with `keyring` (null when the vault is locked).
 * Only a payload starting with the armor prefix is read as text; unencrypted binaries
 * pass through untouched. Decryption is byte-exact (decryptVaultBytes, never TextDecoder),
 * so images and ZIP bundles survive (REQ-BUNDLE-4). A token that fails to authenticate
 * reports `locked` rather than throwing.
 */
export async function openArtifactContentBlob(blob: Blob, keyring: VaultKeyring | null): Promise<OpenedArtifactContent> {
  const head = await blob.slice(0, VAULT_ARMOR_PREFIX.length).text();
  const rawText = head === VAULT_ARMOR_PREFIX ? await blob.text() : '';
  if (!rawText || !isVaultArmored(rawText)) return { blob, locked: false, lockReason: '' };
  if (!keyring) return { blob, locked: true, lockReason: 'locked' };
  try {
    const opened = await decryptVaultBytes(rawText, keyring);
    if (opened.status === 'ok') {
      const plain = new Blob([opened.bytes as unknown as BlobPart], { type: blob.type || 'application/octet-stream' });
      opened.bytes.fill(0);
      return { blob: plain, locked: false, lockReason: '' };
    }
    if (opened.status === 'other_vault') return { blob, locked: true, lockReason: 'other_vault' };
  } catch {}
  return { blob, locked: true, lockReason: 'locked' };
}

/**
 * Accessible name for an artifact image: the (already decrypted) name, or `fallback` when
 * the name is empty or still sealed -- never ciphertext, never a lock marker.
 */
export function safeArtifactAltText(name: string | null | undefined, fallback: string): string {
  const value = String(name ?? '').trim();
  if (!value || containsVaultArmored(value) || value.includes(VAULT_LOCKED_MARKER) || value.includes(VAULT_OTHER_VAULT_MARKER)) return fallback;
  return value;
}
