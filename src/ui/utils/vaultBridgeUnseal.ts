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

/** Discriminator for `VaultKeyNotExportableError`, stable across module instances. */
export const VAULT_KEY_NOT_EXPORTABLE = 'vault_key_not_exportable';

/**
 * A bridge unseal was asked to wrap a `CryptoKey` whose raw bytes cannot be read.
 *
 * This is the EXPECTED outcome for a hardened key (REQ-VAULT-HARDEN-1) and for any
 * key restored from IndexedDB, not a malfunction -- the unseal protocol has to
 * transmit the master key itself, so a handle that cannot yield its bytes is simply
 * not usable key material. The caller's job is to obtain the key from the operator
 * and pass it in; it must never degrade to a weaker payload (REQ-UNSEAL-4).
 *
 * `code` is checked rather than `instanceof` because callers reach this module
 * through a dynamic `import()` and must not depend on sharing one class identity.
 */
export class VaultKeyNotExportableError extends Error {
  readonly code = VAULT_KEY_NOT_EXPORTABLE;

  constructor() {
    super(
      'This browser holds the vault key as a non-extractable handle, which cannot be wrapped for a bridge. ' +
        'Re-enter your master password to unseal this bridge.',
    );
    this.name = 'VaultKeyNotExportableError';
  }
}

/** True when `err` is the not-exportable signal, across module instances. */
export function isVaultKeyNotExportableError(err: unknown): boolean {
  return Boolean(err) && (err as { code?: string }).code === VAULT_KEY_NOT_EXPORTABLE;
}

/**
 * What a completed unseal attempt actually did, as opposed to what the operator was
 * about to be told it did.
 *
 * REQ-UNSEAL-4/5: the UI must never report an unseal that did not happen. The case
 * that makes this worth a function rather than a chain of ternaries inline in the
 * panel is `targeted-bridge-missing`: the operator answers the password prompt raised
 * by ONE bridge row, and in the time they were typing that bridge left the list (the
 * poll refreshes it). Nothing is then attempted and nothing fails, so a "did anything
 * fail?" test sees a clean run and reports success for an unseal that was never built
 * or sent. That is a silent skip, which REQ-UNSEAL-4 forbids, so it is its own outcome
 * and the caller must say so explicitly.
 *
 * Lives here, not in the panel, for two reasons: it is unseal semantics rather than
 * presentation, and `node --test` cannot load `.tsx`, so a decision kept inline in the
 * component is a decision that cannot be tested at all.
 */
export type UnsealOutcome =
  /** The row the prompt was raised for is gone; nothing was attempted. */
  | { kind: 'targeted-bridge-missing' }
  /** At least one bridge took the payload. `count` is how many. */
  | { kind: 'unsealed'; count: number }
  /** Nothing succeeded and at least one bridge failed; the failures are reported. */
  | { kind: 'failed' }
  /** Nothing was targeted and nothing failed -- the vault is unlocked, nothing was sent. */
  | { kind: 'dispatched' };

export function resolveUnsealOutcome(args: {
  /** The bridge row that raised the prompt, or null when it came from the bulk control. */
  pendingUnsealBridgeId: string | null;
  /** Whether that bridge is still present in the list at submit time. */
  pendingBridgeFound: boolean;
  unsealedCount: number;
  failedCount: number;
}): UnsealOutcome {
  if (args.pendingUnsealBridgeId && !args.pendingBridgeFound) {
    return { kind: 'targeted-bridge-missing' };
  }
  if (args.unsealedCount > 0) return { kind: 'unsealed', count: args.unsealedCount };
  if (args.failedCount > 0) return { kind: 'failed' };
  return { kind: 'dispatched' };
}

/**
 * Whether `vaultKey` can actually produce the bytes an unseal payload needs.
 *
 * Callers use this to decide whether to prompt the operator BEFORE starting any
 * network work, so the rule lives here next to the code that enforces it rather
 * than being re-derived (and drifting) in each UI surface.
 */
export function canUnsealWithKey(vaultKey: string | CryptoKey | Uint8Array | null | undefined): boolean {
  if (!vaultKey) return false;
  if (typeof vaultKey === 'string') return vaultKey.trim().length > 0;
  if (vaultKey instanceof Uint8Array) return vaultKey.length > 0;
  return vaultKey.extractable === true;
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

  // REQ-UNSEAL-1, REQ-UNSEAL-4: the bytes come from the `vaultKey` the caller passed
  // and from nowhere else.
  //
  // This block used to be `try { exportKey } catch { module-level hex cache }`. For a
  // non-extractable key -- which is the hardened default (REQ-VAULT-HARDEN-1) -- the
  // `catch` was the NORMAL path, so a thrown DOMException was load-bearing control
  // flow and the real key source was a global that some unrelated earlier call site
  // may or may not have populated. That is what made unseal succeed in the session
  // where the operator typed the key and fail after a reload, with no difference in
  // the call itself. The fallback is deleted: both paths now reach these bytes the
  // same way, and `extractable` is read directly instead of being probed by
  // exception.
  let plaintextBytes: Uint8Array;
  if (typeof vaultKey === 'string') {
    plaintextBytes = new TextEncoder().encode(vaultKey.trim());
  } else if (vaultKey instanceof Uint8Array) {
    plaintextBytes = vaultKey;
  } else if (!vaultKey.extractable) {
    // Loud and specific, never a weaker payload: there is no key material to wrap, so
    // the caller must obtain it from the operator. Callers branch on `code`.
    throw new VaultKeyNotExportableError();
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
