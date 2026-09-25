// Zero-Knowledge Vault Transformers for Projects
// REQ-VAULT-PROJECTS-1

import { isVaultArmored, encryptVaultText, decryptVaultText } from './vaultContent.ts';

export interface ProjectPayload {
  name?: string;
  description?: string;
  [key: string]: any;
}

/**
 * Encrypt project fields (name, description) if vault is unlocked using rawKeyHex.
 */
export async function encryptProjectFields<T extends ProjectPayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return { ...payload };
  const res = { ...payload };
  if (res.name && !isVaultArmored(res.name)) {
    res.name = await encryptVaultText(res.name, rawKeyHex);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, rawKeyHex);
  }
  return res;
}

/**
 * Decrypt project fields (name, description) using rawKeyHex.
 * If vault is locked or key is not provided, leaves armored strings as-is (graceful fallback).
 */
export async function decryptProjectRecord<T extends ProjectPayload>(
  project: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return project;
  let name = project.name;
  let description = project.description;

  if (name && isVaultArmored(name)) {
    try {
      name = await decryptVaultText(name, rawKeyHex);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, rawKeyHex);
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
  rawKeyHex?: string | null,
): Promise<T[]> {
  if (!rawKeyHex || !Array.isArray(projects)) return projects;
  return Promise.all(projects.map((project) => decryptProjectRecord(project, rawKeyHex)));
}
