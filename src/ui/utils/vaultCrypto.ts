// Zero-Knowledge WebCrypto Vault Client Library
// Implements 256-bit AES-GCM vault key generation, PBKDF2 key derivation,
// BIP-39 12-word mnemonic recovery phrase generation, and envelope wrapping/unwrapping.

import { BIP39_WORDS } from './bip39Words.ts';

export const DEFAULT_KDF_ITERATIONS = 100_000;
export const AES_GCM_KEY_LENGTH = 256;
export const AES_GCM_NONCE_BYTES = 12;
export const AES_GCM_TAG_BYTES = 16;
export const VAULT_KEY_BYTES = 32;
export const RECOVERY_ENTROPY_BYTES = 16;

/** Convert Uint8Array to lowercase hex string */
export function bytesToHex(bytes: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, '0');
  }
  return hex;
}

/** Convert hex string to Uint8Array */
export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim().toLowerCase();
  if (clean.length % 2 !== 0) {
    throw new Error(`Hex string must have an even length, got length ${clean.length}`);
  }
  if (!/^[0-9a-f]*$/.test(clean)) {
    throw new Error(`Invalid hex character in string: ${hex}`);
  }
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2) {
    bytes[i / 2] = parseInt(clean.substring(i, i + 2), 16);
  }
  return bytes;
}

/** Generate cryptographically random salt in hex format (default 16 bytes = 32 hex chars) */
export function generateSaltHex(byteLength = 16): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return bytesToHex(bytes);
}

/** Generate cryptographically random AES-GCM nonce in hex format (default 12 bytes = 24 hex chars) */
export function generateNonceHex(byteLength = AES_GCM_NONCE_BYTES): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return bytesToHex(bytes);
}

/**
 * Pure synchronous SHA-256 implementation for 16-byte entropy checksums.
 * Ensures generate12RecoveryWords() can return synchronously without async Promise overhead.
 */
function sha256Sync(bytes: Uint8Array): Uint8Array {
  const K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const H = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  const l = bytes.length;
  const bitLen = l * 8;
  const withPad = new Uint8Array(((l + 8 + 64) >> 6) << 6);
  withPad.set(bytes);
  withPad[l] = 0x80;
  const view = new DataView(withPad.buffer);
  view.setUint32(withPad.length - 4, bitLen, false);

  const W = new Int32Array(64);
  const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));

  for (let i = 0; i < withPad.length; i += 64) {
    for (let t = 0; t < 16; t++) {
      W[t] = view.getUint32(i + t * 4, false);
    }
    for (let t = 16; t < 64; t++) {
      const s0 = rotr(W[t - 15], 7) ^ rotr(W[t - 15], 18) ^ (W[t - 15] >>> 3);
      const s1 = rotr(W[t - 2], 17) ^ rotr(W[t - 2], 19) ^ (W[t - 2] >>> 10);
      W[t] = (W[t - 16] + s0 + W[t - 7] + s1) | 0;
    }
    let [a, b, c, d, e, f, g, h] = H;
    for (let t = 0; t < 64; t++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + K[t] + W[t]) | 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) | 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) | 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) | 0;
    }
    H[0] = (H[0] + a) | 0;
    H[1] = (H[1] + b) | 0;
    H[2] = (H[2] + c) | 0;
    H[3] = (H[3] + d) | 0;
    H[4] = (H[4] + e) | 0;
    H[5] = (H[5] + f) | 0;
    H[6] = (H[6] + g) | 0;
    H[7] = (H[7] + h) | 0;
  }

  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) {
    outView.setUint32(i * 4, H[i], false);
  }
  return out;
}

const wordToBip39IndexMap = new Map<string, number>();
BIP39_WORDS.forEach((word, idx) => {
  wordToBip39IndexMap.set(word, idx);
});

/**
 * Generate a new 256-bit symmetric AES-GCM Vault Key (KV).
 */
export async function generateVaultKey(): Promise<CryptoKey> {
  return await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
    true,
    ['encrypt', 'decrypt'],
  );
}

