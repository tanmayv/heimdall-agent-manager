// REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8:
// Hub-blind E2EE bridge key wrapping and authenticated anti-replay unseal protocol.

import {
  bytesToHex,
  hexToBytes,
  base64ToBytes,
  generateNonceHex,
} from './vaultCrypto.ts';

export interface BridgeUnsealPayload {
  type: 'bridge_unseal';
  command_id?: string;
  bridge_id: string;
  timestamp: number;
  nonce: string;
  client_public_key: string;
  iv: string;
  tag: string;
  ciphertext: string;
}

export interface BridgeUnsealResult {
  type: string;
  command_id: string;
  ok: boolean;
  status?: string;
  error?: string;
}

export interface UnsealOptions {
  timestamp?: number;
  nonce?: string;
  commandId?: string;
}

/**
 * Builds the canonical AAD binding envelope for E2EE unseal requests (REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8).
 * Binds bridge_id, timestamp, and nonce to guarantee anti-replay integrity.
 */
export function buildUnsealAad(bridgeId: string, timestamp: number, nonce: string): Uint8Array {
  return new TextEncoder().encode(`${bridgeId}:${timestamp}:${nonce}`);
}

/**
 * Encrypts and wraps the master vault key for a target bridge using Hub-blind E2EE.
 * Performs ephemeral ECDH key agreement, HKDF-SHA256 key derivation, and AES-256-GCM encryption with AAD binding.
 */
export async function prepareUnsealPayload(
  bridgeId: string,
  bridgePublicKey: string,
  vaultKey: string | CryptoKey | Uint8Array,
  options?: UnsealOptions
): Promise<BridgeUnsealPayload> {
  const cleanPk = bridgePublicKey.trim();
  let bridgePubBytes: Uint8Array;
  if (/^[0-9a-fA-F]{130}$/.test(cleanPk)) {
    bridgePubBytes = hexToBytes(cleanPk);
  } else {
    bridgePubBytes = base64ToBytes(cleanPk);
  }

  if (bridgePubBytes.length !== 65 || bridgePubBytes[0] !== 0x04) {
    throw new Error('Invalid bridge public key: expected 65-byte uncompressed P-256 point starting with 0x04');
  }

  // Import bridge public key into WebCrypto ECDH
  const bridgeCryptoKey = await crypto.subtle.importKey(
    'raw',
    bridgePubBytes as any,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    []
  );

  // Generate ephemeral client keypair (SK_client, PK_client)
  const clientKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits', 'deriveKey']
  );

  // Export client public key to raw bytes (65 bytes)
  const clientPubRaw = await crypto.subtle.exportKey('raw', clientKeyPair.publicKey);
  const clientPublicKeyHex = bytesToHex(new Uint8Array(clientPubRaw));

  // Compute ECDH shared secret bits (256 bits = 32 bytes)
  const sharedSecretBits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: bridgeCryptoKey },
    clientKeyPair.privateKey,
    256
  );

  // HKDF key derivation (RFC 5869 with SHA-256)
  const hkdfKey = await crypto.subtle.importKey(
    'raw',
    sharedSecretBits as any,
    'HKDF',
    false,
    ['deriveKey']
  );

  const aesKey = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32),
      info: new TextEncoder().encode('heimdall-bridge-unseal-v1'),
    },
    hkdfKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt']
  );

  const timestamp = options?.timestamp ?? Date.now();
  const nonce = options?.nonce ?? generateNonceHex(16);
  const commandId = options?.commandId ?? `cmd_unseal_${Date.now()}`;

  const aadBytes = buildUnsealAad(bridgeId, timestamp, nonce);
  const ivBytes = crypto.getRandomValues(new Uint8Array(12));

  let plaintextBytes: Uint8Array;
  if (typeof vaultKey === 'string') {
    plaintextBytes = new TextEncoder().encode(vaultKey.trim());
  } else if (vaultKey instanceof Uint8Array) {
    plaintextBytes = vaultKey;
  } else {
    const raw = await crypto.subtle.exportKey('raw', vaultKey);
    const hexStr = bytesToHex(new Uint8Array(raw));
    plaintextBytes = new TextEncoder().encode(hexStr);
  }

  const encryptedBuf = await crypto.subtle.encrypt(
    {
      name: 'AES-GCM',
      iv: ivBytes as any,
      additionalData: aadBytes as any,
      tagLength: 128,
    },
    aesKey,
    plaintextBytes as any
  );

  const encryptedBytes = new Uint8Array(encryptedBuf);
  const tagBytes = encryptedBytes.slice(encryptedBytes.length - 16);
  const ciphertextBytes = encryptedBytes.slice(0, encryptedBytes.length - 16);

  return {
    type: 'bridge_unseal',
    command_id: commandId,
    bridge_id: bridgeId,
    timestamp,
    nonce,
    client_public_key: clientPublicKeyHex,
    iv: bytesToHex(ivBytes),
    tag: bytesToHex(tagBytes),
    ciphertext: bytesToHex(ciphertextBytes),
  };
}

/**
 * Executes full E2EE bridge unseal workflow from Web UI (REQ-VAULT-HARDEN-3).
 * Wraps vault key with ephemeral ECDH key agreement + AES-256-GCM and dispatches to Bridge via Hub relay.
 */
export async function unsealBridgeE2EE(
  bridgeId: string,
  bridgePublicKey: string,
  vaultKey: string | CryptoKey | Uint8Array,
  dispatchFn: (bridgeId: string, payload: BridgeUnsealPayload) => Promise<BridgeUnsealResult>,
  options?: UnsealOptions
): Promise<BridgeUnsealResult> {
  const payload = await prepareUnsealPayload(bridgeId, bridgePublicKey, vaultKey, options);
  return await dispatchFn(bridgeId, payload);
}
