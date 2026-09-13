import assert from 'node:assert/strict';

// The base64url codec pair in the push subscription service is pure (no DOM), so
// we can import the module directly in node. uint8ArrayToBase64Url must be the
// exact inverse of base64UrlToUint8Array — the diagnostics card relies on this
// to compare the browser's active applicationServerKey against the server's
// VAPID key byte-for-byte.
const { uint8ArrayToBase64Url, base64UrlToUint8Array } = await import('../src/ui/services/pushSubscriptionService');

// A canonical 65-byte uncompressed P-256 VAPID public key (unpadded base64url,
// leading 0x04 point prefix -> 87 chars).
const KNOWN_VAPID = 'BCpPdJm-4wgtUnecweYLMFV6n8TpDjNYfaLH7BE2W4Clyu8UOV6DqM3yFzxhhqvQ9Ro_ZImu0_gdQmeMsdb7IEU';

// --- string -> bytes -> string is identity on a real VAPID key -------------
{
  const bytes = base64UrlToUint8Array(KNOWN_VAPID);
  assert.equal(bytes.length, 65, 'uncompressed P-256 point decodes to 65 bytes');
  assert.equal(bytes[0], 0x04, 'uncompressed point starts with the 0x04 prefix');
  const back = uint8ArrayToBase64Url(bytes);
  assert.equal(back, KNOWN_VAPID, 'encode∘decode round-trips to the exact unpadded base64url input');
}

// --- bytes -> string -> bytes is identity + output stays URL-safe/unpadded --
{
  const original = new Uint8Array(65);
  for (let i = 0; i < original.length; i += 1) original[i] = (i * 37 + 5) & 0xff;
  const encoded = uint8ArrayToBase64Url(original);
  assert.ok(!/[+/=]/.test(encoded), 'output uses the URL-safe alphabet and drops padding');
  const decoded = base64UrlToUint8Array(encoded);
  assert.deepEqual(Array.from(decoded), Array.from(original), 'decode∘encode round-trips raw bytes exactly');
}

// --- empty input round-trips to empty --------------------------------------
{
  assert.equal(uint8ArrayToBase64Url(new Uint8Array(0)), '', 'empty bytes -> empty string');
}

console.log('ui_push_subscription_service_test: ok');
