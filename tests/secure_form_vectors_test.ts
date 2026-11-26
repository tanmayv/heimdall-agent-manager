import { strict as assert } from "node:assert";
import { webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const v = JSON.parse(readFileSync(new URL("./fixtures/secure-form-v1.json", import.meta.url), "utf8"));
const { subtle } = webcrypto;
const enc = new TextEncoder();
const hex = (s: string) => Uint8Array.from(Buffer.from(s, "hex"));
const toHex = (b: ArrayBuffer | Uint8Array) => Buffer.from(b instanceof ArrayBuffer ? new Uint8Array(b) : b).toString("hex");
const answerDomain = "heimdall.secure-form.answer.v1";

function frame(...parts: (string | Uint8Array)[]) {
  const encoded = parts.map((part) => typeof part === "string" ? enc.encode(part) : part);
  const result = new Uint8Array(encoded.reduce((size, part) => size + 4 + part.length, 0));
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const part of encoded) {
    view.setUint32(offset, part.length, false);
    result.set(part, offset + 4);
    offset += 4 + part.length;
  }
  return result;
}

function request(r = v.request) {
  return frame("heimdall.secure-form.request.v1", r.owner, r.bridge, r.generation, r.instance, r.task, r.conversation,
    hex(r.request_id), r.deadline, r.script, hex(r.schema_digest),
    hex(r.recipient_key));
}

function answer(a = v.answer) {
  return frame(answerDomain, hex(a.request_digest), a.device, a.directory_sequence, hex(a.directory_head),
    hex(a.sender_key), hex(a.nonce), Uint8Array.from(Buffer.from(a.ciphertext, "base64")));
}

async function signingKey(key: string) {
  return subtle.importKey("raw", hex(key), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
}

const verify = (key: CryptoKey, sig: string, data: Uint8Array<ArrayBuffer>) =>
  subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, hex(sig), data);

test("signed schema and canonical script path bind the request placement", async () => {
  assert.equal(toHex(await subtle.digest("SHA-256", enc.encode(v.schema))), v.request.schema_digest);
  assert.equal(toHex(request()), v.request_transcript);

  const k = await signingKey(v.bridge_public);
  assert.equal(await verify(k, v.request_signature, request()), true);
  for (const key of ["owner", "bridge", "generation", "instance", "task", "conversation", "request_id", "script"]) {
    const changed = key === "request_id" ? "01".repeat(32) : key === "generation" ? "12" : key === "script" ? "/other/login.sh" : "other";
    assert.equal(await verify(k, v.request_signature, request({ ...v.request, [key]: changed })), false, key);
  }
  for (const raw of [v.schema.replace("Sign in", "Sign out"), v.schema.replace('"logo":"heimdall",', "")]) {
    const digest = toHex(await subtle.digest("SHA-256", enc.encode(raw)));
    assert.equal(await verify(k, v.request_signature, request({ ...v.request, schema_digest: digest })), false);
  }

});

test("valid device signature binds the directory and the ciphertext to this request", async () => {
  assert.equal(toHex(answer()), v.answer_transcript);
  const k = await signingKey(v.device_public);
  assert.equal(hex(v.answer.signature).length, 64);
  assert.equal(await verify(k, v.answer.signature, answer()), true);
  assert.equal(await verify(k, "3044" + v.answer.signature, answer()), false);
  for (const [key, value] of Object.entries({
    request_digest: "00".repeat(32), device: "other_device", directory_sequence: "41",
    directory_head: "11".repeat(32), nonce: "01".repeat(12),
  })) {
    assert.equal(await verify(k, v.answer.signature, answer({ ...v.answer, [key]: value })), false, key);
  }
});

test("WebCrypto derives the fixture key and authenticates the original request AAD", async () => {
  const agreement = { name: "ECDH", namedCurve: "P-256" };
  const recipient = await subtle.importKey("jwk", v.recipient_jwk, agreement, false, ["deriveBits"]);
  const sender = await subtle.importKey("raw", hex(v.answer.sender_key), agreement, false, []);
  const shared = await subtle.deriveBits({ name: "ECDH", public: sender }, recipient, 256);
  assert.equal(toHex(shared), v.shared);
  const material = await subtle.importKey("raw", shared, "HKDF", false, ["deriveBits"]);
  const salt = await subtle.digest("SHA-256", request());
  assert.equal(toHex(salt), v.answer.request_digest);
  const key = await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: enc.encode(answerDomain) }, material, 256);
  assert.equal(toHex(key), v.key);
  const aes = await subtle.importKey("raw", key, "AES-GCM", false, ["encrypt", "decrypt"]);
  const params = { name: "AES-GCM", iv: hex(v.answer.nonce), additionalData: salt, tagLength: 128 };
  const ciphertext = await subtle.encrypt(params, aes, enc.encode(v.plaintext));
  assert.equal(Buffer.from(ciphertext).toString("base64"), v.answer.ciphertext);
  assert.equal(new TextDecoder().decode(await subtle.decrypt(params, aes, ciphertext)), v.plaintext);
  const bridge = await signingKey(v.bridge_public);
  const device = await signingKey(v.device_public);
  for (const negative of v.negative) {
    const { name, value, transcript } = negative;
    switch (name) {
      case "stale_generation":
      case "cross_owner": {
        const changed = name === "stale_generation" ? { generation: value } : { owner: value };
        const bytes = request({ ...v.request, ...changed });
        assert.equal(toHex(bytes), transcript, name);
        assert.equal(await verify(bridge, v.request_signature, bytes), false, name);
        break;
      }
      case "stale_directory": {
        const bytes = answer({ ...v.answer, directory_sequence: value });
        assert.equal(toHex(bytes), transcript, name);
        assert.equal(await verify(device, v.answer.signature, bytes), false, name);
        break;
      }
      case "der_signature":
        assert.equal(await verify(device, value, answer()), false, name);
        break;
      case "wrong_aad":
        await assert.rejects(() => subtle.decrypt({ ...params, additionalData: hex(value) }, aes, ciphertext), name);
        break;
      default:
        assert.fail(`Unknown negative vector: ${name}`);
    }
  }
});
