import type { MigrationBlocker, MigrationPreflight, MigrationRequest, MigrationResult } from './ownerMigrationClient.ts';

// "Import all legacy chains" (Settings → Bridges): moves every legacy Hub chain
// of the account that is not imported yet into one owner Bridge, one chain at a
// time. The core is pure: the Hub calls, the device signing and the title
// decryption are injected, so the whole flow is unit-tested without a Hub.

export type LegacyChainState = 'none' | 'draining' | 'frozen' | 'imported';
export interface LegacyChain {
  chain_id: string; title: string; status: string; work_revision: number; task_count: number;
  state: LegacyChainState; migration_id: string; owner_bridge_id: string;
}
export interface LegacyChainPage { items: LegacyChain[] | null; next_after: string }

export type ImportOutcome = 'imported' | 'pending' | 'skipped' | 'failed';
export interface ImportAllResult {
  chainId: string;
  title: string;
  outcome: ImportOutcome;
  /** Human text: why it was skipped, why it failed, or what is still pending. */
  message: string;
  /** Task ids the Hub force-held because they were in progress. */
  forcedHeld: string[];
  neutralized: MigrationBlocker[];
}
export interface ImportAllProgress {
  /** 1-based index of the chain being worked on; equals total once finished. */
  index: number;
  total: number;
  /** The chain being worked on, '' once finished. */
  currentTitle: string;
  results: ImportAllResult[];
  done: boolean;
}

export interface ImportAllDeps {
  /** GET (cookie auth); resolves the unwrapped `data`. */
  fetchJson: (path: string) => Promise<unknown>;
  /** POST (cookie auth) with a JSON body; resolves the unwrapped `data`. */
  post: (path: string, body: unknown) => Promise<unknown>;
  /** Device-signed migration request (prepareMigrationRequest bound to the session). */
  prepare: (chainId: string, bridgeId: string, workRevision: number) => Promise<MigrationRequest>;
  /** Opens a possibly vault-sealed title; may throw. */
  decryptTitle: (title: string) => Promise<string>;
  onProgress?: (progress: ImportAllProgress) => void;
  /** False once the vault session changed: the batch stops before the next chain. */
  isCurrent?: () => boolean;
}

export const LEGACY_CHAIN_PAGE_LIMIT = 200;
const MAX_PAGES = 1000;

/** Every legacy chain of the account (imported ones included), paged by `after`. */
export async function listLegacyChains(fetchJson: ImportAllDeps['fetchJson'], limit = LEGACY_CHAIN_PAGE_LIMIT): Promise<LegacyChain[]> {
  const out: LegacyChain[] = [];
  let after = '';
  for (let page = 0; page < MAX_PAGES; page++) {
    const params = new URLSearchParams({ limit: String(limit) });
    if (after) params.set('after', after);
    const data = (await fetchJson('/api/v1/owner-local/migrations/legacy-chains?' + params.toString())) as LegacyChainPage | null;
    for (const item of Array.isArray(data?.items) ? data!.items! : []) {
      if (item && typeof item.chain_id === 'string' && item.chain_id) out.push(item);
    }
    const next = String(data?.next_after ?? '');
    if (!next || next === after) break;
    after = next;
  }
  return out;
}

function errorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error ?? '');
  return raw || 'Import failed';
}

/**
 * A refusal because the chain's work revision moved since it was listed. An
 * offline owner Bridge also answers 409 (bridge_offline): that is not a
 * conflict — the chain stays frozen for an exact retry, so it is not aborted.
 */
export function isMigrationConflict(error: unknown): boolean {
  const e = error as { code?: unknown; status?: unknown } | null;
  if (e?.code === 'bridge_offline') return false;
  return e?.code === 'migration_conflict' || e?.status === 409;
}

async function abortUnfinished(post: ImportAllDeps['post'], chainId: string, migrationId: string): Promise<void> {
  if (!migrationId) return;
  await post('/api/v1/owner-local/migrations/abort', { chain_id: chainId, migration_id: migrationId });
}

async function importOne(chain: LegacyChain, bridgeId: string, deps: ImportAllDeps): Promise<MigrationResult | 'already_imported'> {
  // An unfinished earlier move (its signed request is not ours) is abandoned first.
  if (chain.state === 'draining' || chain.state === 'frozen') await abortUnfinished(deps.post, chain.chain_id, chain.migration_id);
  const attempt = async (revision: number) => {
    const request = await deps.prepare(chain.chain_id, bridgeId, revision);
    return (await deps.post('/api/v1/owner-local/migrations', request)) as MigrationResult;
  };
  try {
    return await attempt(chain.work_revision);
  } catch (error) {
    if (!isMigrationConflict(error)) throw error;
    // The chain moved on since it was listed: re-read its revision and retry once.
    const preflight = (await deps.fetchJson('/api/v1/owner-local/migrations/preflight?chain_id=' + encodeURIComponent(chain.chain_id))) as MigrationPreflight;
    if (preflight?.state === 'imported') return 'already_imported';
    if (preflight?.state === 'draining' || preflight?.state === 'frozen') await abortUnfinished(deps.post, chain.chain_id, preflight.migration_id);
    return await attempt(Number(preflight?.work_revision ?? chain.work_revision));
  }
}

function resultFromMigration(chainId: string, title: string, result: MigrationResult | null | undefined): ImportAllResult {
  const forcedHeld = Array.isArray(result?.forced_held) ? result!.forced_held!.map(String) : [];
  const neutralized = Array.isArray(result?.neutralized) ? result!.neutralized! : [];
  const state = String(result?.state ?? '');
  if (state === 'imported') return { chainId, title, outcome: 'imported', message: '', forcedHeld, neutralized };
  return {
    chainId, title, outcome: 'pending', forcedHeld, neutralized,
    message: `Migration ${state || 'started'}; the Bridge finishes the import when it reconnects`,
  };
}

/**
 * Imports every not-yet-imported legacy chain into `bridgeId`, sequentially.
 * Imported chains are skipped (so re-running is idempotent); a failing chain is
 * recorded and the batch continues. Resolves the per-chain results.
 */
export async function importAllLegacyChains(bridgeId: string, deps: ImportAllDeps): Promise<ImportAllResult[]> {
  const isCurrent = deps.isCurrent ?? (() => true);
  const chains = await listLegacyChains(deps.fetchJson);
  const results: ImportAllResult[] = [];
  const total = chains.length;
  const report = (index: number, currentTitle: string, done: boolean) =>
    deps.onProgress?.({ index, total, currentTitle, results: results.slice(), done });
  for (let i = 0; i < chains.length; i++) {
    if (!isCurrent()) throw new Error('Vault session changed; the import stopped');
    const chain = chains[i];
    let title = '';
    try { title = await deps.decryptTitle(String(chain.title || '')); } catch { title = ''; }
    title = title || chain.chain_id;
    report(i + 1, title, false);
    if (chain.state === 'imported') {
      results.push({ chainId: chain.chain_id, title, outcome: 'skipped', message: 'Already imported', forcedHeld: [], neutralized: [] });
      continue;
    }
    try {
      const result = await importOne(chain, bridgeId, deps);
      results.push(result === 'already_imported'
        ? { chainId: chain.chain_id, title, outcome: 'skipped', message: 'Already imported', forcedHeld: [], neutralized: [] }
        : resultFromMigration(chain.chain_id, title, result));
    } catch (error) {
      results.push({ chainId: chain.chain_id, title, outcome: 'failed', message: errorMessage(error), forcedHeld: [], neutralized: [] });
    }
  }
  report(total, '', true);
  return results;
}
