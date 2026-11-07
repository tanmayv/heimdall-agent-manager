import { parseVaultEnvelope } from '../utils/vaultCrypto.ts';
import { ownerPayloadDigest, ownerParse, type OwnerVerifiedKey } from './ownerLocal.ts';
import { parseOwnerRequestDocument } from './ownerJson.ts';

// Mirrored executor resource contracts; no task command or launch authority.
export const executorSchemas = {
  notification: [["protocol_version","version"],["account_id","id"],["owner_bridge_id","id"],["executor_bridge_id","id"],["chain_id","id"],["task_id","id"],["lease_id","id"],["reservation_id","id"],["instance_id","id"],["launch_epoch","id"],["run_count","positive"],["token_generation","hash"],["configuration_revision","positive"],["grant_generation","positive"],["owner_incarnation","positive"],["executor_incarnation","positive"],["prepare_digest","hash"],["launch_key","hash"],["deadline_version","positive"],["expires_ms","positive"],["hard_ms","positive"],["intent_id","hash"],["owner_commit_seq","positive"],["message_digest","hash"],["issued_ms","positive"],["request_expires_ms","positive"],["key_id","id"],["signature","signature"]],
  notification_result: [["protocol_version","version"],["account_id","id"],["owner_bridge_id","id"],["executor_bridge_id","id"],["chain_id","id"],["reservation_id","id"],["owner_incarnation","positive"],["executor_incarnation","positive"],["prepare_digest","hash"],["input_digest","hash"],["intent_id","hash"],["pid","counter"],["ticket","optional"],["input_profile","optional"],["esc_written","executor_flag"],["message_bytes_written","counter"],["enter_written","executor_flag"],["status","notification_status"],["issued_ms","positive"],["request_expires_ms","positive"],["key_id","id"],["signature","signature"]],
  notification_exchange: [['scope','document'],['envelope','required_cipher'],['message','document'],['claim_attempt','positive']],
  notification_fence_request: [
    ['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['owner_bridge_id','id'],['chain_id','id'],['reservation_id','id'],
    ['executor_incarnation','positive'],['owner_incarnation','positive'],
    ['intent_id','hash'],['claim_attempt','positive'],['action_digest','hash'],
    ['challenge','hash'],['issued_ms','positive'],['request_expires_ms','positive'],
    ['key_id','id'],['signature','signature'],['notification','document'],
  ],
  notification_fence_reply: [
    ['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['owner_bridge_id','id'],['chain_id','id'],['reservation_id','id'],
    ['executor_incarnation','positive'],['owner_incarnation','positive'],
    ['request_digest','hash'],['action_digest','hash'],['prepare_digest','hash'],
    ['challenge','hash'],['owner_commit_seq','positive'],['checked_ms','positive'],
    ['request_expires_ms','positive'],['key_id','id'],['signature','signature'],
  ],
  operator_import: [['kind','label'],['document','document']],
  local_relay: [['protocol_version','version'],['bridge_id','id'],['request_id','id'],['expires_ms','positive'],['envelope','required_cipher']],
  local_result: [['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['principal_id','id'],['operation_id','id'],['request_id','id'],['request_digest','hash'],['result_digest','hash'],
    ['issued_ms','positive'],['request_expires_ms','positive'],['key_id','id'],['signature','signature']],
  local_bundle: [['receipt','document'],['body','document']],
  local_draft: [['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['principal_id','id'],['operation_id','id'],['method','executor_draft_method'],
    ['draft_id','hash'],['draft_revision','positive'],['configuration_digest','hash'],
    ['issued_ms','positive'],['request_expires_ms','positive'],['key_id','id'],['signature','signature']],
  local_launch: [['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['principal_id','id'],['operation_id','id'],['configuration_digest','hash'],
    ['issued_ms','positive'],['request_expires_ms','positive'],['key_id','id'],['signature','signature']],
  local_configuration: [['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['instance_id','id'],['launch_epoch','id'],['run_count','positive'],['token_generation','hash'],
    ['configuration_revision','positive'],['executor_incarnation','positive'],['policy_revision','positive'],
    ['slot_id','id'],['provider','label'],['model','label'],['provider_profile','id'],
    ['directory_id','id'],['directory_revision','positive'],['directory_key','hash'],
    ['purpose','executor_local_purpose'],['spawn_digest','hash']],
  bootstrap_content: [['agents_md','document'],['memory_md','optional_document'],['task_md','document'],['skills_json','document']],
  child_request: [["protocol_version", "version"], ["account_id", "id"], ["owner_bridge_id", "id"], ["executor_bridge_id", "id"], ["chain_id", "id"], ["task_id", "id"], ["lease_id", "id"], ["reservation_id", "id"], ["instance_id", "id"], ["launch_epoch", "id"], ["run_count", "positive"], ["token_generation", "hash"], ["configuration_revision", "positive"], ["grant_generation", "positive"], ["owner_incarnation", "positive"], ["executor_incarnation", "positive"], ["prepare_digest", "hash"], ["bootstrap_digest", "hash"], ["input_digest", "hash"], ["launch_key", "hash"], ["deadline_version", "positive"], ["expires_ms", "positive"], ["hard_ms", "positive"], ["issued_ms", "positive"], ["request_expires_ms", "positive"], ["key_id", "id"], ["signature", "signature"]],
  bootstrap: [["protocol_version", "version"], ["account_id", "id"], ["owner_bridge_id", "id"], ["executor_bridge_id", "id"], ["chain_id", "id"], ["task_id", "id"], ["lease_id", "id"], ["reservation_id", "id"], ["instance_id", "id"], ["launch_epoch", "id"], ["run_count", "positive"], ["token_generation", "hash"], ["configuration_revision", "positive"], ["grant_generation", "positive"], ["owner_incarnation", "positive"], ["executor_incarnation", "positive"], ["prepare_digest", "hash"], ["action_digest", "hash"], ["configuration_digest", "hash"], ["body_digest", "hash"], ["launch_key", "hash"], ["deadline_version", "positive"], ["expires_ms", "positive"], ["hard_ms", "positive"], ["issued_ms", "positive"], ["request_expires_ms", "positive"], ["key_id", "id"], ["signature", "signature"]],
  transport_scope: [
    ['protocol_version','version'],['account_id','id'],['owner_bridge_id','id'],['executor_bridge_id','id'],
    ['chain_id','id'],['reservation_id','optional'],['request_id','id'],
    ['method','executor_transport_method'],['direction','executor_direction'],
    ['input_digest','hash'],['fence_digest','hash'],['owner_incarnation','positive'],['executor_incarnation','positive'],
    ['issued_ms','positive'],['request_expires_ms','positive'],
  ],
  exchange: [['scope','document'],['envelope','required_cipher']],
  child_exchange: [['scope','document'],['envelope','required_cipher'],['input','document']],
  child_result_bundle: [['receipt','document'],['body','document']],
  child_result: [['protocol_version','version'],['account_id','id'],['owner_bridge_id','id'],['executor_bridge_id','id'],['chain_id','id'],['reservation_id','id'],['owner_incarnation','positive'],['executor_incarnation','positive'],['prepare_digest','hash'],['request_digest','hash'],['input_digest','hash'],['result_digest','hash'],['issued_ms','positive'],['request_expires_ms','positive'],['key_id','id'],['signature','signature']],
  activation_bootstrap_exchange: [['scope','document'],['envelope','required_cipher'],['intent_id','hash'],['claim_attempt','positive'],['bootstrap','document'],['body','document']],
  activation_exchange: [['scope','document'],['envelope','required_cipher'],['intent_id','hash'],['claim_attempt','positive']],
  issuance_exchange: [['scope','document'],['envelope','required_cipher'],['selection','document']],
  issuance_bundle: [['configuration','document'],['attestation','document'],['issuance_receipt','document']],
  directory: [
    ['protocol_version','version'],['account_id','id'],['executor_bridge_id','id'],
    ['directory_id','id'],['revision','positive'],['directory_path','path'],['enabled','executor_flag'],
    ['key_id','id'],['signature','signature'],
  ],
  issuance_selection: [
    ['provider','label'],
    ['model','label'],
    ['provider_profile','id'],
    ['directory_id','id'],
    ['policy_revision','positive'],
    ['slot_id','id'],
  ],
  issuance_consent: [
    ['protocol_version','version'],
    ['account_id','id'],
    ['owner_bridge_id','id'],
    ['executor_bridge_id','id'],
    ['executor_key_id','id'],
    ['chain_id','id'],
    ['task_id','id'],
    ['agent_id','id'],
    ['configuration_revision','positive'],
    ['operation_id','id'],
    ['principal_id','id'],
    ['selection_digest','hash'],
    ['issued_ms','positive'],
    ['request_expires_ms','positive'],
    ['key_id','id'],
    ['signature','signature'],
  ],
  issuance_receipt: [
    ['protocol_version','version'],
    ['account_id','id'],
    ['owner_bridge_id','id'],
    ['executor_bridge_id','id'],
    ['chain_id','id'],
    ['task_id','id'],
    ['operation_id','id'],
    ['principal_id','id'],
    ['request_digest','hash'],
    ['configuration_digest','hash'],
    ['enrollment_digest','hash'],
    ['issued_ms','positive'],
    ['request_expires_ms','positive'],
    ['key_id','id'],
    ['signature','signature'],
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
    case 'executor_transport_method': return ['enrollment','prepare','action','fence_request','child_request','notification','notification_fence_request'].includes(s);
    case 'executor_direction': return s === 'request' || s === 'response';
    case 'required_cipher': { if (s.length > 65536 || s === '') return false; try { parseVaultEnvelope(s); return true; } catch { return false; } }
    case 'optional_document': return new TextEncoder().encode(s).length <= 256 * 1024;
    case 'document': return new TextEncoder().encode(s).length <= 256 * 1024 && s !== '';
    case 'version': return s === '1';
    case 'id': return id(s);
    case 'path': return s.length <= 4096 && s.startsWith('/') && !s.includes('..') && !s.includes(String.fromCharCode(92)) && [...s].every(c => c.charCodeAt(0) >= 32 && c.charCodeAt(0) <= 126);
    case 'label': return s.length > 0 && new TextEncoder().encode(s).length <= 256 && !/[\u0000-\u001f\u007f]/.test(s);
    case 'optional': return s === '' || id(s);
    case 'counter': return integer(s);
    case 'positive': return integer(s) && s !== '0';
    case 'hash': return /^[0-9a-f]{64}$/.test(s);
    case 'signature': return /^[0-9a-f]{128}$/.test(s);
    case 'executor_receipt_method': return ['prepare','activate','heartbeat','stop','query'].includes(s);
    case 'executor_state': return ['prepared','active','stopping','released'].includes(s);
    case 'notification_status': return ['partial','delivered','recovery_required','child_mismatch','unsupported_not_delivered'].includes(s);
    case 'executor_flag': return s === '0' || s === '1';
    case 'executor_purpose': return ['work','review','manual','warm'].includes(s);
    case 'executor_draft_method': return ['prepare','inspect','authorize','cancel'].includes(s);
    case 'executor_local_purpose': return ['manual','warm','provider_test'].includes(s);
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
  if ((kind === 'local_launch' || kind === 'local_draft' || kind === 'local_result') && (BigInt(o.request_expires_ms) <= BigInt(o.issued_ms) || BigInt(o.request_expires_ms)-BigInt(o.issued_ms) > EXECUTOR_TRANSPORT_TTL_MS)) throw new SyntaxError('Executor local consent bounds');
  if (kind === 'bootstrap_content') {
    const skills = parseOwnerRequestDocument(o.skills_json);
    if (!Array.isArray(skills) || skills.length > 64) throw new SyntaxError('Executor bootstrap skills');
    const seen = new Set<string>();
    for (const skill of skills) {
      if (!object(skill) || Object.keys(skill).length !== 2 || typeof skill.name !== 'string' ||
          !/^[a-zA-Z0-9-]{1,160}$/.test(skill.name) || typeof skill.content !== 'string' ||
          !fieldValid(skill.content,'document') || seen.has(skill.name.toLowerCase())) throw new SyntaxError('Executor bootstrap skill');
      seen.add(skill.name.toLowerCase());
    }
  }
  if (kind === 'bootstrap' || kind === 'child_request' || kind === 'notification') {
    const start = BigInt(o.issued_ms), end = BigInt(o.request_expires_ms);
    if (end <= start || end-start > EXECUTOR_FENCE_TTL_MS || end > BigInt(o.expires_ms) || BigInt(o.expires_ms) > BigInt(o.hard_ms)) throw new SyntaxError('Executor child bounds');
  }
  if ((kind === 'child_result' || kind === 'notification_result') && (BigInt(o.request_expires_ms) <= BigInt(o.issued_ms) || BigInt(o.request_expires_ms)-BigInt(o.issued_ms) > EXECUTOR_FENCE_TTL_MS)) throw new SyntaxError('Executor child result bounds');
  if (kind === 'directory' && o.directory_path === '') throw new SyntaxError('Executor directory path');
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
  if (kind === 'fence_request' || kind === 'fence_reply' || kind === 'notification_fence_request' || kind === 'notification_fence_reply') {
    const start = BigInt(kind === 'fence_request' || kind === 'notification_fence_request' ? o.issued_ms : o.checked_ms);
    const end = BigInt(o.request_expires_ms);
    if (end <= start || end - start > EXECUTOR_FENCE_TTL_MS) throw new SyntaxError('Executor fence bounds');
  }
  if (['enrollment','issuance_consent','issuance_receipt'].includes(kind) && (BigInt(o.request_expires_ms) <= BigInt(o.issued_ms) || BigInt(o.request_expires_ms)-BigInt(o.issued_ms) > 300000n)) throw new SyntaxError('Executor enrollment bounds');
  if (kind === 'transport_scope' && (BigInt(o.request_expires_ms) <= BigInt(o.issued_ms) || BigInt(o.request_expires_ms)-BigInt(o.issued_ms) > EXECUTOR_TRANSPORT_TTL_MS ||
      (o.method === 'enrollment' ? o.reservation_id !== '' : !id(o.reservation_id)))) throw new SyntaxError('Executor transport bounds');
  return o;
}
export function executorCanonical(kind: ExecutorKind, value: ExecutorDocument): string {
  const o = executorParse(JSON.stringify(value), kind);
  return 'heimdall-executor/' + kind + '/v1\n' + executorSchemas[kind].filter(([,type]) => type !== 'signature').map(([name]) => new TextEncoder().encode(o[name]).length + ':' + o[name] + ',').join('');
}
export async function executorChildResultMatches(result: ExecutorDocument, request: ExecutorDocument, body: string, ownerKey: OwnerVerifiedKey, now: number | bigint): Promise<boolean> {
  try {
    if (!await executorVerify('child_result',result,ownerKey)) return false;
    executorParse(JSON.stringify(request),'child_request');
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','reservation_id','owner_incarnation','executor_incarnation','prepare_digest','input_digest']) {
      if (result[name] !== request[name]) return false;
    }
    return result.request_digest === await ownerPayloadDigest(executorCanonical('child_request',request)) && result.result_digest === await ownerPayloadDigest(body) &&
      BigInt(now) >= BigInt(result.issued_ms) && BigInt(result.issued_ms) >= BigInt(request.issued_ms) &&
      BigInt(now) < BigInt(result.request_expires_ms) && BigInt(result.request_expires_ms) <= BigInt(request.request_expires_ms);
  } catch { return false; }
}

const unhex = (hex: string): Uint8Array<ArrayBuffer> => Uint8Array.from(hex.match(/../g) ?? [], (pair) => parseInt(pair,16));
export async function executorVerify(kind: ExecutorKind, value: ExecutorDocument, key: OwnerVerifiedKey): Promise<boolean> {
  try {
    const o = executorParse(JSON.stringify(value), kind);
    const principal = kind === 'notification_result' || kind === 'notification_fence_request' || kind === 'policy' || kind === 'receipt' || kind === 'fence_request' || kind === 'enrollment' || kind === 'issuance_receipt' || kind === 'directory' || kind === 'child_request' || kind === 'local_result' ? o.executor_bridge_id : kind === 'issuance_consent' || kind === 'local_launch' || kind === 'local_draft' ? o.principal_id : o.owner_bridge_id;
    if (!key.enrolled || key.revoked || key.kind !== (kind === 'issuance_consent' || kind === 'local_launch' || kind === 'local_draft' ? 'device' : 'bridge') || key.account_id !== o.account_id ||
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
        !await executorVerify('action',action,ownerKey) || !['activate','heartbeat'].includes(action.method)) return false;
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


export async function executorQueryReceiptMatches(r: ExecutorDocument, q: ExecutorDocument, key: OwnerVerifiedKey, now: bigint, launchKey: string): Promise<boolean> {
  try {
    executorParse(JSON.stringify(q),'action');
    executorParse(JSON.stringify(r),'receipt');
    if (q.method !== 'query' || r.method !== 'query' || r.historical !== '0' || !await executorVerify('receipt',r,key) ||
      now < 0n || now >= BigInt(q.request_expires_ms) || BigInt(r.executor_incarnation) < BigInt(q.executor_incarnation) ||
      r.child_incarnation !== q.executor_incarnation || r.launch_key !== launchKey) return false;
    for (const name of ['account_id','executor_bridge_id','owner_bridge_id','chain_id','reservation_id','operation_id','grant_generation','prepare_digest','hard_ms'])
      if (r[name] !== q[name]) return false;
    return r.input_digest === await ownerPayloadDigest(executorCanonical('action',q));
  } catch { return false; }
}

export async function executorIssuanceMatches(receipt: ExecutorDocument, consent: ExecutorDocument, selectionRaw: string,
  configurationRaw: string, enrollment: ExecutorDocument, deviceKey: OwnerVerifiedKey, executorKey: OwnerVerifiedKey,
  now: bigint, currentAdmission = true): Promise<boolean> {
  try {
    const selection = executorParse(selectionRaw,'issuance_selection');
    const c = ownerParse(configurationRaw,'remote_configuration');
    if (!await executorVerify('issuance_consent',consent,deviceKey) || !await executorVerify('issuance_receipt',receipt,executorKey) ||
        !await executorEnrollmentMatches(enrollment,configurationRaw,executorKey,now,currentAdmission)) return false;
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','task_id','operation_id','principal_id'])
      if (receipt[name] !== consent[name]) return false;
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','executor_key_id','chain_id','task_id','agent_id','configuration_revision'])
      if (c[name] !== consent[name]) return false;
    for (const name of ['provider','model','provider_profile','directory_id','policy_revision','slot_id'])
      if (c[name] !== selection[name]) return false;
    return consent.selection_digest === await ownerPayloadDigest(selectionRaw) &&
      receipt.request_digest === await ownerPayloadDigest(executorCanonical('issuance_consent',consent)) &&
      receipt.configuration_digest === await ownerPayloadDigest(configurationRaw) &&
      receipt.enrollment_digest === await ownerPayloadDigest(executorCanonical('enrollment',enrollment)) &&
      (!currentAdmission || (now >= BigInt(consent.issued_ms) && now < BigInt(consent.request_expires_ms) &&
        now >= BigInt(receipt.issued_ms) && now < BigInt(receipt.request_expires_ms)));
  } catch { return false; }
}

/** The caller pins launchKey from the accepted executor reservation. */
export async function executorBootstrapMatches(b: ExecutorDocument, p: ExecutorDocument, a: ExecutorDocument,
  configurationRaw: string, bodyRaw: string, launchKey: string, ownerKey: OwnerVerifiedKey, now: bigint): Promise<boolean> {
  try {
    const c = ownerParse(configurationRaw,'remote_configuration');
    executorParse(bodyRaw,'bootstrap_content');
    if (!await executorVerify('bootstrap',b,ownerKey) || !await executorVerify('prepare',p,ownerKey) ||
        !await executorVerify('action',a,ownerKey) || a.method !== 'activate' || p.owner_bridge_id === p.executor_bridge_id ||
        !/^[0-9a-f]{64}$/.test(launchKey) || b.launch_key !== launchKey || bodyRaw === '' ||
        new TextEncoder().encode(bodyRaw).length > EXECUTOR_DOCUMENT_MAX) return false;
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','task_id','lease_id',
      'reservation_id','instance_id','launch_epoch','run_count','token_generation','configuration_revision','grant_generation',
      'owner_incarnation','executor_incarnation','hard_ms']) if (b[name] !== p[name]) return false;
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','task_id',
      'instance_id','launch_epoch','run_count','token_generation','configuration_revision','executor_incarnation','policy_revision','slot_id',
      'provider_profile','directory_key']) if (p[name] !== c[name]) return false;
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','reservation_id',
      'owner_incarnation','executor_incarnation','grant_generation','deadline_version','expires_ms','hard_ms']) if (b[name] !== a[name]) return false;
    const pd = await ownerPayloadDigest(executorCanonical('prepare',p));
    return b.prepare_digest === pd && a.prepare_digest === pd && b.action_digest === await ownerPayloadDigest(executorCanonical('action',a)) &&
      b.configuration_digest === await ownerPayloadDigest(configurationRaw) && b.body_digest === await ownerPayloadDigest(bodyRaw) &&
      now >= BigInt(b.issued_ms) && now < BigInt(b.request_expires_ms) && now < BigInt(a.request_expires_ms) && now < BigInt(a.expires_ms);
  } catch { return false; }
}

/** The caller supplies its currently accepted bootstrap and checks owner state. */
export async function executorChildRequestMatches(r: ExecutorDocument, b: ExecutorDocument, inputRaw: string,
  executorKey: OwnerVerifiedKey, ownerKey: OwnerVerifiedKey, now: bigint, renewal?: ExecutorDocument): Promise<boolean> {
  try {
    if (!await executorVerify('child_request',r,executorKey) || !await executorVerify('bootstrap',b,ownerKey) ||
        b.owner_bridge_id === b.executor_bridge_id) return false;
    if (renewal) {
      if (!await executorVerify('action',renewal,ownerKey) || renewal.method !== 'heartbeat') return false;
      for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','reservation_id',
        'grant_generation','owner_incarnation','executor_incarnation','prepare_digest','hard_ms']) if (renewal[name] !== b[name]) return false;
      if (BigInt(renewal.deadline_version) <= BigInt(b.deadline_version) || BigInt(renewal.expires_ms) < BigInt(b.expires_ms) ||
          r.deadline_version !== renewal.deadline_version || r.expires_ms !== renewal.expires_ms) return false;
    } else if (r.deadline_version !== b.deadline_version || r.expires_ms !== b.expires_ms) return false;
    for (const name of ['protocol_version','account_id','owner_bridge_id','executor_bridge_id','chain_id','task_id','lease_id',
      'reservation_id','instance_id','launch_epoch','run_count','token_generation','configuration_revision','grant_generation',
      'owner_incarnation','executor_incarnation','prepare_digest','launch_key','hard_ms']) {
      if (r[name] !== b[name]) return false;
    }
    if (r.bootstrap_digest !== await ownerPayloadDigest(executorCanonical('bootstrap',b)) || r.input_digest !== await ownerPayloadDigest(inputRaw)) return false;
    let input;
    try { input = ownerParse(inputRaw,'lease_input'); } catch { input = ownerParse(inputRaw,'lifecycle_input'); }
    for (const name of ['chain_id','task_id','lease_id','configuration_revision']) if (input[name] !== r[name]) return false;
    return now >= BigInt(r.issued_ms) && BigInt(r.issued_ms) >= BigInt(b.issued_ms) && now < BigInt(r.request_expires_ms);
  } catch { return false; }
}

/** Local startup observation only; this grants no owner task authority. */
export interface ExecutorReadinessAck { accepted: boolean; ready_ms: string }
