import { ownerPayloadDigest, ownerParse, type OwnerVerifiedKey } from './ownerLocal.ts';
import { parseOwnerRequestDocument } from './ownerJson.ts';

// Mirrored executor resource contracts; no task command or launch authority.
export const executorSchemas = {
  transport_scope: [
    ['protocol_version','version'],['account_id','id'],['owner_bridge_id','id'],['executor_bridge_id','id'],
    ['chain_id','id'],['reservation_id','optional'],['request_id','id'],
    ['method','executor_transport_method'],['direction','executor_direction'],
    ['input_digest','hash'],['fence_digest','hash'],['owner_incarnation','positive'],['executor_incarnation','positive'],
    ['issued_ms','positive'],['request_expires_ms','positive'],
  ],
  enrollment: [
    ['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['owner_bridge_id','id'],['chain_id','id'],['task_id','id'],['instance_id','id'],
    ['configuration_revision','positive'],['configuration_digest','hash'],
    ['issued_ms','positive'],['request_expires_ms','positive'],['key_id','id'],['signature','signature'],
  ],
  fence_request: [
    ['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['owner_bridge_id','id'],['chain_id','id'],['reservation_id','id'],
    ['executor_incarnation','positive'],['owner_incarnation','positive'],
    ['intent_id','hash'],['claim_attempt','positive'],['action_digest','hash'],
    ['challenge','hash'],['issued_ms','positive'],['request_expires_ms','positive'],
    ['key_id','id'],['signature','signature'],
  ],
  fence_reply: [
    ['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['owner_bridge_id','id'],['chain_id','id'],['reservation_id','id'],
    ['executor_incarnation','positive'],['owner_incarnation','positive'],
    ['request_digest','hash'],['action_digest','hash'],['prepare_digest','hash'],
    ['challenge','hash'],['owner_commit_seq','positive'],['checked_ms','positive'],
    ['request_expires_ms','positive'],['key_id','id'],['signature','signature'],
  ],
  "policy": [
    [
      "protocol_version",
      "version"
    ],
    [
      "account_id",
      "id"
    ],
    [
      "executor_bridge_id",
      "id"
    ],
    [
      "policy_revision",
      "positive"
    ],
    [
      "device_capacity",
      "positive"
    ],
    [
      "slots_json",
      "document"
    ],
    [
      "key_id",
      "id"
    ],
    [
      "signature",
      "signature"
    ]
  ],
  "prepare": [
    [
      "protocol_version",
      "version"
    ],
    [
      "account_id",
      "id"
    ],
    [
      "executor_bridge_id",
      "id"
    ],
    [
      "owner_bridge_id",
      "id"
    ],
    [
      "chain_id",
      "id"
    ],
    [
      "task_id",
      "id"
    ],
    [
      "lease_id",
      "id"
    ],
    [
      "reservation_id",
      "id"
    ],
    [
      "operation_id",
      "id"
    ],
    [
      "instance_id",
      "id"
    ],
    [
      "launch_epoch",
      "id"
    ],
    [
      "run_count",
      "positive"
    ],
    [
      "token_generation",
      "hash"
    ],
    [
      "configuration_revision",
      "positive"
    ],
    [
      "grant_generation",
      "positive"
    ],
    [
      "owner_incarnation",
      "positive"
    ],
    [
      "executor_incarnation",
      "positive"
    ],
    [
      "policy_revision",
      "positive"
    ],
    [
      "slot_id",
      "id"
    ],
    [
      "provider_profile",
      "id"
    ],
    [
      "directory_key",
      "optional"
    ],
    [
      "purpose",
      "executor_purpose"
    ],
    [
      "prepare_until_ms",
      "positive"
    ],
    [
      "hard_ms",
      "positive"
    ],
    [
      "request_expires_ms",
      "positive"
    ],
    [
      "key_id",
      "id"
    ],
    [
      "signature",
      "signature"
    ]
  ],
  "action": [
    [
      "protocol_version",
      "version"
    ],
    [
      "account_id",
      "id"
    ],
    [
      "executor_bridge_id",
      "id"
    ],
    [
      "owner_bridge_id",
      "id"
    ],
    [
      "chain_id",
      "id"
    ],
    [
      "reservation_id",
      "id"
    ],
    [
      "operation_id",
      "id"
    ],
    [
      "method",
      "executor_method"
    ],
    [
      "prepare_digest",
      "hash"
    ],
    [
      "executor_incarnation",
      "positive"
    ],
    [
      "owner_incarnation",
      "positive"
    ],
    [
      "owner_commit_seq",
      "positive"
    ],
    [
      "grant_generation",
      "positive"
    ],
    [
      "deadline_version",
      "positive"
    ],
    [
      "expires_ms",
      "positive"
    ],
    [
      "hard_ms",
      "positive"
    ],
    [
      "request_expires_ms",
      "positive"
    ],
    [
      "key_id",
      "id"
    ],
    [
      "signature",
      "signature"
    ]
  ],
  "receipt": [
    [
      "protocol_version",
      "version"
    ],
    [
      "account_id",
      "id"
    ],
    [
      "executor_bridge_id",
      "id"
    ],
    [
      "owner_bridge_id",
      "id"
    ],
    [
      "chain_id",
      "id"
    ],
    [
      "reservation_id",
      "id"
    ],
    [
      "operation_id",
      "id"
    ],
    [
      "method",
      "executor_receipt_method"
    ],
    [
      "input_digest",
      "hash"
    ],
    [
      "prepare_digest",
      "hash"
    ],
    [
      "executor_incarnation",
      "positive"
    ],
    [
      "child_incarnation",
      "positive"
    ],
    [
      "grant_generation",
      "positive"
    ],
    [
      "deadline_version",
      "positive"
    ],
    [
      "expires_ms",
      "positive"
    ],
    [
      "hard_ms",
      "positive"
    ],
    [
      "launch_key",
      "hash"
    ],
    [
      "state",
      "executor_state"
    ],
    [
      "historical",
      "executor_flag"
    ],
    [
      "key_id",
      "id"
    ],
    [
      "signature",
      "signature"
    ]
  ]
} as const;
export type ExecutorKind = keyof typeof executorSchemas;
export type ExecutorDocument = Record<string, string>;
export const EXECUTOR_DOCUMENT_MAX = 32768;
export const EXECUTOR_CAPACITY_MAX = 128;
export const EXECUTOR_PREPARE_TTL_MS = 30000n;
export const EXECUTOR_FENCE_TTL_MS = 5000n;
export const EXECUTOR_TRANSPORT_TTL_MS = 60000n;
const integer = (s: string) => /^(0|[1-9][0-9]*)$/.test(s) && s.length <= 19 && BigInt(s) <= 9223372036854775807n;
const id = (s: string) => s.length <= 160 && /^[a-zA-Z0-9_.:-]+$/.test(s);
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
function fieldValid(s: string, kind: string): boolean {
  switch (kind) {
    case 'executor_transport_method': return ['enrollment','prepare','action','fence_request'].includes(s);
    case 'executor_direction': return s === 'request' || s === 'response';
    case 'document': return new TextEncoder().encode(s).length <= 256 * 1024 && s !== '';
    case 'version': return s === '1';
    case 'id': return id(s);
    case 'optional': return s === '' || id(s);
    case 'positive': return integer(s) && s !== '0';
    case 'hash': return /^[0-9a-f]{64}$/.test(s);
    case 'signature': return /^[0-9a-f]{128}$/.test(s);
    case 'executor_receipt_method': return ['prepare','activate','heartbeat','stop','query'].includes(s);
    case 'executor_state': return ['prepared','active','stopping','released'].includes(s);
    case 'executor_flag': return s === '0' || s === '1';
    case 'executor_purpose': return ['work','review','manual','warm'].includes(s);
    case 'executor_method': return ['activate','heartbeat','stop','query'].includes(s);
    default: return false;
  }
}
export function executorParse(raw: string, kind: ExecutorKind): ExecutorDocument {
  if (new TextEncoder().encode(raw).length > EXECUTOR_DOCUMENT_MAX) throw new SyntaxError('Executor document too large');
  const value = parseOwnerRequestDocument(raw);
  const schema = executorSchemas[kind];
  if (!schema || !object(value) || Object.keys(value).length !== schema.length) throw new SyntaxError('Executor shape');
  for (const [name, type] of schema) {
    const field = value[name];
    if (typeof field !== 'string' || !fieldValid(field, type)) throw new SyntaxError('Executor field');
  }
  const o = value as ExecutorDocument;
  if (kind === 'policy') {
    const capacity = BigInt(o.device_capacity);
    const slots = parseOwnerRequestDocument(o.slots_json);
    if (capacity > BigInt(EXECUTOR_CAPACITY_MAX) || !Array.isArray(slots) || BigInt(slots.length) > capacity) throw new SyntaxError('Executor capacity');
    const seen = new Set<string>();
    for (const slot of slots) {
      if (!object(slot) || Object.keys(slot).length !== 3 || typeof slot.slot_id !== 'string' || !id(slot.slot_id) ||
          typeof slot.provider_profile !== 'string' || !id(slot.provider_profile) || (slot.enabled !== '0' && slot.enabled !== '1') ||
          seen.has(slot.slot_id)) throw new SyntaxError('Executor slot');
      seen.add(slot.slot_id);
    }
  }
  if (kind === 'prepare' && (BigInt(o.prepare_until_ms) > BigInt(o.hard_ms) || (o.directory_key !== '' && !/^[0-9a-f]{64}$/.test(o.directory_key)))) throw new SyntaxError('Executor prepare bounds');
  if ((kind === 'action' || kind === 'receipt') && BigInt(o.expires_ms) > BigInt(o.hard_ms)) throw new SyntaxError('Executor action bounds');
  if (kind === 'fence_request' || kind === 'fence_reply') {
    const start = BigInt(kind === 'fence_request' ? o.issued_ms : o.checked_ms);
    const end = BigInt(o.request_expires_ms);
    if (end <= start || end - start > EXECUTOR_FENCE_TTL_MS) throw new SyntaxError('Executor fence bounds');
  }
  if (kind === 'enrollment' && (BigInt(o.request_expires_ms) <= BigInt(o.issued_ms) || BigInt(o.request_expires_ms)-BigInt(o.issued_ms) > 300000n)) throw new SyntaxError('Executor enrollment bounds');
  if (kind === 'transport_scope' && (BigInt(o.request_expires_ms) <= BigInt(o.issued_ms) || BigInt(o.request_expires_ms)-BigInt(o.issued_ms) > EXECUTOR_TRANSPORT_TTL_MS ||
      (o.method === 'enrollment' ? o.reservation_id !== '' : !id(o.reservation_id)))) throw new SyntaxError('Executor transport bounds');
  return o;
}
export function executorCanonical(kind: ExecutorKind, value: ExecutorDocument): string {
  const o = executorParse(JSON.stringify(value), kind);
  return 'heimdall-executor/' + kind + '/v1\n' + executorSchemas[kind].filter(([,type]) => type !== 'signature').map(([name]) => o[name].length + ':' + o[name] + ',').join('');
}

const unhex = (hex: string): Uint8Array<ArrayBuffer> => Uint8Array.from(hex.match(/../g) ?? [], (pair) => parseInt(pair,16));
export async function executorVerify(kind: ExecutorKind, value: ExecutorDocument, key: OwnerVerifiedKey): Promise<boolean> {
  try {
    const o = executorParse(JSON.stringify(value), kind);
    const principal = kind === 'policy' || kind === 'receipt' || kind === 'fence_request' || kind === 'enrollment' ? o.executor_bridge_id : o.owner_bridge_id;
    if (!key.enrolled || key.revoked || key.kind !== 'bridge' || key.account_id !== o.account_id ||
        key.principal_id !== principal || key.key_id !== o.key_id || !/^04[0-9a-f]{128}$/.test(key.public_key)) return false;
    const pub = await crypto.subtle.importKey('raw', unhex(key.public_key), {name:'ECDSA',namedCurve:'P-256'}, false, ['verify']);
    return await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'}, pub, unhex(o.signature), new TextEncoder().encode(executorCanonical(kind,o)));
  } catch { return false; }
}

export async function executorEnrollmentMatches(attestation: ExecutorDocument, configurationRaw: string, key: OwnerVerifiedKey, now: bigint, currentAdmission = true): Promise<boolean> {
  try {
    const c = ownerParse(configurationRaw,'remote_configuration');
    if (!await executorVerify('enrollment',attestation,key) || c.owner_bridge_id === c.executor_bridge_id || c.directory_path === '' || c.executor_key_id !== key.key_id ||
        attestation.configuration_digest !== await ownerPayloadDigest(configurationRaw)) return false;
    for (const name of ['protocol_version','account_id','executor_bridge_id','owner_bridge_id','chain_id','task_id','instance_id','configuration_revision'] as const) {
      if (attestation[name] !== c[name]) return false;
    }
    return !currentAdmission || (now >= BigInt(attestation.issued_ms) && now < BigInt(attestation.request_expires_ms));
  } catch { return false; }
}

// Callers must consume the locally pending challenge once this succeeds.
export async function executorFenceReplyMatches(reply: ExecutorDocument, request: ExecutorDocument, action: ExecutorDocument,
  ownerKey: OwnerVerifiedKey, executorKey: OwnerVerifiedKey, now: bigint): Promise<boolean> {
  try {
    if (!await executorVerify('fence_request',request,executorKey) || !await executorVerify('fence_reply',reply,ownerKey) ||
        !await executorVerify('action',action,ownerKey) || action.method !== 'activate') return false;
    for (const name of ['account_id','executor_bridge_id','owner_bridge_id','chain_id','reservation_id','executor_incarnation','owner_incarnation','request_expires_ms']) {
      if (reply[name] !== request[name]) return false;
    }
    for (const name of ['account_id','executor_bridge_id','owner_bridge_id','chain_id','reservation_id','executor_incarnation','owner_incarnation']) {
      if (request[name] !== action[name]) return false;
    }
    const requestDigest = await ownerPayloadDigest(executorCanonical('fence_request',request));
    const actionDigest = await ownerPayloadDigest(executorCanonical('action',action));
    return reply.request_digest === requestDigest && reply.challenge === request.challenge &&
      request.action_digest === actionDigest && reply.action_digest === actionDigest &&
      reply.prepare_digest === action.prepare_digest && reply.owner_commit_seq === action.owner_commit_seq &&
      now >= BigInt(reply.checked_ms) && BigInt(reply.checked_ms) >= BigInt(request.issued_ms) &&
      now < BigInt(request.request_expires_ms) && now < BigInt(action.request_expires_ms) &&
      now < BigInt(action.expires_ms) && now < BigInt(action.hard_ms);
  } catch { return false; }
}
export async function executorReceiptMatches(receipt: ExecutorDocument, request: ExecutorDocument, kind: 'prepare' | 'action', key: OwnerVerifiedKey, now: bigint, currentAdmission = true): Promise<boolean> {
  try {
    executorParse(JSON.stringify(request), kind);
    if (!await executorVerify('receipt',receipt,key)) return false;
    for (const name of ['account_id','executor_bridge_id','owner_bridge_id','chain_id','reservation_id','operation_id','grant_generation']) {
      if (receipt[name] !== request[name]) return false;
    }
    const digest = await ownerPayloadDigest(executorCanonical(kind,request));
    if (receipt.input_digest !== digest || receipt.executor_incarnation !== request.executor_incarnation || receipt.hard_ms !== request.hard_ms) return false;
    const method = kind === 'prepare' ? 'prepare' : request.method;
    if (receipt.method !== method || receipt.prepare_digest !== (kind === 'prepare' ? digest : request.prepare_digest)) return false;
    if (!currentAdmission) return true;
    if (now < 0n || receipt.historical !== '0' || BigInt(receipt.expires_ms) <= now) return false;
    if (method === 'prepare') return receipt.state === 'prepared' && receipt.child_incarnation === request.executor_incarnation && receipt.expires_ms === request.prepare_until_ms && receipt.deadline_version === '1';
    if (method === 'activate' || method === 'heartbeat') return receipt.state === 'active' && receipt.expires_ms === request.expires_ms && receipt.deadline_version === request.deadline_version;
    return method === 'query' || (method === 'stop' && ['stopping','released'].includes(receipt.state));
  } catch { return false; }
}
