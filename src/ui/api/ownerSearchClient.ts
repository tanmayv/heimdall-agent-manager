import { ownerSubmissionRoute } from '../utils/ownerSubmissionNavigation.ts';
import { prepareOwnerOperation, sendOwnerOperation, type OwnerSession } from './ownerLocalClient.ts';
import { decryptVaultText } from '../utils/vaultContent.ts';

export interface OwnerSearchListing { chain_id: string; task_id: string; owner_bridge_id: string; online: boolean; registry_json: string }
export interface OwnerSearchHit {
  chain_id: string; project_id: string; status: string; updated_at: string;
  title: string; description: string; task_id?: string; kind?: string; attempt?: string; object_revision?: string; indexed_seq?: string;
  /** The matched object's own title (task title, archived stage key); '' for comments. */
  match_title?: string;
  owner_bridge_id?: string; owner_online?: boolean;
  /** Filters this local hit could not be checked against (no such owner metadata). */
  filters_unverified?: string[];
}
const KIND_ORDER = ['chain', 'task', 'requirements', 'comment', 'output', 'handoff', 'archived_task', 'message', 'workflow', 'source'];
const kindRank = (kind = '') => { const i = KIND_ORDER.indexOf(kind); return i < 0 ? KIND_ORDER.length : i; };

/** Keeps every hit of the first `limit` distinct chains, in order. */
export function limitHitsByChain<T extends { chain_id: string }>(hits: T[], limit: number): T[] {
  const chains = new Set<string>();
  return hits.filter((h) => {
    if (chains.has(h.chain_id)) return true;
    if (chains.size >= limit) return false;
    chains.add(h.chain_id);
    return true;
  });
}

// Queries the immutable owners rather than hedging between unrelated databases.
// The listing is routing input only: every query is independently device-signed
// and the owner intersects it with its current local grant. The listing may be
// any length (callers page the registry); concurrency stays bounded at four.
// Every hit of a chain is kept, grouped by chain (chain order is the listing's).
export async function searchOwnerChains(
  session: OwnerSession, rows: OwnerSearchListing[], query: string, limit: number,
  send: (body: unknown) => Promise<unknown>, signal?: AbortSignal,
): Promise<{ hits: OwnerSearchHit[]; ownedIds: Set<string>; stale: boolean }> {
  const chains = rows.filter((r) => !r.task_id);
  const groups: OwnerSearchHit[][] = chains.map(() => []);
  const ownedIds = new Set(rows.map((r) => r.chain_id));
  let stale = false, next = 0;
  // Bounded concurrency and output; no query/text crosses the Hub unsealed.
  await Promise.all(Array.from({ length: Math.min(4, chains.length) }, async () => {
    for (;;) {
      if (signal?.aborted) { stale = true; return; }
      const index = next++;
      const row = chains[index]; if (!row) return;
      if (!row.online) { stale = true; continue; }
      try {
        const op = await prepareOwnerOperation(session, row.owner_bridge_id, 'chain.search', { chainId: row.chain_id, expectedRevision: '0', query, limit });
        const result = JSON.parse((await sendOwnerOperation(session, op, send)).body);
        if (!result.hits?.length) continue;
        const registry = JSON.parse(row.registry_json);
        const title = await decryptVaultText(registry.chain_title_cipher, session.keyring);
        const group: OwnerSearchHit[] = [];
        for (const hit of result.hits) {
          if (hit.kind === "output" && !ownerSubmissionRoute(hit)) throw new Error("Historical output identity unavailable");
          group.push({ ...hit, match_title: String(hit.title ?? ''), title: hit.kind === 'output' ? title + ' — submission attempt ' + hit.attempt : title,
            project_id: '', status: '', updated_at: '', indexed_seq: result.indexed_seq, owner_bridge_id: row.owner_bridge_id, owner_online: true });
        }
        group.sort((a, b) => kindRank(a.kind) - kindRank(b.kind) || String(a.task_id ?? '').localeCompare(String(b.task_id ?? '')) || Number(a.attempt || 0) - Number(b.attempt || 0));
        groups[index] = group;
      } catch (error) {
        // Revocation is a denial, never a stale result fallback.
        if (error instanceof Error && error.message === 'invalid_scope') continue;
        stale = true;
      }
    }
  }));
  return { hits: limitHitsByChain(groups.flat(), limit), ownedIds, stale };
}
