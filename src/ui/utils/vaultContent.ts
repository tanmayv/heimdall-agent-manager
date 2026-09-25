// Zero-Knowledge Vault Content Cryptography & Declarative Transformers
// Implements armored envelope wire format 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>',
// transparent unarmored fallback, and declarative field/list transformers.
// REQ-VAULT-CONTENT-LIB-1

import {
  importRawKeyHex,
  AES_GCM_NONCE_BYTES,
  AES_GCM_TAG_BYTES,
} from './vaultCrypto.ts';

export const VAULT_ARMOR_PREFIX = 'vault:v1:';
export const MIN_ARMOR_PAYLOAD_BYTES = AES_GCM_NONCE_BYTES + AES_GCM_TAG_BYTES; // 28 bytes

/**
 * Check if a string is armored with the vault content encryption prefix.
 */
export function isVaultArmored(text: unknown): boolean {
  return typeof text === 'string' && text.startsWith(VAULT_ARMOR_PREFIX);
}

/**
 * Validate standard base64 string syntax.
 */
export function isValidBase64(str: string): boolean {
  if (!str || str.length % 4 !== 0) return false;
  return /^[A-Za-z0-9+/]+={0,2}$/.test(str);
}

/**
 * Convert Uint8Array to base64 string across browser and Node.js environments.
 */
export function bytesToBase64(bytes: Uint8Array): string {
  if (typeof Buffer !== 'undefined') {
    return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64');
  }
  let binary = '';
  const chunkSize = 8192;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
    binary += String.fromCharCode.apply(null, Array.from(chunk));
  }
  return btoa(binary);
}

/**
 * Convert base64 string to Uint8Array across browser and Node.js environments.
 */
export function base64ToBytes(base64: string): Uint8Array {
  if (typeof Buffer !== 'undefined') {
    const buf = Buffer.from(base64, 'base64');
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  }
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/**
 * Resolve a hex string or CryptoKey into a WebCrypto CryptoKey instance.
 */
export async function resolveCryptoKey(key: string | CryptoKey): Promise<CryptoKey> {
  if (typeof key === 'string') {
    return await importRawKeyHex(key);
  }
  if (!key || typeof key !== 'object') {
    throw new Error('Invalid vault key: expected a 64-character hex string or CryptoKey instance');
  }
  return key;
}

/**
 * Encrypt plaintext using 256-bit AES-GCM and return self-describing armored string:
 * 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>'
 *
 * @param plaintext The plaintext string to encrypt.
 * @param rawKeyHex The 256-bit vault key as a 64-character hex string or CryptoKey.
 */
export async function encryptVaultText(
  plaintext: string,
  rawKeyHex: string | CryptoKey,
): Promise<string> {
  const cryptoKey = await resolveCryptoKey(rawKeyHex);
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));

  const enc = new TextEncoder();
  const plaintextBytes = enc.encode(plaintext);

  // WebCrypto AES-GCM outputs ciphertext with the 16-byte authentication tag appended at the end
  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
    cryptoKey,
    plaintextBytes as unknown as BufferSource,
  );

  const encryptedBytes = new Uint8Array(encrypted);
  const ciphertextLen = encryptedBytes.length - AES_GCM_TAG_BYTES;
  const ciphertextBytes = encryptedBytes.subarray(0, ciphertextLen);
  const tagBytes = encryptedBytes.subarray(ciphertextLen);

  // Wire format: 12B nonce + 16B tag + ciphertext
  const payload = new Uint8Array(MIN_ARMOR_PAYLOAD_BYTES + ciphertextLen);
  payload.set(nonce, 0);
  payload.set(tagBytes, AES_GCM_NONCE_BYTES);
  payload.set(ciphertextBytes, MIN_ARMOR_PAYLOAD_BYTES);

  return `${VAULT_ARMOR_PREFIX}${bytesToBase64(payload)}`;
}

/**
 * Decrypt a vault armored string. If input is not armored with 'vault:v1:',
 * returns the original input string as-is without throwing errors (transparent fallback).
 *
 * @param armored The potentially armored string.
 * @param rawKeyHex The 256-bit vault key as a 64-character hex string or CryptoKey.
 */
