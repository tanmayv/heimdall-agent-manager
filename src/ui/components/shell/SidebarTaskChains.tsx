import { useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { Icon, StatusDot } from '@ui';
import { selectSearchChains } from '../../store/searchTitleSlice';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { navigateToHash } from '../../utils/conversationUrl';
import { searchTaskChainsEncrypted, taskChainSearchErrorMessage } from '../../utils/taskChainSearch';
import { useAuthUser } from '../auth/AuthUserContext';
import { chainStatusDot } from '../ui/patterns/commandPaletteLogic';
import { VaultText } from '../vault/VaultText';
import { refreshOwnerChains, useOwnerChains } from '../../api/ownerChainsStore';
import {
  filterHomeChains, homeChainsFromOwners, homeChainsFromSearchHits,
  HOME_RECENT_CHAIN_LIMIT, HOME_REMOTE_SEARCH_MIN_CHARS, type HomeChainItem,
} from '../home/homeChainSearchLogic';

/** A chain row opens its submission (search match) or the chain view. */
function chainRoute(chain: HomeChainItem): string {
  return chain.submissionRoute || `/chains/${encodeURIComponent(chain.chainId)}`;
}

export interface SidebarTaskChainsProps {
  scrollRoot?: HTMLElement | null;
  active?: boolean;
  currentPath: string;
  onNavigate?: () => void;
}

/** The Bridge-owned chains of the shared owner-registry snapshot, with Bridge
 * search. No timer, focus/reconnect fetch or per-row fetch: the registry loads
 * once per vault session (ownerChainsStore).
 */
export function SidebarTaskChains({ currentPath, onNavigate }: SidebarTaskChainsProps) {
  const owners = useOwnerChains();
  const loaded = useMemo(() => homeChainsFromOwners(owners.chains), [owners.chains]);
  const titles = useSelector(selectSearchChains) as Record<string, { decryptedTitle?: string }>;
  const unlocked = useSelector(selectIsVaultUnlocked);
  const user = useAuthUser();
  const [query, setQuery] = useState('');
  const trimmed = query.trim();
  const searchKey = JSON.stringify([user?.user_id, unlocked, trimmed]);
  const [remote, setRemote] = useState<{
    key: string; rows: HomeChainItem[] | null; state: 'searching' | 'stale' | 'error' | 'idle'; error?: string;
  } | null>(null);
  useEffect(() => {
    if (!unlocked || trimmed.length < HOME_REMOTE_SEARCH_MIN_CHARS || !user?.user_id) {
      setRemote(null);
      return;
    }
    let cancelled = false;
    setRemote(null);
    const timer = setTimeout(() => {
      setRemote({ key: searchKey, rows: null, state: 'searching' });
      searchTaskChainsEncrypted(trimmed, user.user_id!, { limit: HOME_RECENT_CHAIN_LIMIT })
        .then(response => {
          if (!cancelled) setRemote({
            key: searchKey, rows: homeChainsFromSearchHits(response.hits, loaded),
            state: response.stale ? 'stale' : 'idle',
          });
        })
        .catch(error => {
          if (!cancelled) setRemote({ key: searchKey, rows: null, state: 'error', error: taskChainSearchErrorMessage(error) });
        });
    }, 150);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [searchKey, trimmed, unlocked, user?.user_id, loaded]);
  const activeRemote = unlocked && remote?.key === searchKey ? remote : null;
  const rows = trimmed ? activeRemote?.rows ?? filterHomeChains(loaded, trimmed, titles, Infinity) : loaded;
  const open = (event: React.MouseEvent<HTMLAnchorElement>, chain: HomeChainItem) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    navigateToHash(buildRouteHash(chainRoute(chain), ''));
    onNavigate?.();
  };
  return (
    <section aria-label="Task chains" data-debug-id="sidebar-task-chains" className="mt-4 min-w-0 border-t border-subtle pt-3">
      <h2 className="mb-2 px-2.5 text-xs font-semibold text-muted">Task chains</h2>
      <div className="relative mb-2">
        <Icon name="search" size={14} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
        <input type="search" aria-label="Search task chains" placeholder="Search task chains…"
          data-debug-id="sidebar-chain-search" value={query} onChange={event => setQuery(event.target.value)}
          className="min-h-11 w-full min-w-0 rounded-xl border border-subtle bg-surface pl-9 pr-3 text-base text-primary placeholder:text-muted focus:border-accent focus:outline-none sm:text-sm" />
      </div>
      {activeRemote && activeRemote.state !== 'idle' ? (
        <p role="status" className="px-2.5 py-2 text-xs text-muted">
          {activeRemote.state === 'searching' ? 'Searching unlocked Bridges…' : activeRemote.state === 'stale' ? 'Results may be stale.' : activeRemote.error}
        </p>
      ) : null}
      <ul aria-label="Task chains" aria-busy={owners.status === 'loading'} className="space-y-0.5">
        {owners.status === 'locked' ? (
          <li data-debug-id="sidebar-chain-locked" className="px-2.5 py-3 text-sm text-muted">Unlock the vault to see your task chains.</li>
        ) : owners.status === 'loading' && !loaded.length ? (
          <li role="status" className="px-2.5 py-3 text-sm text-muted">Loading task chains…</li>
        ) : owners.status === 'error' && !loaded.length ? null : rows.length === 0 ? (
          <li data-debug-id="sidebar-chain-empty" className="px-2.5 py-3 text-sm text-muted">
            {trimmed ? 'No matching task chains.' : 'No task chains yet.'}
          </li>
        ) : rows.map(chain => (
          <li key={chain.rowKey || chain.chainId}>
            <a href={buildRouteHash(chainRoute(chain), '')}
              onClick={event => open(event, chain)}
              data-debug-id={chain.firstInGroup === false ? `sidebar-chain-match-row-${(chain.rowKey || chain.chainId).replace(/\u0000/g, '-')}` : `sidebar-chain-row-${chain.chainId}`}
              aria-current={currentPath === chainRoute(chain) ? 'page' : undefined}
              title="Open task chain"
              className={`flex min-h-11 min-w-0 items-center gap-2 rounded-xl px-2.5 py-2 hover:bg-neutral-soft ${currentPath === chainRoute(chain) ? 'bg-neutral-soft font-semibold' : ''}`}>
              {chain.owner
                ? <StatusDot size="sm" tone={chain.owner.online ? 'success' : 'neutral'} label={chain.owner.online ? 'Owner Bridge online' : 'Owner Bridge offline'} />
                : <StatusDot size="sm" {...chainStatusDot(chain.status)} label={chain.status || 'unknown'} />}
              <span className="min-w-0 flex-1">
                {chain.firstInGroup === false ? null : (
                  <span className="block truncate text-[13px] font-medium text-primary">
                    <VaultText value={titles[chain.chainId]?.decryptedTitle || chain.title} fallback={chain.chainId} />
                  </span>
                )}
                {chain.matchLabel ? <span data-debug-id={`sidebar-chain-match-${chain.chainId}`} className="block truncate text-xs text-muted">{chain.matchLabel}</span> : null}
                {chain.owner && chain.firstInGroup !== false ? (
                  <span data-debug-id={`sidebar-chain-owner-${chain.chainId}`} className="block truncate text-xs text-muted">
                    Bridge-owned · {chain.owner.bridgeName}{chain.owner.online ? '' : ' (offline)'}
                  </span>
                ) : chain.projectName ? <span className="block truncate text-xs text-muted"><VaultText value={chain.projectName} /></span> : null}
              </span>
            </a>
          </li>
        ))}
      </ul>
      {owners.status === 'error' ? (
        <div role="status" className="px-2.5 py-2 text-xs text-muted">
          <p>Could not load task chains.</p>
          <button type="button" data-debug-id="sidebar-chain-retry" onClick={() => void refreshOwnerChains()}
            className="min-h-11 rounded-xl px-3 text-sm text-accent hover:bg-neutral-soft">Retry</button>
        </div>
      ) : null}
    </section>
  );
}
