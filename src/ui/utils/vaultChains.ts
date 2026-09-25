// Zero-Knowledge Vault Transformers for Task Chains
// REQ-VAULT-CHAINS-1

import { isVaultArmored, encryptVaultText, decryptVaultText } from './vaultContent.ts';

export interface ChainPayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

/**
 * Encrypt chain fields (title, description) if vault is unlocked using rawKeyHex.
 */
export async function encryptChainFields<T extends ChainPayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, rawKeyHex);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, rawKeyHex);
  }
  return res;
}

/**
 * Decrypt chain fields (title, description, description_preview) using rawKeyHex.
 * If vault is locked or key is not provided, leaves armored strings as-is (graceful fallback).
 */
export async function decryptChainRecord<T extends ChainPayload>(
  chain: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return chain;
  let title = chain.title;
  let description = chain.description;
  let descriptionPreview = (chain as any).descriptionPreview || (chain as any).description_preview;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, rawKeyHex);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, rawKeyHex);
    } catch {}
  }
  if (descriptionPreview && isVaultArmored(descriptionPreview)) {
    try {
      descriptionPreview = await decryptVaultText(descriptionPreview, rawKeyHex);
    } catch {}
  }

  return {
    ...chain,
    title,
    description,
    descriptionPreview,
    description_preview: descriptionPreview,
  };
}

/**
 * Decrypt an array of chain records.
 */
export async function decryptChainList<T extends ChainPayload>(
  chains: T[],
  rawKeyHex?: string | null,
): Promise<T[]> {
  if (!rawKeyHex || !Array.isArray(chains)) return chains;
  return Promise.all(chains.map((chain) => decryptChainRecord(chain, rawKeyHex)));
}
