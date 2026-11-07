// Bridge-owned ("owner-local") task chains in the ordinary UI (R4b).
//
// The Hub's owner registry (/api/v1/owner-local/chains) is routing metadata
// only: chain/task titles arrive sealed and are decrypted here with the vault
// keyring; everything else is read from the owner Bridge through signed,
// encrypted owner operations (ownerLocalClient). Nothing in this module trusts
// a Hub copy of an owner chain: a migrated chain's frozen Hub copy only lends
// its project placement to the owner row and is otherwise dropped.

import { cookieJsonFetch, cookieMutation } from './cookieFetch';
import { listOwnerRegistryPages, type OwnerRegistryPage } from './ownerRegistryListing';
import { ownerId, prepareOwnerOperation, sendOwnerOperation, type OwnerInput, type OwnerSession } from './ownerLocalClient';
import type { OwnerCommand } from './ownerLocal';
import { decryptVaultText } from '../utils/vaultContent';
import { pinsFromChain, verifyDirectory, type VerifiedChain } from '../utils/vaultDirectoryVerify';
import { getKeyringSession } from '../utils/vaultKeyringSession';
import type { ChainListItem } from './endpoints/tasks';

export interface OwnerChainTaskTitle { taskId: string; title: string }
export interface OwnerChainSummary {
  chainId: string;
  ownerBridgeId: string;
  bridgeName: string;
  online: boolean;
  title: string;
  description: string;
  /** Titles could not be opened with the current keyring. */
  sealed: boolean;
  tasks: OwnerChainTaskTitle[];
  /** Carried from a migrated chain's frozen Hub copy; empty for native chains. */
  projectId: string;
  projectName: string;
  /** A frozen Hub copy of this chain exists (it was moved to its Bridge). */
  migrated: boolean;
  /** Created here; the owner has not published its registry entry yet. */
  pending?: boolean;
  /** The owner's work status; '' or absent when unknown (owner offline or not read). */
  status?: OwnerChainStatus;
}
export type OwnerChainStatus = '' | 'active' | 'completed';

/** Fixed sends for the owner relay; replaced in tests. */
export type OwnerSend = (relay: unknown) => Promise<unknown>;
export const ownerRelaySend: OwnerSend = (relay) => cookieMutation('/api/v1/owner-local/relay', 'POST', relay);

/** The enrolled-device label of a Bridge, else its id. */
export function ownerBridgeName(chain: VerifiedChain | undefined, bridgeId: string): string {
  if (!chain) return bridgeId;
  for (const d of chain.trusted.values()) {
    if (d.kind === 'bridge' && d.row.bridge_id === bridgeId) return String(d.row.label || bridgeId);
  }
  return bridgeId;
}

/** The current session re-verified against the live device directory. */
export async function freshOwnerSession(): Promise<OwnerSession> {
  const s = getKeyringSession();
  if (!s) throw new Error('Unlock the vault first');
  const chain = await verifyDirectory(await cookieJsonFetch('/api/v1/vault/directory'), s.identity.userId, pinsFromChain(s.chain));
  if (getKeyringSession() !== s || chain.currentEpoch !== s.keyring.currentEpoch) throw new Error('Vault session changed; refresh it first');
  return { ...s, chain };
}

async function openTitle(cipher: string, session: OwnerSession): Promise<string | null> {
  if (!cipher) return '';
  try { return await decryptVaultText(cipher, session.keyring); } catch { return null; }
}

/**
 * Every registry row (paged past 100), grouped per chain with sealed titles
 * opened client-side. Tombstoned or unparsable rows are skipped.
 */
