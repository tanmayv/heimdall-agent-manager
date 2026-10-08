// Seals a vault key to a bridge's ephemeral ECDH public key exactly the way the
// approval screen does, and prints the `bridge_unseal` payload as JSON.
//
// WHY THIS EXISTS RATHER THAN A CALL INTO THE UI BUNDLE. REQ-FIX-2's E2E has to
// deliver a REAL vault key through the REAL relay to a REAL bridge; a harness that
// faked the envelope would prove only that the harness and the bridge agree. So
// this mirrors `src/ui/utils/vaultBridgeUnseal.ts:138-264` step for step, on the
// same WebCrypto primitives the browser uses — P-256 ECDH, HKDF-SHA256 with a
// 32-byte zero salt and the info string `heimdall-bridge-unseal-v1`, AES-256-GCM
// with the AAD `<bridge_id>:<timestamp>:<nonce>`.
//
// EVERY ONE OF THOSE PARAMETERS IS LOAD-BEARING and was read off both sides before
// this file was written, because a mismatch in any of them fails as an AEAD tag
// error — which is the SAME symptom as the defect under test
// (unseal_protocol.odin's "AEAD tag verification failed"). A harness bug would
// therefore look exactly like the bug still being present, and a "still broken"
// result would be unfalsifiable. The bridge side is `unseal_protocol.odin:223-227`
// (salt/info) and `:261` (aad1); the UI side is `buildUnsealAad` at
// `vaultBridgeUnseal.ts:130`.
//
// Usage: node req_fix_2_seal.mjs <bridge_id> <bridge_public_key_hex> <vault_key_hex>

import { webcrypto as crypto } from 'node:crypto';

const [bridgeId, bridgePubHex, vaultKeyHex] = process.argv.slice(2);
if (!bridgeId || !bridgePubHex || !vaultKeyHex) {
  console.error('usage: node req_fix_2_seal.mjs <bridge_id> <bridge_public_key_hex> <vault_key_hex>');
  process.exit(2);
}

const hexToBytes = (hex) => {
  const clean = hex.trim();
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new Error(`not hex: ${clean.slice(0, 24)}…`);
  }
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
  return out;
};
const bytesToHex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

const bridgePubBytes = hexToBytes(bridgePubHex);
// Fail loudly on a malformed point. A silent pass here would produce an envelope
// nothing can open, and the test would read that as the defect.
if (bridgePubBytes.length !== 65 || bridgePubBytes[0] !== 0x04) {
  throw new Error(
    `invalid bridge public key: expected a 65-byte uncompressed P-256 point starting 0x04, got ${bridgePubBytes.length} bytes starting 0x${bridgePubBytes[0]?.toString(16)}`,
  );
}

const bridgeCryptoKey = await crypto.subtle.importKey(
  'raw',
  bridgePubBytes,
  { name: 'ECDH', namedCurve: 'P-256' },
  false,
  [],
);

const clientKeyPair = await crypto.subtle.generateKey(
  { name: 'ECDH', namedCurve: 'P-256' },
  true,
  ['deriveBits', 'deriveKey'],
);

const clientPubRaw = await crypto.subtle.exportKey('raw', clientKeyPair.publicKey);
const clientPublicKeyHex = bytesToHex(new Uint8Array(clientPubRaw));

const sharedSecretBits = await crypto.subtle.deriveBits(
  { name: 'ECDH', public: bridgeCryptoKey },
  clientKeyPair.privateKey,
  256,
);

const hkdfKey = await crypto.subtle.importKey('raw', sharedSecretBits, 'HKDF', false, ['deriveKey']);

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
  ['encrypt'],
);

const timestamp = Date.now();
const nonce = bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
const aadBytes = new TextEncoder().encode(`${bridgeId}:${timestamp}:${nonce}`);
const ivBytes = crypto.getRandomValues(new Uint8Array(12));

// The protocol transmits the vault key as its 64-char hex TEXT, not as 32 raw
// bytes — `unseal_protocol.odin` accepts either, but the UI sends hex text and
// this harness must not diverge from the client it stands in for.
const plaintextBytes = new TextEncoder().encode(vaultKeyHex.trim());

const encryptedBuf = await crypto.subtle.encrypt(
  { name: 'AES-GCM', iv: ivBytes, additionalData: aadBytes, tagLength: 128 },
  aesKey,
  plaintextBytes,
);

const encryptedBytes = new Uint8Array(encryptedBuf);
const tagBytes = encryptedBytes.slice(encryptedBytes.length - 16);
const ciphertextBytes = encryptedBytes.slice(0, encryptedBytes.length - 16);

process.stdout.write(
  JSON.stringify({
    type: 'bridge_unseal',
    command_id: `cmd_unseal_${timestamp}`,
    bridge_id: bridgeId,
    timestamp,
    nonce,
    client_public_key: clientPublicKeyHex,
    iv: bytesToHex(ivBytes),
    tag: bytesToHex(tagBytes),
    ciphertext: bytesToHex(ciphertextBytes),
  }),
);