/**
 * Export raw key bytes as a 64-character lowercase hex string.
 */
export async function exportRawKeyHex(key: CryptoKey): Promise<string> {
  const raw = await crypto.subtle.exportKey('raw', key);
  return bytesToHex(new Uint8Array(raw));
}

/**
 * Import a 256-bit AES-GCM key from a 64-character hex string.
 */
export async function importRawKeyHex(hex: string): Promise<CryptoKey> {
  const bytes = hexToBytes(hex);
  if (bytes.length !== VAULT_KEY_BYTES) {
    throw new Error(
      `Invalid vault key length: expected ${VAULT_KEY_BYTES} bytes (64 hex characters), got ${bytes.length} bytes`,
    );
  }
  return await crypto.subtle.importKey(
    'raw',
    bytes as unknown as BufferSource,
    { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
    true,
    ['encrypt', 'decrypt'],
  );
}

/**
 * Derive a 256-bit AES-GCM key from a master password using PBKDF2-SHA256.
 *
 * @param password The master password string.
 * @param saltHex The salt as a hex string (at least 16 bytes recommended).
 * @param iterations The PBKDF2 iteration count (defaults to 100,000).
 */
export async function deriveKeyFromPassword(
  password: string,
  saltHex: string,
  iterations: number = DEFAULT_KDF_ITERATIONS,
): Promise<CryptoKey> {
  const enc = new TextEncoder();
  const passwordBytes = enc.encode(password);
  const saltBytes = hexToBytes(saltHex);

  const baseKey = await crypto.subtle.importKey(
    'raw',
    passwordBytes as unknown as BufferSource,
    { name: 'PBKDF2' },
    false,
    ['deriveKey', 'deriveBits'],
  );

  return await crypto.subtle.deriveKey(
    {
      name: 'PBKDF2',
      salt: saltBytes as unknown as BufferSource,
      iterations,
      hash: 'SHA-256',
    },
    baseKey,
    { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
    true,
    ['encrypt', 'decrypt'],
  );
}

/**
 * Generate 12 BIP-39 mnemonic recovery words from 128-bit cryptographically secure entropy.
 *
 * @param entropyBytes Optional 16-byte entropy array (generated with crypto.getRandomValues if omitted).
 * @returns Object with words array (12 words) and entropyHex (32 hex characters).
 */
export function generate12RecoveryWords(entropyBytes?: Uint8Array): {
  words: string[];
  entropyHex: string;
} {
  const entropy = entropyBytes ?? crypto.getRandomValues(new Uint8Array(RECOVERY_ENTROPY_BYTES));
  if (entropy.length !== RECOVERY_ENTROPY_BYTES) {
    throw new Error(`Expected 16 bytes of entropy for 12 BIP-39 words, got ${entropy.length}`);
  }

  const hash = sha256Sync(entropy);
  // High 4 bits of the first byte of SHA-256 hash form the 4-bit checksum
  const checksumBits = (hash[0] >> 4).toString(2).padStart(4, '0');

  let bits = '';
  for (let i = 0; i < entropy.length; i++) {
    bits += entropy[i].toString(2).padStart(8, '0');
  }
  bits += checksumBits; // Total 132 bits

  const words: string[] = [];
  for (let i = 0; i < 12; i++) {
    const chunk = bits.slice(i * 11, (i + 1) * 11);
    const index = parseInt(chunk, 2);
    words.push(BIP39_WORDS[index]);
  }

  return {
    words,
    entropyHex: bytesToHex(entropy),
  };
}

/**
 * Validate that a list of words forms a valid 12-word BIP-39 mnemonic with a matching checksum.
 */
export function validateRecoveryWords(words: string[]): boolean {
  if (!Array.isArray(words) || words.length !== 12) {
    return false;
  }
  let bits = '';
  for (const word of words) {
    const cleanWord = word.trim().toLowerCase();
    const idx = wordToBip39IndexMap.get(cleanWord);
    if (idx === undefined) {
      return false;
    }
    bits += idx.toString(2).padStart(11, '0');
  }

  const entropyBits = bits.slice(0, 128);
  const checksumBits = bits.slice(128, 132);

  const entropyBytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    entropyBytes[i] = parseInt(entropyBits.slice(i * 8, (i + 1) * 8), 2);
  }

  const hash = sha256Sync(entropyBytes);
  const expectedChecksumBits = (hash[0] >> 4).toString(2).padStart(4, '0');
  return checksumBits === expectedChecksumBits;
}

/**
 * Derive a 256-bit AES-GCM recovery key (KR) from 12 recovery words and a recovery salt.
 *
 * @param words The 12 recovery words.
 * @param saltHex The recovery salt as a hex string.
 * @param iterations The PBKDF2 iteration count (defaults to 100,000).
 */
export async function deriveKeyFromRecoveryWords(
  words: string[],
  saltHex: string,
  iterations: number = DEFAULT_KDF_ITERATIONS,
): Promise<CryptoKey> {
  const normalizedPhrase = words.map((w) => w.trim().toLowerCase()).join(' ');
  return await deriveKeyFromPassword(normalizedPhrase, saltHex, iterations);
}

/**
 * Encrypt the raw 256-bit vaultKey using wrappingKey (AES-GCM).
 * Outputs separate hex representations for ciphertext, nonce, and authentication tag.
 *
 * @param wrappingKey The 256-bit AES-GCM wrapping key (KM or KR).
 * @param vaultKey The 256-bit AES-GCM vault key (KV).
 */
export async function encryptVaultKeyEnvelope(
  wrappingKey: CryptoKey,
  vaultKey: CryptoKey,
): Promise<{ ciphertextHex: string; nonceHex: string; tagHex: string }> {
  const rawVaultKey = await crypto.subtle.exportKey('raw', vaultKey);
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));

  // WebCrypto encrypt with AES-GCM appends the 16-byte tag to the ciphertext
  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
    wrappingKey,
    rawVaultKey,
  );

  const encryptedBytes = new Uint8Array(encrypted);
  const ciphertextBytes = encryptedBytes.slice(0, encryptedBytes.length - AES_GCM_TAG_BYTES);
  const tagBytes = encryptedBytes.slice(encryptedBytes.length - AES_GCM_TAG_BYTES);

  return {
    ciphertextHex: bytesToHex(ciphertextBytes),
    nonceHex: bytesToHex(nonce),
    tagHex: bytesToHex(tagBytes),
  };
}

