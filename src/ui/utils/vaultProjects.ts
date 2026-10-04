// Zero-Knowledge Vault Transformers for Projects
// REQ-VAULT-PROJECTS-1

import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';

export interface ProjectPayload {
  name?: string;
  description?: string;
  [key: string]: any;
}

/**
 * Encrypt project fields (name, description) if vault is unlocked using rawKeyHex or active CryptoKey.
 */
export async function encryptProjectFields<T extends ProjectPayload>(
  payload: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return { ...payload };
  const res = { ...payload };
  if (res.name && !isVaultArmored(res.name)) {
    res.name = await encryptVaultText(res.name, activeKey);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, activeKey);
  }
  return res;
}

/**
 * Decrypt project fields (name, description) using rawKeyHex or active CryptoKey.
 * If vault is locked or key is not provided, leaves armored strings as-is (graceful fallback).
 */
export async function decryptProjectRecord<T extends ProjectPayload>(
  project: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return project;
  let name = project.name;
  let description = project.description;

  if (name && isVaultArmored(name)) {
    try {
      name = await decryptVaultText(name, activeKey);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, activeKey);
    } catch {}
  }

  return {
    ...project,
    name,
    description,
  };
}

/**
 * Decrypt an array of project records.
 */
export async function decryptProjectList<T extends ProjectPayload>(
  projects: T[],
  rawKeyHex?: string | CryptoKey | null,
): Promise<T[]> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !Array.isArray(projects)) return projects;
  return Promise.all(projects.map((project) => decryptProjectRecord(project, activeKey)));
}