export async function loadOwnerChainSummaries(
  session: OwnerSession,
  fetchPage: (path: string) => Promise<OwnerRegistryPage> = cookieJsonFetch,
  current: () => boolean = () => true,
): Promise<OwnerChainSummary[]> {
  const rows = await listOwnerRegistryPages(fetchPage, current);
  const byChain = new Map<string, { chain?: any; tasks: any[] }>();
  for (const row of rows) {
    if (!row || typeof row.chain_id !== 'string' || !row.chain_id) continue;
    const entry = byChain.get(row.chain_id) ?? { tasks: [] };
    if (row.task_id) entry.tasks.push(row); else entry.chain = row;
    byChain.set(row.chain_id, entry);
  }
  const out: OwnerChainSummary[] = [];
  for (const [chainId, entry] of byChain) {
    const head = entry.chain ?? entry.tasks[0];
    let registry: any = {};
    try { registry = JSON.parse(String(head.registry_json || '{}')); } catch { continue; }
    if (registry.deleted === '1') continue;
    const title = await openTitle(String(registry.chain_title_cipher || ''), session);
    const description = await openTitle(String(registry.chain_description_cipher || ''), session);
    const tasks: OwnerChainTaskTitle[] = [];
    let sealed = title === null;
    for (const t of entry.tasks) {
      let r: any = {};
      try { r = JSON.parse(String(t.registry_json || '{}')); } catch { continue; }
      if (r.deleted === '1') continue;
      const taskTitle = await openTitle(String(r.task_title_cipher || ''), session);
      if (taskTitle === null) sealed = true;
      tasks.push({ taskId: String(t.task_id), title: taskTitle ?? '' });
    }
    tasks.sort((a, b) => a.taskId.localeCompare(b.taskId));
    out.push({
      chainId, ownerBridgeId: String(head.owner_bridge_id || ''), bridgeName: ownerBridgeName(session.chain, String(head.owner_bridge_id || '')),
      online: head.online === true, title: title ?? '', description: description ?? '', sealed, tasks,
      projectId: '', projectName: '', migrated: false,
    });
  }
  return out.sort((a, b) => (a.title || a.chainId).localeCompare(b.title || b.chainId) || a.chainId.localeCompare(b.chainId));
}

/**
 * Owner chains own their identity: a Hub row with the same id is the frozen
 * copy left by migration. Drop it, keep its project placement on the owner row.
 *
 * Limitation: the Hub chain list carries no migration state client-side, so
 * this dedupe keys on the live registry. If the owner registry tombstones a
 * moved chain (deleted on its Bridge), its frozen Hub copy is listed again.
 * R4a's `authority:{kind:"owner"}` on /task-chains is the durable fix.
 */
export function mergeOwnerChains<T extends { chainId: string; projectId?: string; projectName?: string }>(
  hubChains: T[], owners: OwnerChainSummary[],
): { hub: T[]; owners: OwnerChainSummary[] } {
  const ids = new Set(owners.map((o) => o.chainId));
  const copies = new Map<string, T>();
  const hub = hubChains.filter((c) => {
    if (!ids.has(c.chainId)) return true;
    copies.set(c.chainId, c);
    return false;
  });
  return {
    hub,
    owners: owners.map((o) => {
      const copy = copies.get(o.chainId);
      return copy ? { ...o, migrated: true, projectId: o.projectId || copy.projectId || '', projectName: o.projectName || copy.projectName || '' } : o;
    }),
  };
}

/** An owner chain as an ordinary chain-list row (status is not in the registry). */
export function ownerChainListItem(o: OwnerChainSummary): ChainListItem & { owner: OwnerChainSummary } {
  return {
    chainId: o.chainId, title: o.title, status: '', kind: 'ticket', updatedAt: '', coordinatorAgentInstanceId: '',
    projectId: o.projectId, projectName: o.projectName, taskCount: o.tasks.length, completedTaskCount: 0,
    userValidationCount: 0, hasUserValidation: false, isPinned: false, pinnedAt: '', owner: o,
  };
}

/* Owner operations ----------------------------------------------------- */

/**
 * Methods whose expected_revision is the TASK revision on the owner
 * (src/lib/owner_local/store.odin, execute()); every other method, task.create
 * included, is checked against the CHAIN revision.
 */
export const OWNER_TASK_REVISION_METHODS: ReadonlySet<string> = new Set([
  'task.publish', 'task.priority', 'native.history.import', 'native.history.read', 'native.history.fetch', 'attempt.read',
  'dependency.edit', 'review.roles', 'task.hold', 'task.release', 'task.cancel', 'task.reopen', 'task.resolve', 'merge.retry',
  'submission.read', 'task.edit', 'task.delete', 'task.comment', 'task.read', 'fleet.edit', 'fleet.reserve', 'runtime.read',
  'lifecycle.configure', 'requirements.edit', 'review.post',
]);
export function ownerExpectedRevision(method: string, chainRevision: string, taskRevision: string): string {
  return OWNER_TASK_REVISION_METHODS.has(method) ? taskRevision : chainRevision;
}

