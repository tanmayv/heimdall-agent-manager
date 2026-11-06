import { ownerSubmissionRoute } from '../utils/ownerSubmissionNavigation.ts';
import { prepareOwnerOperation, sendOwnerOperation, type OwnerSession } from './ownerLocalClient.ts';
import { decryptVaultText } from '../utils/vaultContent.ts';

export interface OwnerSearchListing { chain_id: string; task_id: string; owner_bridge_id: string; online: boolean; registry_json: string }
export interface OwnerSearchHit {
  chain_id: string; project_id: string; status: string; updated_at: string;
  title: string; description: string; task_id?: string; kind?: string; attempt?: string; object_revision?: string; indexed_seq?: string;
}
// Queries the immutable owners rather than hedging between unrelated databases.
// The listing is routing input only: every query is independently device-signed
// and the owner intersects it with its current local grant.
export async function searchOwnerChains(
  session: OwnerSession, rows: OwnerSearchListing[], query: string, limit: number,
  send: (body: unknown) => Promise<unknown>, signal?: AbortSignal,
): Promise<{ hits: OwnerSearchHit[]; ownedIds: Set<string>; stale: boolean }> {
  const chains = rows.filter((r) => !r.task_id);
  if (chains.length > 100) throw new Error('Owner search supports up to 100 chains per request');
  const hits: OwnerSearchHit[] = [];
  const ownedIds = new Set(rows.map((r) => r.chain_id));
  let stale = false, next = 0;
  // Bounded concurrency and output; no query/text crosses the Hub unsealed.
  await Promise.all(Array.from({ length: Math.min(4, chains.length) }, async () => {
    for (;;) {
      if (signal?.aborted) { stale = true; return; }
      const row = chains[next++]; if (!row) return;
      if (!row.online) { stale = true; continue; }
      try {
        const op = await prepareOwnerOperation(session, row.owner_bridge_id, 'chain.search', { chainId: row.chain_id, expectedRevision: '0', query, limit });
        const result = JSON.parse((await sendOwnerOperation(session, op, send)).body);
        if (!result.hits?.length) continue;
        const registry = JSON.parse(row.registry_json);
        const title = await decryptVaultText(registry.chain_title_cipher, session.keyring);
        const hit = result.hits[0];
        if (hit.kind === "output" && !ownerSubmissionRoute(hit)) throw new Error("Historical output identity unavailable");
        hits.push({ ...hit, title: hit.kind === 'output' ? title + ' — submission attempt ' + hit.attempt : title, project_id: '', status: '', updated_at: '', indexed_seq: result.indexed_seq });
      } catch (error) {
        // Revocation is a denial, never a stale result fallback.
        if (error instanceof Error && error.message === 'invalid_scope') continue;
        stale = true;
      }
    }
  }));
  hits.sort((a, b) => a.chain_id.localeCompare(b.chain_id));
  return { hits: hits.slice(0, limit), ownedIds, stale };
}
