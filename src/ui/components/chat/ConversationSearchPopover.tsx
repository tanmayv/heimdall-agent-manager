// Conversation top-bar search: a scoped search popover launched from the
// conversation header. Unlike the global Cmd-K CommandPalette, results here are
// constrained to the current conversation and its task chain.
//
// Scope choice: the backend AND-s positive typed scope filters, and message/
// conversation rows are indexed with BOTH their conversation id and their chain
// id (search_repo_sqlite scope columns). So a single `chain_ids=<chain>` filter
// already yields the union we want — this conversation's messages plus the
// chain's tasks and comments — in one query. When the conversation has no chain
// (a standalone chat) we fall back to `conversation_ids=<conversation>`.

import { useEffect, useMemo, useState } from 'react';
import { Icon, Input, Popover, Spinner } from '@ui';
import { useGlobalSearchQuery, type SearchHit } from '../../api/endpoints/search';
import { hitRoute, renderPreview } from '../../utils/searchHit';
import { buildRouteHash } from '../../utils/appLocation';

// Mirror the CommandPalette search tuning so the two surfaces behave alike.
const SEARCH_DEBOUNCE_MS = 250;
const MIN_QUERY_LEN = 2;

type ConversationSearchPopoverProps = {
  conversationId: string;
  chainId?: string;
};

export default function ConversationSearchPopover({ conversationId, chainId }: ConversationSearchPopoverProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [debounced, setDebounced] = useState('');

  // Debounce the network query; reset everything when the popover closes.
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(query), SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [query]);
  useEffect(() => {
    if (!open) { setQuery(''); setDebounced(''); }
  }, [open]);

  const trimmed = debounced.trim();
  const scope = useMemo(
    () => (chainId ? { chainIds: chainId } : { conversationIds: conversationId }),
    [chainId, conversationId],
  );
  const scopeLabel = chainId ? 'this conversation & its task chain' : 'this conversation';

  const searchQuery = useGlobalSearchQuery(
    { q: trimmed, limit: 15, ...scope },
    { skip: !open || trimmed.length < MIN_QUERY_LEN },
  );

  const groups = searchQuery.data?.groups || [];
  const hasHits = groups.some((group) => group.hits.length > 0);

  function goToHit(hit: SearchHit) {
    const route = hitRoute(hit);
    if (!route) return;
    window.location.hash = buildRouteHash(route, '');
    setOpen(false);
  }

  return (
    <Popover
      align="end"
      label="Search this conversation and its task chain"
      open={open}
      onOpenChange={setOpen}
      trigger={
        <button
          type="button"
          data-debug-id="conversation-search-btn"
          aria-label="Search this conversation and its task chain"
          title="Search this conversation & chain"
          className="grid h-9 w-9 shrink-0 place-items-center rounded-xl text-zinc-400 hover:bg-white/10 hover:text-zinc-200"
        >
          <Icon name="search" size={16} />
        </button>
      }
    >
      <div data-debug-id="conversation-search-panel" className="w-[min(92vw,22rem)] p-2">
        <Input
          data-debug-id="conversation-search-input"
          aria-label="Search query"
          value={query}
          onChange={setQuery}
          width="full"
          placeholder={`Search ${scopeLabel}…`}
          leading={<Icon name="search" size={14} />}
          autoFocus
        />
        <div className="mt-1 px-1 text-caption text-zinc-500">Scoped to {scopeLabel}</div>
        <div data-debug-id="conversation-search-results" className="mt-2 max-h-[50vh] space-y-3 overflow-y-auto">
          {trimmed.length < MIN_QUERY_LEN ? (
            <p className="px-1 py-3 text-xs text-zinc-500">Type at least {MIN_QUERY_LEN} characters to search.</p>
          ) : searchQuery.isFetching ? (
            <div className="flex items-center gap-2 px-1 py-3 text-xs text-zinc-500"><Spinner size="sm" /> Searching…</div>
          ) : searchQuery.isError ? (
            <p data-debug-id="conversation-search-error" className="px-1 py-3 text-xs text-red-300">Search failed. Try again.</p>
          ) : !hasHits ? (
            <p data-debug-id="conversation-search-empty" className="px-1 py-3 text-xs text-zinc-500">No matches in {scopeLabel}.</p>
          ) : (
            groups.map((group) => (group.hits.length ? (
              <div key={group.type} data-debug-id={`conversation-search-group-${group.type}`}>
                <div className="px-1 pb-1 text-caption uppercase tracking-wide text-zinc-600">{group.type}</div>
                <ul className="space-y-0.5">
                  {group.hits.map((hit) => (
                    <li key={`${group.type}:${hit.id}`}>
                      <button
                        type="button"
                        data-debug-id={`conversation-search-hit-${hit.id}`}
                        onClick={() => goToHit(hit)}
                        className="w-full rounded-lg px-2 py-1.5 text-left hover:bg-white/[0.06]"
                      >
                        <div className="truncate text-sm text-zinc-100">{hit.label || '(untitled)'}</div>
                        {hit.sublabel ? <div className="truncate text-caption text-zinc-500">{hit.sublabel}</div> : null}
                        {hit.preview ? <div className="truncate text-caption text-zinc-400">{renderPreview(hit.preview)}</div> : null}
                      </button>
                    </li>
                  ))}
                </ul>
              </div>
            ) : null))
          )}
        </div>
      </div>
    </Popover>
  );
}