export async function decryptVaultText(
  armored: string,
  rawKeyHex: string | CryptoKey,
): Promise<string> {
  if (!isVaultArmored(armored)) {
    return armored;
  }

  const b64 = armored.slice(VAULT_ARMOR_PREFIX.length).trim();
  if (!isValidBase64(b64)) {
    throw new Error('Invalid vault armored ciphertext: malformed base64 payload');
  }

  const payload = base64ToBytes(b64);
  if (payload.length < MIN_ARMOR_PAYLOAD_BYTES) {
    throw new Error(
      `Invalid vault armored ciphertext: payload length (${payload.length} bytes) is less than header (${MIN_ARMOR_PAYLOAD_BYTES} bytes)`,
    );
  }

  const nonce = payload.subarray(0, AES_GCM_NONCE_BYTES);
  const tag = payload.subarray(AES_GCM_NONCE_BYTES, MIN_ARMOR_PAYLOAD_BYTES);
  const ciphertext = payload.subarray(MIN_ARMOR_PAYLOAD_BYTES);

  // Recombine ciphertext and auth tag for WebCrypto AES-GCM decrypt (ciphertext || tag)
  const combined = new Uint8Array(ciphertext.length + tag.length);
  combined.set(ciphertext, 0);
  combined.set(tag, ciphertext.length);

  const cryptoKey = await resolveCryptoKey(rawKeyHex);
  const decryptedRaw = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
    cryptoKey,
    combined as unknown as BufferSource,
  );

  const dec = new TextDecoder();
  return dec.decode(decryptedRaw);
}

/**
 * Declarative object transformer: encrypts specified string fields of an object in-place or clone.
 * Unencrypted/non-targeted fields and already-armored fields are preserved intact.
 *
 * @param data Target object.
 * @param fields List of keys to encrypt.
 * @param key The vault key as a 64-char hex string or CryptoKey.
 */
export async function encryptFields<T>(
  data: T,
  fields: (keyof T)[],
  key: string | CryptoKey,
): Promise<T> {
  if (data == null || typeof data !== 'object') {
    return data;
  }

  const cryptoKey = await resolveCryptoKey(key);
  const result = (Array.isArray(data) ? [...data] : { ...data }) as T;

  for (const field of fields) {
    const val = (result as Record<string, unknown>)[field as string];
    if (typeof val === 'string' && !isVaultArmored(val)) {
      (result as Record<string, unknown>)[field as string] = await encryptVaultText(val, cryptoKey);
    }
  }

  return result;
}

/**
 * Declarative object transformer: decrypts specified string fields of an object.
 * Non-targeted fields and unarmored fields are preserved intact (transparent fallback).
 *
 * @param data Target object.
 * @param fields List of keys to decrypt.
 * @param key The vault key as a 64-char hex string or CryptoKey.
 */
export async function decryptFields<T>(
  data: T,
  fields: (keyof T)[],
  key: string | CryptoKey,
): Promise<T> {
  if (data == null || typeof data !== 'object') {
    return data;
  }

  const cryptoKey = await resolveCryptoKey(key);
  const result = (Array.isArray(data) ? [...data] : { ...data }) as T;

  for (const field of fields) {
    const val = (result as Record<string, unknown>)[field as string];
    if (typeof val === 'string' && isVaultArmored(val)) {
      (result as Record<string, unknown>)[field as string] = await decryptVaultText(val, cryptoKey);
    }
  }

  return result;
}

/**
 * Declarative array transformer: decrypts specified string fields for each object in an array.
 *
 * @param items Array of target objects.
 * @param fields List of keys to decrypt on each item.
 * @param key The vault key as a 64-char hex string or CryptoKey.
 */
export async function decryptList<T>(
  items: T[],
  fields: (keyof T)[],
  key: string | CryptoKey,
): Promise<T[]> {
  if (!Array.isArray(items)) {
    return [];
  }
  const cryptoKey = await resolveCryptoKey(key);
  return await Promise.all(items.map((item) => decryptFields(item, fields, cryptoKey)));
}

/**
 * Declarative array transformer: encrypts specified string fields for each object in an array.
 *
 * @param items Array of target objects.
 * @param fields List of keys to encrypt on each item.
 * @param key The vault key as a 64-char hex string or CryptoKey.
 */
export async function encryptList<T>(
  items: T[],
  fields: (keyof T)[],
  key: string | CryptoKey,
): Promise<T[]> {
  if (!Array.isArray(items)) {
    return [];
  }
  const cryptoKey = await resolveCryptoKey(key);
  return await Promise.all(items.map((item) => encryptFields(item, fields, cryptoKey)));
}
