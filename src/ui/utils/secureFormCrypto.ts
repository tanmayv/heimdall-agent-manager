const utf8 = new TextEncoder();
const agreement = { name: 'ECDH', namedCurve: 'P-256' };
const signing = { name: 'ECDSA', hash: 'SHA-256' };
const answerDomain = 'heimdall.secure-form.answer.v1';
const idPattern = /^[A-Za-z0-9_-]{1,64}$/;
const decimal = /^[1-9][0-9]{0,15}$/;
export const secureFormId = /^[0-9a-f]{64}$/;
export const secureFormChanged = 'secure_form.changed';

export function secureFormEventDetail(payload: { conversation_id?: unknown; request_id?: unknown }) {
  if (typeof payload.conversation_id !== 'string' || !payload.conversation_id
    || typeof payload.request_id !== 'string' || !secureFormId.test(payload.request_id)) return null;
  return { conversation_id: payload.conversation_id, request_id: payload.request_id };
}

type Choice = { id: string; label: string };
export type SecureFormField = Choice & { type: 'text' | 'password' | 'single' | 'multiple'; choices?: Choice[] };
type PublicSchema = { version: 1; purpose: string; logo?: 'heimdall'; fields: SecureFormField[] };
export type FormRequest = Record<'owner' | 'bridge' | 'generation' | 'instance' | 'task' | 'conversation' |
  'request_id' | 'deadline' | 'script' | 'schema_digest' | 'recipient_key', string>;
export type FormRegistration = { version: 1; request: FormRequest; schema: string; signature: string };
export type FormStatus = { version: 1; request_id: string; generation: string; state: 'pending' | 'forwarding' | 'accepted' | 'final'; code?: number | null };
export type FormView = { registration: FormRegistration; status: FormStatus };
type Values = Record<string, string | string[]>;

export function missingSecureFormChoices(fields: SecureFormField[], values: Values): Record<string, string> {
  const missing: Record<string, string> = Object.create(null);
  for (const { id, type } of fields) {
    const value = Object.hasOwn(values, id) ? values[id] : undefined;
    if (type === 'single' && (typeof value !== 'string' || !value)) missing[id] = 'Choose an option.';
    if (type === 'multiple' && (!Array.isArray(value) || !value.length)) missing[id] = 'Choose at least one option.';
  }
  return missing;
}

function requireValid(condition: unknown): asserts condition {
  if (!condition) throw new Error('Secure form verification failed');
}

function asBytes(value: string, size: number) {
  requireValid(typeof value === 'string' && value.length === size * 2 && /^[0-9a-f]+$/.test(value));
  return Uint8Array.from(value.match(/../g)!, (pair) => Number.parseInt(pair, 16));
}

function hex(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function frame(...parts: (string | Uint8Array)[]) {
  const bytes = parts.map((part) => typeof part === 'string' ? utf8.encode(part) : part);
  const result = new Uint8Array(bytes.reduce((n, part) => n + 4 + part.length, 0));
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const part of bytes) {
    view.setUint32(offset, part.length);
    result.set(part, offset + 4);
    offset += 4 + part.length;
  }
  return result;
}

function text(value: unknown, limit: number): value is string {
  return typeof value === 'string' && Boolean(value.trim()) && Array.from(value).length <= limit && !/[\p{Cc}\p{Cs}\u2028\u2029<>]/u.test(value);
}

function onlyKeys(value: unknown, keys: string[]): value is Record<string, unknown> {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every((key) => keys.includes(key)));
}

function parseSchema(raw: string): PublicSchema {
  requireValid(typeof raw === 'string' && utf8.encode(raw).length <= 32768);
  const schema: unknown = JSON.parse(raw);
  requireValid(onlyKeys(schema, ['version', 'purpose', 'logo', 'fields']) && schema.version === 1
    && text(schema.purpose, 200) && (!('logo' in schema) || schema.logo === 'heimdall')
    && Array.isArray(schema.fields) && schema.fields.length >= 1 && schema.fields.length <= 12);
  const seen = new Set<string>();
  for (const field of schema.fields) {
    requireValid(onlyKeys(field, ['id', 'label', 'type', 'choices'])
      && typeof field.id === 'string' && idPattern.test(field.id) && !seen.has(field.id)
      && text(field.label, 200));
    seen.add(field.id);
    if (field.type === 'text' || field.type === 'password') {
      requireValid(!('choices' in field));
      continue;
    }
    requireValid((field.type === 'single' || field.type === 'multiple') && Array.isArray(field.choices)
      && field.choices.length >= 1 && field.choices.length <= 12);
    const choices = new Set<string>();
    for (const choice of field.choices) {
      requireValid(onlyKeys(choice, ['id', 'label']) && typeof choice.id === 'string'
        && idPattern.test(choice.id) && !choices.has(choice.id) && text(choice.label, 200));
      choices.add(choice.id);
    }
  }
  return schema as unknown as PublicSchema;
}