/** The owner's work status of a chain (work.read). */
export async function readOwnerChainStatus(session: OwnerSession, bridgeId: string, chainId: string, send: OwnerSend = ownerRelaySend): Promise<OwnerChainStatus> {
  const data = await ownerCall(session, bridgeId, 'work.read', { chainId, expectedRevision: '0', cursor: '', limit: 1 }, send);
  return data.status === 'active' || data.status === 'completed' ? data.status : '';
}

/**
 * Statuses for the online chains of a listing, bounded at four concurrent owner
 * reads. Offline or failing chains stay unknown ('').
 */
export async function readOwnerChainStatuses(
  session: OwnerSession, chains: OwnerChainSummary[], send: OwnerSend = ownerRelaySend, current: () => boolean = () => true,
): Promise<Map<string, OwnerChainStatus>> {
  const out = new Map<string, OwnerChainStatus>();
  const queue = chains.filter((c) => c.online && !c.pending);
  await Promise.all(Array.from({ length: Math.min(4, queue.length) }, async () => {
    for (let c = queue.shift(); c; c = queue.shift()) {
      if (!current()) return;
      try { out.set(c.chainId, await readOwnerChainStatus(session, c.ownerBridgeId, c.chainId, send)); } catch { out.set(c.chainId, ''); }
    }
  }));
  return out;
}

const OWNER_ERROR_TEXT: Record<string, string> = {
  invalid_scope: 'This device has no access to that chain or task on its owner Bridge.',
  stale_revision: 'The chain changed on its owner Bridge. It has been reloaded; try again.',
  operation_conflict: 'The owner Bridge refused this change in the task’s current state.',
  clock_uncertain: 'The owner Bridge’s clock needs recovery before it accepts changes.',
  retention_capacity: 'The owner Bridge has reached its history capacity.',
  invalid_content: 'The owner Bridge rejected the content (too large or invalid).',
  storage_error: 'The owner Bridge could not read or write its store.',
  retired: 'That item was deleted on the owner Bridge.',
  stale_cursor: 'The list changed while paging. Reload to see the current state.',
  malformed: 'The owner Bridge rejected a malformed request.',
  bad_signature: 'The owner Bridge rejected this device’s signature.',
  digest_mismatch: 'The owner Bridge rejected a request that did not match its signature.',
  expired: 'The request expired before the owner Bridge received it. Try again.',
  revoked: 'This device has been revoked.',
};

export function isOwnerOffline(error: unknown): boolean {
  return error instanceof Error && error.message === 'owner_unavailable';
}

/** Human text for an owner failure; never a raw code or JSON blob. */
export function ownerErrorMessage(error: unknown, bridgeName = 'the owner Bridge'): string {
  if (isOwnerOffline(error)) return ownerOfflineMessage(bridgeName);
  const raw = error instanceof Error ? error.message : String(error ?? '');
  if (OWNER_ERROR_TEXT[raw]) return OWNER_ERROR_TEXT[raw];
  if (/^Unlock the vault|^Vault session changed|^Device and owner must be|limited to \d+ UTF-8|^Search requires|^Invalid work document/.test(raw)) return raw;
  if (/^[a-z_]+$/.test(raw)) return `The owner Bridge refused the request (${raw.replaceAll('_', ' ')}).`;
  return 'The owner Bridge request failed. Try again.';
}
export function ownerOfflineMessage(bridgeName: string): string {
  return `Owner Bridge ${bridgeName} is offline — details and changes unavailable`;
}

/** One signed, encrypted owner operation; the parsed result body. */
export async function ownerCall(
  session: OwnerSession, bridgeId: string, method: OwnerCommand['method'], input: OwnerInput, send: OwnerSend = ownerRelaySend,
): Promise<any> {
  const op = await prepareOwnerOperation(session, bridgeId, method, input);
  const result = await sendOwnerOperation(session, op, send);
  return result.body ? JSON.parse(result.body) : {};
}

