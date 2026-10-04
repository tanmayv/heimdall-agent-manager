// Zero-Knowledge Vault Transformers for Task Chains
// REQ-VAULT-CHAINS-1

import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';

export interface ChainPayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

/**
 * Encrypt chain fields (title, description) if vault is unlocked using rawKeyHex or active CryptoKey.
 */
export async function encryptChainFields<T extends ChainPayload>(
  payload: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, activeKey);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, activeKey);
  }
  return res;
}

/**
 * Decrypt chain fields (title, description, description_preview) using rawKeyHex or active CryptoKey.
 * If vault is locked or key is not provided, leaves armored strings as-is (graceful fallback).
 */
export async function decryptChainRecord<T extends ChainPayload>(
  chain: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return chain;
  let title = chain.title;
  let description = chain.description;
  let descriptionPreview = (chain as any).descriptionPreview || (chain as any).description_preview;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, activeKey);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, activeKey);
    } catch {}
  }
  if (descriptionPreview && isVaultArmored(descriptionPreview)) {
    try {
      descriptionPreview = await decryptVaultText(descriptionPreview, activeKey);
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
  rawKeyHex?: string | CryptoKey | null,
): Promise<T[]> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !Array.isArray(chains)) return chains;
  return Promise.all(chains.map((chain) => decryptChainRecord(chain, activeKey)));
}