/**
 * Decrypt a vault key envelope using wrappingKey (AES-GCM) and reconstruct the Vault Key (KV).
 *
 * @param wrappingKey The 256-bit AES-GCM wrapping key (KM or KR).
 * @param ciphertextHex The ciphertext in hex format.
 * @param nonceHex The 12-byte nonce in hex format.
 * @param tagHex The 16-byte authentication tag in hex format.
 */
export async function decryptVaultKeyEnvelope(
  wrappingKey: CryptoKey,
  ciphertextHex: string,
  nonceHex: string,
  tagHex: string,
): Promise<CryptoKey> {
  const ciphertextBytes = hexToBytes(ciphertextHex);
  const nonceBytes = hexToBytes(nonceHex);
  const tagBytes = hexToBytes(tagHex);

  // Combine ciphertext and auth tag for WebCrypto AES-GCM decrypt
  const combined = new Uint8Array(ciphertextBytes.length + tagBytes.length);
  combined.set(ciphertextBytes, 0);
  combined.set(tagBytes, ciphertextBytes.length);

  const decryptedRaw = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonceBytes as unknown as BufferSource, tagLength: 128 },
    wrappingKey,
    combined as unknown as BufferSource,
  );

  return await crypto.subtle.importKey(
    'raw',
    decryptedRaw,
    { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
    true,
    ['encrypt', 'decrypt'],
  );
}