/** Creates an owner chain with a device-signed genesis; resolves its id. */
export async function createOwnerChain(
  session: OwnerSession, bridgeId: string, input: { title: string; description: string }, send: OwnerSend = ownerRelaySend,
): Promise<string> {
  const chainId = ownerId('chain_');
  await ownerCall(session, bridgeId, 'chain.create', { chainId, expectedRevision: '0', title: input.title, description: input.description }, send);
  return chainId;
}

export interface OwnerTaskRow { task_id: string; title: string; revision: string; priority: string }
export interface OwnerChainDetail { title: string; description: string; revision: string; tasks: OwnerTaskRow[]; truncated: boolean }
export interface OwnerComment { operation_id: string; principal_id: string; body: string; seq: string; created_at: string }
export interface OwnerTaskDetail { title: string; body: string; priority: string; revision: string; comments: OwnerComment[]; truncated: boolean }

const MAX_PAGES = 10;

export async function readOwnerChain(session: OwnerSession, bridgeId: string, chainId: string, send: OwnerSend = ownerRelaySend): Promise<OwnerChainDetail> {
  let cursor = '', first: any = null;
  const tasks: OwnerTaskRow[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const data = await ownerCall(session, bridgeId, 'chain.read', { chainId, expectedRevision: '0', cursor }, send);
    first ??= data;
    for (const t of Array.isArray(data.items) ? data.items : []) tasks.push({ task_id: String(t.task_id), title: String(t.title ?? ''), revision: String(t.revision ?? ''), priority: String(t.priority ?? 'p2') });
    cursor = String(data.next_cursor || '');
    if (!cursor) break;
  }
  return { title: String(first?.title ?? ''), description: String(first?.description ?? ''), revision: String(first?.revision ?? '0'), tasks, truncated: Boolean(cursor) };
}

export async function readOwnerTask(session: OwnerSession, bridgeId: string, chainId: string, taskId: string, send: OwnerSend = ownerRelaySend): Promise<OwnerTaskDetail> {
  let cursor = '', first: any = null;
  const comments: OwnerComment[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const data = await ownerCall(session, bridgeId, 'task.read', { chainId, taskId, expectedRevision: '0', cursor }, send);
    first ??= data;
    for (const c of Array.isArray(data.items) ? data.items : []) comments.push({ operation_id: String(c.operation_id), principal_id: String(c.principal_id ?? ''), body: String(c.body ?? ''), seq: String(c.seq ?? ''), created_at: String(c.created_at ?? '') });
    cursor = String(data.next_cursor || '');
    if (!cursor) break;
  }
  return { title: String(first?.title ?? ''), body: String(first?.body ?? ''), priority: String(first?.priority ?? 'p2'), revision: String(first?.revision ?? '0'), comments, truncated: Boolean(cursor) };
}

export interface OwnerRuntime {
  revision: string;
  lifecycle: string; attempt: string;
  control: { mode: string; reason: string; waitingOn: string } | null;
  leased: boolean;
  requirements: { revision: string; goal: string; acceptance: string[]; raw: string } | null;
  submission: { attempt: string; head: string; requirementsRevision: string; summary: string; author: string } | null;
  attemptNo: number;
}

function parseBrief(raw: string): { goal: string; acceptance: string[] } {
  try {
    const b = JSON.parse(raw);
    return { goal: String(b?.goal ?? ''), acceptance: Array.isArray(b?.acceptance) ? b.acceptance.map(String) : [] };
  } catch { return { goal: '', acceptance: [] }; }
}

export function parseOwnerRuntime(data: any): OwnerRuntime {
  const row = (name: string): string[] | null => (Array.isArray(data?.[name]) && Array.isArray(data[name][0]) ? data[name][0].map(String) : null);
  const state = row('state'), controls = row('controls'), req = row('requirements'), sub = row('submission');
  return {
    revision: String(data?.revision ?? '0'),
    lifecycle: state?.[0] ?? 'ready', attempt: state?.[1] ?? '0',
    control: controls ? { mode: controls[0], reason: controls[2] ?? '', waitingOn: controls[3] ?? '' } : null,
    leased: Array.isArray(data?.leases) && data.leases.length > 0,
    requirements: req ? { revision: req[0], raw: req[1] ?? '', ...parseBrief(req[1] ?? '') } : null,
    submission: sub ? { attempt: sub[0], head: sub[1] ?? '', requirementsRevision: sub[2] ?? '', summary: sub[3] ?? '', author: sub[4] ?? '' } : null,
    attemptNo: Number(data?.attempts?.attempt_no ?? 0) || 0,
  };
}

