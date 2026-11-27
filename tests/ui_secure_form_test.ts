import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { sealSecureForm, secureFormEventDetail, verifySecureForm, type FormRegistration } from '../src/ui/utils/secureFormCrypto.ts';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/secure-form-v1.json', import.meta.url), 'utf8'));
const registration: FormRegistration = { version: 1, request: fixture.request, schema: fixture.schema, signature: fixture.request_signature };
const bytes = (str: string) => Buffer.from(str, 'hex');
const hex = (data: ArrayBuffer) => Buffer.from(data).toString('hex');
const expected = { owner: fixture.request.owner, conversation: fixture.request.conversation, bridge: fixture.request.bridge };
const nativeKey = { name: 'ECDSA', namedCurve: 'P-256' };
const signing = { name: 'ECDSA', hash: 'SHA-256' };
const agreement = { name: 'ECDH', namedCurve: 'P-256' };

function transcript(...parts: (string | Uint8Array)[]) {
  return Buffer.concat(parts.flatMap((part) => {
    const value = Buffer.from(part);
    const size = Buffer.alloc(4);
    size.writeUInt32BE(value.length);
    return [size, value];
  }));
}

async function syntheticRegistration(schema: string) {
  const bridge = await crypto.subtle.generateKey(nativeKey, false, ['sign', 'verify']);
  const r = { ...registration.request, deadline: String(Date.now() + 60_000),
    schema_digest: hex(await crypto.subtle.digest('SHA-256', Buffer.from(schema))) };
  const data = transcript('heimdall.secure-form.request.v1', r.owner, r.bridge, r.generation, r.instance, r.task,
    r.conversation, bytes(r.request_id), r.deadline, r.script, bytes(r.schema_digest), bytes(r.recipient_key));
  return {
    reg: { version: 1 as const, request: r, schema, signature: hex(await crypto.subtle.sign(signing, bridge.privateKey, data)) },
    publicKey: hex(await crypto.subtle.exportKey('raw', bridge.publicKey)),
  };
}

test('only the signed placement, purpose and script are eligible for display', async () => {
  const verified = await verifySecureForm(registration, expected, fixture.bridge_public);
  assert.equal(hex(verified.digest), fixture.answer.request_digest);
  assert.equal(verified.request.script, '/approved/login.sh');
  assert.equal(verified.schema.purpose, 'Sign in to the test account.');
  await assert.rejects(verifySecureForm(registration, { ...expected, conversation: 'other-conversation' }, fixture.bridge_public));
  for (const request of [{ ...registration.request, script: '/different/script.sh' },
    { ...registration.request, instance: 'other-agent' }, { ...registration.request, generation: '14' }]) {
    await assert.rejects(verifySecureForm({ ...registration, request }, expected, fixture.bridge_public));
  }
  await assert.rejects(verifySecureForm({ ...registration, schema: registration.schema.replace('Sign in', 'Sign out') }, expected, fixture.bridge_public));
});

test('a valid signature cannot authorize a remote or inline logo or duplicate fields', async () => {
  const schema = JSON.parse(fixture.schema);
  for (const forbidden of [{ ...schema, logo: 'https://example.test/image' }, { ...schema, logo: '<svg/>' },
    { ...schema, fields: [schema.fields[0], schema.fields[0]] }]) {
    const { reg, publicKey } = await syntheticRegistration(JSON.stringify(forbidden));
    await assert.rejects(verifySecureForm(reg, expected, publicKey));
  }
});

test('the sealed submission decrypts only with the intended key and request digest', async () => {
  const { reg, publicKey } = await syntheticRegistration(fixture.schema);
  const form = await verifySecureForm(reg, expected, publicKey);
  const device = await crypto.subtle.generateKey(nativeKey, false, ['sign', 'verify']);
  const signer = { deviceId: 'test_device', signPrivateKey: device.privateKey, sequence: 42, head: 'cd'.repeat(32), proof: 'synthetic-proof' };
  const values = JSON.parse(fixture.plaintext);
  const payload = await sealSecureForm(form, values, signer);
  const envelope = JSON.parse(payload.envelope);
  assert.equal(payload.directory_proof, signer.proof);
  assert.equal(envelope.request_digest, hex(form.digest));
  assert.ok(!JSON.stringify(payload).includes(values.pass));
  assert.ok(!JSON.stringify(payload).includes(values.login));
  const recipient = await crypto.subtle.importKey('jwk', fixture.recipient_jwk, agreement, false, ['deriveBits']);
  const sender = await crypto.subtle.importKey('raw', bytes(envelope.sender_key), agreement, false, []);
  const shared = await crypto.subtle.deriveBits({ name: 'ECDH', public: sender }, recipient, 256);
  const key = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
  const domain = 'heimdall.secure-form.answer.v1';
  const aes = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: form.digest, info: Buffer.from(domain) },
    key, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
  const ciphertext = Buffer.from(envelope.ciphertext, 'base64');
  const params = { name: 'AES-GCM', iv: bytes(envelope.nonce), additionalData: form.digest };
  assert.equal(Buffer.from(await crypto.subtle.decrypt(params, aes, ciphertext)).toString(), fixture.plaintext);
  await assert.rejects(crypto.subtle.decrypt({ ...params, additionalData: Buffer.alloc(32) }, aes, ciphertext));
  assert.equal(await crypto.subtle.verify(signing, device.publicKey, bytes(envelope.signature), transcript(domain,
    bytes(envelope.request_digest), envelope.device, envelope.directory_sequence, bytes(envelope.directory_head),
    bytes(envelope.sender_key), bytes(envelope.nonce), ciphertext)), true);
  await assert.rejects(sealSecureForm(form, { ...values, roles: ['observer', 'observer'] }, signer));
  const expired = await verifySecureForm(registration, expected, fixture.bridge_public);
  await assert.rejects(sealSecureForm(expired, values, signer));
});

test('WebSocket routing passes only an addressed metadata refresh', () => {
  const detail = { conversation_id: expected.conversation, request_id: fixture.request.request_id };
  assert.deepEqual(secureFormEventDetail({ ...detail, envelope: 'ignored' } as typeof detail), detail);
  assert.equal(secureFormEventDetail({ ...detail, request_id: '../submit' }), null);
  assert.equal(secureFormEventDetail({ ...detail, conversation_id: '' }), null);
});
