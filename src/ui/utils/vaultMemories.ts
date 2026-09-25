// Zero-Knowledge Vault Transformers for Memories
// REQ-VAULT-MEMORIES-1

import { isVaultArmored, encryptVaultText, decryptVaultText } from './vaultContent.ts';

export interface MemoryPayload {
  title?: string;
  description?: string;
  body?: string;
  evidence?: string;
  [key: string]: any;
}

/**
 * Encrypt memory content fields (title, description, body, evidence) if vault is unlocked using rawKeyHex.
 */
export async function encryptMemoryFields<T extends MemoryPayload>(
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
  if (res.body && !isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, rawKeyHex);
  }
  if (res.evidence && !isVaultArmored(res.evidence)) {
    res.evidence = await encryptVaultText(res.evidence, rawKeyHex);
  }
  return res;
}

/**
 * Decrypt memory content fields (title, description, body, evidence) using rawKeyHex.
 */
export async function decryptMemoryRecord<T extends MemoryPayload>(
  memory: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return memory;
  let title = memory.title;
  let description = memory.description;
  let body = memory.body;
  let evidence = memory.evidence;

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
  if (body && isVaultArmored(body)) {
    try {
      body = await decryptVaultText(body, rawKeyHex);
    } catch {}
  }
  if (evidence && isVaultArmored(evidence)) {
    try {
      evidence = await decryptVaultText(evidence, rawKeyHex);
    } catch {}
  }

  return {
    ...memory,
    title,
    description,
    body,
    evidence,
  };
}