export async function readOwnerRuntime(session: OwnerSession, bridgeId: string, chainId: string, taskId: string, send: OwnerSend = ownerRelaySend): Promise<OwnerRuntime> {
  return parseOwnerRuntime(await ownerCall(session, bridgeId, 'runtime.read', { chainId, taskId, expectedRevision: '0' }, send));
}

export type OwnerTaskState = 'ready' | 'in_progress' | 'in_review' | 'done' | 'cancelled';
/** Owner lifecycle + controls in the five ordinary ticket states, plus flags. */
export function ownerTaskState(rt: OwnerRuntime): { state: OwnerTaskState; held: boolean; blocked: boolean; merge: string } {
  const mode = rt.control?.mode ?? 'ready';
  let state: OwnerTaskState = 'ready';
  if (mode === 'cancelled') state = 'cancelled';
  else if (rt.lifecycle === 'done') state = 'done';
  else if (rt.lifecycle === 'in_review' || rt.lifecycle === 'merge_pending' || rt.lifecycle === 'merge_blocked') state = 'in_review';
  else if (rt.leased) state = 'in_progress';
  return { state, held: mode === 'held', blocked: mode === 'blocked', merge: rt.lifecycle.startsWith('merge_') ? rt.lifecycle : '' };
}

export interface OwnerReview {
  source: 'archived' | 'owner';
  attempt: string; verdict: string; reviewer: string; role: string; summary: string; at: string;
}

/** Reviews carried over verbatim from the Hub at migration (none for native chains). */
export async function readArchivedReviews(session: OwnerSession, bridgeId: string, chainId: string, taskId: string, send: OwnerSend = ownerRelaySend): Promise<OwnerReview[]> {
  const out: OwnerReview[] = [];
  let cursor = '';
  for (let page = 0; page < MAX_PAGES; page++) {
    let data: any;
    try {
      data = await ownerCall(session, bridgeId, 'migration.archive.read', { chainId, expectedRevision: '0', archiveKind: 'review', archiveTaskId: taskId, cursor, limit: 50 }, send);
    } catch (e) {
      // A native chain has no migration import to read.
      if (e instanceof Error && e.message === 'invalid_scope' && page === 0) return [];
      throw e;
    }
    for (const item of Array.isArray(data.items) ? data.items : []) {
      let r: any = {};
      try { r = JSON.parse(String(item.record || '{}')); } catch { continue; }
      let findings = '';
      try {
        const parsed = JSON.parse(String(r.findings_json || '[]'));
        findings = Array.isArray(parsed) ? parsed.map((f: any) => (typeof f === 'string' ? f : String(f?.note ?? f?.summary ?? f?.text ?? JSON.stringify(f)))).join('\n') : '';
      } catch { findings = ''; }
      out.push({
        source: 'archived', attempt: String(r.attempt_no ?? ''), verdict: String(r.verdict ?? ''),
        reviewer: r.reviewer_kind === 'user' ? 'You' : String(r.reviewer_agent_id || r.reviewer_instance_id || 'Agent'),
        role: String(r.role ?? ''), summary: findings, at: String(r.created_at ?? ''),
      });
    }
    cursor = String(data.next_cursor || '');
    if (!cursor) break;
  }
  return out;
}

export const OWNER_REVIEW_KEEP = 20;
export const OWNER_HISTORY_PAGE = 100;
export const OWNER_HISTORY_MAX_PAGES = 200;

/**
 * Reviews recorded on the owner, from its accepted event history. The history
 * is oldest-first, so it is paged to the end (100 events per page) keeping a
 * ring buffer of the latest matching review events. `truncated` is set when the
 * page cap stopped the scan before the end (newer reviews may be missing);
 * `more` when older reviews were dropped from the buffer.
 */