export async function verifySecureForm(
  registration: FormRegistration,
  expected: { owner: string; conversation: string; bridge: string },
  trustedBridgeKey: string,
) {
  const { request: r, schema: raw, signature } = registration;
  requireValid(registration.version === 1 && r.owner === expected.owner && r.conversation === expected.conversation
    && r.bridge === expected.bridge && text(r.instance, 256) && typeof r.task === 'string'
    && typeof r.generation === 'string' && typeof r.deadline === 'string'
    && decimal.test(r.generation) && decimal.test(r.deadline) && Number(r.deadline) <= 8640000000000000
    && typeof r.script === 'string' && utf8.encode(r.script).length <= 4096 && !/[\u0000-\u001f\u007f\p{Cs}]/u.test(r.script)
    && r.script.startsWith('/') && r.script.slice(1).split('/').every((part) => part && part !== '.' && part !== '..'));
  const schema = parseSchema(raw);
  requireValid(hex(await crypto.subtle.digest('SHA-256', utf8.encode(raw))) === r.schema_digest);
  const recipient = asBytes(r.recipient_key, 65);
  const transcript = frame('heimdall.secure-form.request.v1', r.owner, r.bridge, r.generation, r.instance, r.task,
    r.conversation, asBytes(r.request_id, 32), r.deadline, r.script, asBytes(r.schema_digest, 32), recipient);
  const key = await crypto.subtle.importKey('raw', asBytes(trustedBridgeKey, 65), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  requireValid(await crypto.subtle.verify(signing, key, asBytes(signature, 64), transcript));
  const recipientKey = await crypto.subtle.importKey('raw', recipient, agreement, false, []);
  return { request: { ...r }, schema, recipientKey, digest: await crypto.subtle.digest('SHA-256', transcript) };
}

export type VerifiedForm = Awaited<ReturnType<typeof verifySecureForm>>;
export type FormSigner = { deviceId: string; signPrivateKey: CryptoKey; sequence: number; head: string; proof: string };

export async function sealSecureForm(form: VerifiedForm, values: Values, signer: FormSigner) {
  requireValid(Date.now() < Number(form.request.deadline) && Number.isSafeInteger(signer.sequence) && signer.sequence > 0
    && utf8.encode(signer.proof).length <= 262144);
  const normalized: Values = Object.create(null);
  for (const field of form.schema.fields) {
    const value = values[field.id];
    if (field.type === 'multiple') {
      requireValid(Array.isArray(value) && value.length > 0 && new Set(value).size === value.length
        && value.every((id) => field.choices?.some((choice) => choice.id === id)));
    } else {
      requireValid(typeof value === 'string' && value !== '' && utf8.encode(value).length <= 8192 && !/\p{Cs}/u.test(value)
        && (field.type !== 'single' || field.choices?.some((choice) => choice.id === value)));
    }
    normalized[field.id] = value;
  }
  const plaintext = utf8.encode(JSON.stringify(normalized));
  try {
    requireValid(plaintext.length <= 32768);
    const sender = await crypto.subtle.generateKey(agreement, false, ['deriveBits']);
    const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: form.recipientKey }, sender.privateKey, 256));
    const material = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']).finally(() => shared.fill(0));
    const aes = await crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: form.digest, info: utf8.encode(answerDomain) },
      material, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: form.digest, tagLength: 128 }, aes, plaintext));
    const senderKey = await crypto.subtle.exportKey('raw', sender.publicKey);
    const sequence = String(signer.sequence);
    const signed = frame(answerDomain, new Uint8Array(form.digest), signer.deviceId, sequence,
      asBytes(signer.head, 32), new Uint8Array(senderKey), nonce, ciphertext);
    const signature = await crypto.subtle.sign(signing, signer.signPrivateKey, signed);
    return {
      version: 1, request_id: form.request.request_id, generation: form.request.generation,
      envelope: JSON.stringify({
        request_digest: hex(form.digest), device: signer.deviceId, directory_sequence: sequence,
        directory_head: signer.head, sender_key: hex(senderKey), nonce: hex(nonce.buffer),
        ciphertext: btoa(Array.from(ciphertext, (byte) => String.fromCharCode(byte)).join('')), signature: hex(signature),
      }),
      directory_proof: signer.proof,
    };
  } finally {
    plaintext.fill(0);
  }
}
