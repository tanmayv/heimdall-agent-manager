import { ownerSubmissionRoute } from '../../utils/ownerSubmissionNavigation';
import type { TaskChainSearchHit } from '../../utils/taskChainSearch';
import { isVaultArmored } from '../../utils/vaultContent';
import type { OwnerChainSummary } from '../../api/ownerChains';

/** A flat (ungrouped) recent task chain row on the home view. */
export interface HomeChainItem {
  chainId: string;
  title: string;
  status: string;
  projectId: string;
  projectName: string;
  updatedAt: string;
  coordinatorAgentInstanceId?: string;
  submissionRoute?: string;
  /** Unique per row: a chain can have several search matches. */
  rowKey?: string;
  /** What matched inside the chain (search rows only). */
  matchLabel?: string;
  /** False for the second and later matches of the same chain. */
  firstInGroup?: boolean;
  /** Set for Bridge-owned chains. */
  owner?: { bridgeId: string; bridgeName: string; online: boolean };
}

/** The owner registry's chains as home rows (every chain is Bridge-owned). */
export function homeChainsFromOwners(owners: OwnerChainSummary[]): HomeChainItem[] {
  return owners.map((o): HomeChainItem => ({
    chainId: o.chainId, title: o.title || '', status: o.status || '', updatedAt: '',
    projectId: o.projectId || '', projectName: o.projectName || '',
    owner: { bridgeId: o.ownerBridgeId, bridgeName: o.bridgeName, online: o.online },
    // The bound coordinator (owner member rows) once read; a row opens its conversation.
    ...(o.coordinatorAgentInstanceId ? { coordinatorAgentInstanceId: o.coordinatorAgentInstanceId } : {}),
  }));
}

const MATCH_KIND_LABELS: Record<string, string> = {
  chain: 'Chain', task: 'Ticket', requirements: 'Requirements', comment: 'Comment', handoff: 'Handoff',
  archived_task: 'Archived workflow stage', message: 'Message', workflow: 'Workflow', source: 'Source',
};

/** "Ticket: Fix login", "Comment", "Submission attempt 2", "… (status not checked)". */
export function searchMatchLabel(hit: TaskChainSearchHit): string {
  const kind = hit.kind || '';
  let label = kind === 'output' ? `Submission attempt ${hit.attempt}` : (MATCH_KIND_LABELS[kind] || '');
  if (label && hit.match_title && kind !== 'chain' && kind !== 'output') label += ': ' + hit.match_title;
  if (hit.filters_unverified?.length) label += (label ? ' ' : '') + `(${hit.filters_unverified.join(' and ')} not checked)`;
  return label;
}

export const HOME_RECENT_CHAIN_LIMIT = 10;
export const HOME_REMOTE_SEARCH_MIN_CHARS = 2;

/**
 * Local search over loaded chains (vault-safe: armored titles / project names
 * never match; a decrypted title from the title cache does).
 */
export function filterHomeChains(
  chains: HomeChainItem[],
  query: string,
  decryptedTitles: Record<string, { decryptedTitle?: string } | undefined> = {},
  limit = HOME_RECENT_CHAIN_LIMIT,
): HomeChainItem[] {
  const q = query.trim().toLowerCase();
  const matches = q
    ? chains.filter((c) => {
        const title = decryptedTitles[c.chainId]?.decryptedTitle || c.title || '';
        if (title && !isVaultArmored(title) && title.toLowerCase().includes(q)) return true;
        if (c.chainId.toLowerCase().includes(q)) return true;
        return Boolean(c.projectName && !isVaultArmored(c.projectName) && c.projectName.toLowerCase().includes(q));
      })
    : chains;
  return matches.slice(0, limit);
}

/**
 * Bridge search hits -> home rows, one row per match. Matches of one chain stay
 * together (the first carries the chain heading). Hits carry no coordinator,
 * so it (and the project name) is filled in from the loaded chain list when
 * known. `limit` counts chains, not matches.
 */
export function homeChainsFromSearchHits(
  hits: TaskChainSearchHit[],
  loaded: HomeChainItem[],
  limit = HOME_RECENT_CHAIN_LIMIT,
): HomeChainItem[] {
  const byId = new Map(loaded.map((c) => [c.chainId, c]));
  const projectNames = new Map(loaded.map((c) => [c.projectId, c.projectName]));
  const order: string[] = [];
  const groups = new Map<string, TaskChainSearchHit[]>();
  for (const hit of hits) {
    if (!groups.has(hit.chain_id)) { groups.set(hit.chain_id, []); order.push(hit.chain_id); }
    groups.get(hit.chain_id)!.push(hit);
  }
  return order.slice(0, limit).flatMap((chainId) => groups.get(chainId)!.map((hit, i) => {
    const known = byId.get(hit.chain_id);
    const owner = hit.owner_bridge_id
      ? { bridgeId: hit.owner_bridge_id, bridgeName: known?.owner?.bridgeName || hit.owner_bridge_id, online: hit.owner_online !== false }
      : known?.owner;
    return {
      chainId: hit.chain_id,
      title: hit.title || known?.title || '',
      submissionRoute: ownerSubmissionRoute(hit),
      status: String(hit.status || known?.status || '').toLowerCase(),
      projectId: hit.project_id || known?.projectId || '',
      projectName: known?.projectName || projectNames.get(hit.project_id) || '',
      updatedAt: hit.updated_at || known?.updatedAt || '',
      coordinatorAgentInstanceId: known?.coordinatorAgentInstanceId,
      rowKey: [hit.chain_id, hit.kind || '', hit.task_id || '', hit.attempt || '', String(i)].join('\u0000'),
      matchLabel: searchMatchLabel(hit),
      firstInGroup: i === 0,
      ...(owner ? { owner } : {}),
    };
  }));
}