export async function readOwnerReviews(
  session: OwnerSession, bridgeId: string, chainId: string, taskId: string, send: OwnerSend = ownerRelaySend,
  keep = OWNER_REVIEW_KEEP, maxPages = OWNER_HISTORY_MAX_PAGES,
): Promise<{ reviews: OwnerReview[]; truncated: boolean; more: boolean }> {
  const events: any[] = [];
  let cursor = '', dropped = false;
  for (let page = 0; page < maxPages; page++) {
    const data = await ownerCall(session, bridgeId, 'history.read', { chainId, expectedRevision: '0', cursor, limit: OWNER_HISTORY_PAGE }, send);
    for (const e of Array.isArray(data.items) ? data.items : []) {
      if (e.task_id === taskId && (e.kind === 'review.post' || e.kind === 'review.role.post')) {
        events.push(e);
        if (events.length > keep) { events.shift(); dropped = true; }
      }
    }
    cursor = String(data.next_cursor || '');
    if (!cursor) break;
  }
  const reviews: OwnerReview[] = [];
  for (const e of events) {
    let evidence = '', offset = '0';
    for (let chunk = 0; chunk < 8; chunk++) {
      const part = await ownerCall(session, bridgeId, 'history.fetch', { chainId, expectedRevision: '0', eventSeq: String(e.seq), offset }, send);
      evidence += String(part.evidence ?? '');
      offset = String(part.next_offset || '');
      if (!offset) break;
    }
    let payload: any = {};
    try { payload = JSON.parse(String(JSON.parse(evidence).payload || '{}')); } catch { payload = {}; }
    const ms = Number(e.ts_ms);
    reviews.push({
      source: 'owner', attempt: String(payload.attempt ?? ''), verdict: String(payload.verdict ?? ''),
      reviewer: e.actor_kind === 'agent' ? String(e.actor_id || 'Agent') : (e.actor_id === session.identity.deviceId ? 'You' : 'Device ' + String(e.actor_id || '').slice(0, 8)),
      role: String(payload.role ?? ''), summary: String(payload.summary ?? ''), at: Number.isFinite(ms) && ms > 0 ? new Date(ms).toISOString() : '',
    });
  }
  // Newest first, like the rest of the view.
  return { reviews: reviews.reverse(), truncated: Boolean(cursor), more: dropped };
}

export interface OwnerSubmission { attempt: string; summary: string; head: string; author: string; requirementsRevision: string; complete: boolean }
export async function readOwnerSubmission(session: OwnerSession, bridgeId: string, chainId: string, taskId: string, attempt: string, send: OwnerSend = ownerRelaySend): Promise<OwnerSubmission> {
  let summary = '', offset = '0', first: any = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const data = await ownerCall(session, bridgeId, 'submission.read', { chainId, taskId, expectedRevision: '0', attempt, offset }, send);
    first ??= data;
    summary += String(data.summary ?? '');
    offset = String(data.next_offset || '');
    if (!offset) break;
  }
  return { attempt, summary, head: String(first?.head ?? ''), author: String(first?.author_agent_id ?? ''), requirementsRevision: String(first?.requirements_revision ?? ''), complete: !offset };
}

/* Placement ------------------------------------------------------------ */

export interface OwnerBridgeChoice { bridgeId: string; name: string; online: boolean }

/** Bridges enrolled in this vault (they can own chains), with their live status. */
export function ownerBridgeChoices(chain: VerifiedChain | undefined, bridgeRows: any[]): OwnerBridgeChoice[] {
  if (!chain) return [];
  const status = new Map<string, any>();
  for (const b of bridgeRows || []) status.set(String(b?.bridge_id || b?.bridgeId || b?.id || ''), b);
  const out: OwnerBridgeChoice[] = [];
  for (const d of chain.trusted.values()) {
    if (d.kind !== 'bridge' || !d.row.bridge_id) continue;
    const row = status.get(d.row.bridge_id);
    const online = Boolean(row) && !row.plan_disabled_at && !row.revoked_at && String(row.status || row.runtime_status || '').toLowerCase() === 'online';
    out.push({ bridgeId: d.row.bridge_id, name: String(row?.label || d.row.label || row?.machine_hostname || d.row.bridge_id), online });
  }
  return out.sort((a, b) => Number(b.online) - Number(a.online) || a.name.localeCompare(b.name));
}

/** Default placement: the first online enrolled Bridge, else the Hub. */
export function defaultChainPlacement(choices: OwnerBridgeChoice[]): string {
  return choices.find((c) => c.online)?.bridgeId ?? HUB_PLACEMENT;
}
export const HUB_PLACEMENT = 'hub';
