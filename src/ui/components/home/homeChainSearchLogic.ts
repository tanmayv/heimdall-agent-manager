import { ownerSubmissionRoute } from '../../utils/ownerSubmissionNavigation';
import type { ChainListItem, ChainProjectGroup } from '../../api/endpoints/tasks';
import type { TaskChainSearchHit } from '../../utils/taskChainSearch';
import { isVaultArmored } from '../../utils/vaultContent';
import type { OwnerChainSummary } from '../../api/ownerChains';
import { isOwnerHeldChain, type ChainAuthority } from '../../api/chainAuthority';

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
  /** R4a: the Hub marks this Hub row owner-held (a frozen copy of a moved chain). */
  authority?: ChainAuthority;
}

/**
 * Bridge-owned chains first, then the Hub list without the frozen Hub copies
 * of chains that moved to a Bridge (the owner row inherits their project).
 * A Hub row marked owner-held is dropped even without a live registry row
 * (the owner tombstoned it), so a frozen copy never resurfaces.
 */
export function homeChainsWithOwners(loaded: HomeChainItem[], owners: OwnerChainSummary[]): HomeChainItem[] {
  if (!owners.length) return loaded.filter((c) => !isOwnerHeldChain(c));
  const copies = new Map(loaded.map((c) => [c.chainId, c]));
  const ids = new Set(owners.map((o) => o.chainId));
  return [
    ...owners.map((o): HomeChainItem => {
      const copy = copies.get(o.chainId);
      return {
        chainId: o.chainId, title: o.title || '', status: '', updatedAt: copy?.updatedAt || '',
        projectId: o.projectId || copy?.projectId || '', projectName: o.projectName || copy?.projectName || '',
        owner: { bridgeId: o.ownerBridgeId, bridgeName: o.bridgeName, online: o.online },
      };
    }),
    ...loaded.filter((c) => !ids.has(c.chainId) && !isOwnerHeldChain(c)),
  ];
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

function time(value: string): number {
  const t = new Date(value || '').getTime();
  return Number.isFinite(t) ? t : Number.NEGATIVE_INFINITY;
}

/** Full flat API snapshot, copied and ordered deterministically; invalid dates last.
 * Duplicate IDs retain their newest eligible row (first response row on exact ties).
 */
export function homeChainsFromFlatList(
  chains: ChainListItem[] | undefined,
  archivedProjectIds: ReadonlySet<string> = new Set(),
): HomeChainItem[] {
  const sorted = (chains || [])
    .filter((c) => c.chainId && !archivedProjectIds.has(c.projectId)
      && String(c.status || '').toLowerCase() !== 'archived' && !(c as ChainListItem & { archived?: boolean }).archived)
    .map((c) => ({
      chainId: c.chainId,
      title: c.title || '',
      status: String(c.status || '').toLowerCase(),
      projectId: c.projectId || '',
      projectName: c.projectName || '',
      updatedAt: c.updatedAt || '',
      coordinatorAgentInstanceId: c.coordinatorAgentInstanceId || undefined,
      ...(c.authority ? { authority: c.authority } : {}),
    }))
    .sort((a, b) => {
      const at = time(a.updatedAt), bt = time(b.updatedAt);
      return at !== bt ? (at > bt ? -1 : 1) : (a.chainId < b.chainId ? -1 : a.chainId > b.chainId ? 1 : 0);
    });
  const seen = new Set<string>();
  return sorted.filter((c) => {
    if (seen.has(c.chainId)) return false;
    seen.add(c.chainId);
    return true;
  });
}

/** Zero rows have zero pages; clamp defensively after a snapshot shrinks. */
export function homeChainPage(chains: HomeChainItem[], index: number) {
  const pageCount = Math.ceil(chains.length / HOME_RECENT_CHAIN_LIMIT);
  const pageIndex = Math.max(0, Math.min(Number.isFinite(index) ? Math.trunc(index) : 0, Math.max(0, pageCount - 1)));
  return {
    rows: chains.slice(pageIndex * HOME_RECENT_CHAIN_LIMIT, (pageIndex + 1) * HOME_RECENT_CHAIN_LIMIT),
    pageIndex,
    pageCount,
    hasPrevious: pageIndex > 0,
    hasNext: pageIndex + 1 < pageCount,
  };
}

/**
 * All non-archived chains across every project, flattened (no grouping) and
 * sorted most-recently-updated first.
 */
export function flattenRecentChains(
  groups: ChainProjectGroup[] | undefined,
  archivedProjectIds: ReadonlySet<string> = new Set(),
): HomeChainItem[] {
  const out: HomeChainItem[] = [];
  for (const g of groups || []) {
    if (g.projectId && archivedProjectIds.has(g.projectId)) continue;
    for (const c of g.chains || []) {
      const projectId = c.projectId || g.projectId || '';
      if (projectId && archivedProjectIds.has(projectId)) continue;
      const status = String(c.status || '').toLowerCase();
      if (status === 'archived' || (c as any).archived) continue;
      out.push({
        chainId: c.chainId,
        title: c.title || '',
        status,
        projectId,
        projectName: c.projectName || g.projectName || '',
        updatedAt: c.updatedAt || '',
        coordinatorAgentInstanceId: c.coordinatorAgentInstanceId || undefined,
      });
    }
  }
  return out.sort((a, b) => time(b.updatedAt) - time(a.updatedAt));
}

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
