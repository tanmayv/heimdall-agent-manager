/**
 * CommandPalette — the unified Cmd/Ctrl-K palette (EL-056).
 * ------------------------------------------------------------------
 * Purpose: one keyboard-first surface for navigation + entity search + quick
 * actions, invoked from Cmd/Ctrl-K, the sidebar "Search" item, and the mobile
 * center tab. Search-as-you-type (debounced, superseded requests aborted by RTK
 * Query), grouped results, and real load-more paging.
 *
 * Layer: pattern (product-specific). Built on the shared dialog a11y contract
 * (`useDialogA11y`, the same focus-trap/Esc/scroll-lock/restore Modal uses) and
 * the ARIA combobox pattern (an input `role="combobox"` driving a `role="listbox"`
 * of `role="option"` rows via `aria-activedescendant`). It does NOT nest the
 * `Combobox` primitive: the palette's results are heterogeneous and grouped
 * (nav / actions / live conversations / backend entities with previews +
 * load-more), which Combobox's flat option model can't render — so it reuses the
 * pattern, not the component.
 *
 * Accessibility (built in, not props):
 *   - Panel is `role="dialog"` + `aria-modal` + `aria-label`; `useDialogA11y`
 *     traps focus, closes on Esc, locks body scroll, and restores focus on close.
 *   - The input is `role="combobox"` (`aria-expanded`, `aria-controls`,
 *     `aria-activedescendant`, `aria-autocomplete="list"`); results are a
 *     `role="listbox"`; each row is a `role="option"` with a stable id and
 *     `aria-selected`. Focus stays on the input; ↑/↓ move the active option,
 *     Enter activates it — the options are not tab stops.
 *
 * Tokens only: surface/border/text/radius/shadow/z resolve to tokens
 * (`surface-overlay`, `border-subtle`, `text-primary/muted/faint`, `z-modal`,
 * `shadow-overlay`). Row hover/active use the app's translucent white-overlay
 * idiom (not a hex literal). No raw hex / arbitrary z.
 */
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useGlobalSearchQuery, useLazyGlobalSearchQuery, type SearchHit } from '../../../api/endpoints/search';
import { hitRoute, renderPreview } from '../../../utils/searchHit';
import { Icon, Spinner, StatusDot, type IconName } from '../primitives';
import { runtimeStatusToTone } from './RuntimeChip';
import { useDialogA11y } from '../composites/useDialogA11y';

export type PaletteConversation = {
  conversationId: string;
  agentInstanceId?: string;
  title: string;
  agentName?: string;
  // True when this conversation's agent is a coordinator of its chain: renders
  // the entry's own name gold (matches the sidebar rail).
  isCoordinator?: boolean;
  runtimeStatus?: string;
  activityStatus?: string;
  unreadCount?: number;
};

export type PaletteConversationGroup = {
  projectId: string;
  projectName: string;
  conversations: PaletteConversation[];
};

// Optional search scope. When provided (e.g. the palette is opened from a
// conversation's top bar), the palette becomes a scoped search: Navigate/Actions
// groups are hidden, entity search is constrained to the chain/conversation, and
// a scope selector lets the user widen to "Everywhere". chainId takes precedence
// over conversationId (chain scope already covers the conversation's messages).
export type PaletteScope = {
  chainId?: string;
  conversationId?: string;
  // Short human label for the scope chip, e.g. the conversation/chain title.
  label?: string;
};

export type CommandPaletteProps = {
  open: boolean;
  onClose: () => void;
  onNavigate: (route: string) => void;
  onAction?: (actionId: string) => void;
  // Documented actions surfaced as quick verbs.
  actions?: PaletteAction[];
  // Live conversations grouped by project — mirrors the sidebar rail so the
  // palette doubles as the conversation switcher (replaces the drawer on mobile).
  conversationGroups?: PaletteConversationGroup[];
  // Current active route path for persistent selected highlight.
  currentPath?: string;
  // Present → open in scoped-search mode (see PaletteScope).
  scope?: PaletteScope;
};

export type PaletteAction = {
  id: string;
  label: string;
  hint?: string;
  icon?: IconName;
};

export type PaletteResult =
  | { kind: 'navigate'; label: string; hint?: string; icon?: IconName; route: string; group: 'Navigate' }
  | { kind: 'action'; label: string; hint?: string; icon?: IconName; actionId: string; group: 'Actions' }
  | { kind: 'conversation'; label: string; hint?: string; route: string; group: string; convo: PaletteConversation }
  | { kind: 'entity'; label: string; hint?: string; hit: SearchHit; group: string; route?: string };

// Live runtime state → StatusDot props for a conversation row's dot. Uses the
// canonical runtime tone map (EL-050) so the palette matches the sidebar/chips.
function convoDot(convo: PaletteConversation): { tone: Parameters<typeof StatusDot>[0]['tone']; pulse: boolean } {
  const tone = runtimeStatusToTone(convo.runtimeStatus || '');
  const busy = ['active', 'busy', 'working'].includes(String(convo.activityStatus || '').toLowerCase());
  return { tone, pulse: tone === 'success' && busy };
}

const DEFAULT_NAV: { label: string; icon: IconName; route: string }[] = [
  { label: 'New conversation', icon: 'plus', route: '/conversations/new' },
  { label: 'Conversations', icon: 'chat', route: '/conversations' },
  { label: 'Actions', icon: 'clock', route: '/actions' },
  { label: 'Projects', icon: 'grid', route: '/projects' },
  { label: 'Agents', icon: 'bot', route: '/agents' },
  { label: 'Memory', icon: 'spark', route: '/memory' },
  { label: 'Task Chains', icon: 'tasks', route: '/chains' },
  { label: 'Library', icon: 'device', route: '/library' },
  { label: 'Settings', icon: 'gear', route: '/settings' },
];

const DEFAULT_ACTIONS: PaletteAction[] = [
  { id: 'new-chain', label: 'New task chain', icon: 'tasks', hint: 'Start a chain' },
  { id: 'new-agent', label: 'New agent', icon: 'plus', hint: 'Create a durable identity' },
  { id: 'new-project', label: 'New project', icon: 'grid', hint: 'Grouping + paths' },
];

// Search-call tuning (user-approved): a slightly longer debounce and a 2-char
// minimum before hitting the BACKEND cut /api/v1/search calls >50% for typical
// typing, with no perceived slowdown. LOCAL palette content (nav/actions) still
// filters from the 1st character — only the network entity search is gated.
const SEARCH_DEBOUNCE_MS = 250;
const MIN_BACKEND_QUERY_LEN = 2;

function matches(haystack: string, q: string): boolean {
  return haystack.toLowerCase().includes(q.toLowerCase());
}


function hitIcon(type: string): IconName {
  switch (String(type || '').toLowerCase()) {
    case 'conversation': return 'chat';
    case 'agent':
    case 'agent_instance': return 'bot';
    case 'task-chain':
    case 'chain': return 'tasks';
    case 'task': return 'tasks';
    case 'comment': return 'chat';
    case 'message': return 'chat';
    case 'skill': return 'spark';
    case 'project': return 'grid';
    case 'artifact': return 'device';
    case 'memory': return 'search';
    default: return 'chevron-right';
  }
}

const ENTITY_GROUP_LABEL: Record<string, string> = {
  conversation: 'Conversations',
  agent: 'Agents',
  agent_instance: 'Agents',
  'task-chain': 'Task Chains',
  task: 'Tasks',
  comment: 'Comments',
  message: 'Messages',
  project: 'Projects',
  artifact: 'Artifacts',
  memory: 'Memory',
  skill: 'Skills',
};

/** Stable id for the option at flat index `i` (target of aria-activedescendant). */
const optionId = (i: number) => `command-palette-option-${i}`;

export function CommandPalette({ open, onClose, onNavigate, onAction, actions = DEFAULT_ACTIONS, conversationGroups = [], currentPath = '', scope }: CommandPaletteProps) {
  const [query, setQuery] = useState('');
  const [debounced, setDebounced] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const listboxId = 'command-palette-listbox';

  // Scoped-search mode. `hasScope` = the palette was opened with a scope context;
  // `scoped` (user-toggleable via the scope selector) = that scope is currently
  // applied. When scoped, entity search is constrained and the scope's parent id
  // is forwarded to the backend; when the user switches to "Everywhere" the same
  // palette behaves like a plain global search (Navigate/Actions stay hidden —
  // this instance is a search entry point, not the full command palette).
  const hasScope = Boolean(scope && (scope.chainId || scope.conversationId));
  const [scoped, setScoped] = useState(true);
  const scopeActive = hasScope && scoped;
  const scopeFilter = scopeActive
    ? (scope!.chainId ? { chainIds: scope!.chainId } : { conversationIds: scope!.conversationId })
    : {};

  // Shared dialog contract: focus trap, Esc-to-close, body scroll-lock, and
  // focus restore on close — the same infrastructure Modal/Drawer use.
  useDialogA11y(open, onClose, panelRef);

  // Debounce the search query to limit requests: only the settled value drives the
  // backend hook, so mid-typing keystrokes never each fire a call.
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(query), SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [query]);

  // Entity search via the backend global endpoint. RTK Query keeps only the
  // latest arg and aborts superseded requests, so results never jitter.
  const trimmed = debounced.trim();
  // Require >=2 chars before calling /search — 1-char queries are the broadest and
  // least useful, and local nav/actions already answer single keystrokes.
  const searchQuery = useGlobalSearchQuery(
    { q: trimmed, limit: 12, ...scopeFilter },
    { skip: !open || trimmed.length < MIN_BACKEND_QUERY_LEN },
  );

  // Real load-more (SEARCH-5): the first page comes from useGlobalSearchQuery;
  // subsequent pages are fetched on demand with the previous page's cursor and
  // appended. Reset whenever the (debounced) query or its first page changes.
  const [extraHits, setExtraHits] = useState<SearchHit[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [fetchMore] = useLazyGlobalSearchQuery();

  useEffect(() => {
    setExtraHits([]);
    setCursor(searchQuery.data?.nextCursor ?? null);
    setHasMore(Boolean(searchQuery.data?.hasMore));
  }, [trimmed, searchQuery.data]);

  const loadMore = useCallback(async () => {
    if (!cursor || loadingMore) return;
    setLoadingMore(true);
    try {
      const res = await fetchMore({ q: trimmed, limit: 12, cursor, ...scopeFilter }).unwrap();
      setExtraHits((prev) => [...prev, ...res.hits]);
      setCursor(res.nextCursor ?? null);
      setHasMore(Boolean(res.hasMore));
    } catch {
      setHasMore(false);
    } finally {
      setLoadingMore(false);
    }
  }, [cursor, loadingMore, trimmed, fetchMore, scopeActive, scope?.chainId, scope?.conversationId]);

  // First page + all loaded pages, de-duped by type+id so paging never dupes.
  const entityHits = useMemo<SearchHit[]>(() => {
    const seen = new Set<string>();
    const out: SearchHit[] = [];
    for (const hit of [...(searchQuery.data?.hits ?? []), ...extraHits]) {
      const key = `${hit.type}:${hit.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(hit);
    }
    return out;
  }, [searchQuery.data, extraHits]);

  // Reset on open, and move focus to the input (combobox owns focus).
  useEffect(() => {
    if (open) {
      setQuery('');
      setDebounced('');
      setActiveIndex(0);
      setScoped(true);
      window.setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open]);

  // Build the grouped, flat result list.
  const results = useMemo<PaletteResult[]>(() => {
    const q = query.trim().toLowerCase();
    const out: PaletteResult[] = [];

    // Navigate + Actions FIRST (local, instant primary quick-jumps) so they are
    // always reachable at the top of the list — crucial on mobile where a long
    // Conversations list + the on-screen keyboard would otherwise push Actions
    // out of reach at the bottom. Hidden entirely in scoped-search mode: this
    // instance is a search entry point, not the global command palette.
    if (!hasScope) {
      const navItems = q ? DEFAULT_NAV.filter((item) => matches(item.label, q)) : DEFAULT_NAV;
      if (navItems.length) {
        navItems.forEach((item) => out.push({ kind: 'navigate', label: item.label, icon: item.icon, route: item.route, group: 'Navigate' }));
      }

      const actionItems = q ? actions.filter((a) => matches(a.label, q)) : actions;
      if (actionItems.length) {
        actionItems.forEach((a) => out.push({ kind: 'action', label: a.label, hint: a.hint, icon: a.icon, actionId: a.id, group: 'Actions' }));
      }
    }

    // Live conversations grouped by project — mirrors the sidebar rail. Each
    // project becomes its own palette group; filtered by query when typing.
    // In scoped mode the caller passes only the in-scope (chain) conversations,
    // so show them when the scope is applied; hide them under "Everywhere"
    // (that widening relies on the global entity search below instead).
    if (!hasScope || scopeActive) {
      for (const group of conversationGroups) {
        const items = q
          ? group.conversations.filter((c) => matches(`${c.title} ${c.agentName || ''} ${group.projectName}`, q))
          : group.conversations;
        items.forEach((c) => out.push({
          kind: 'conversation',
          label: c.title || c.agentName || c.conversationId,
          hint: c.agentName && c.agentName !== c.title ? c.agentName : undefined,
          route: `/conversations/${encodeURIComponent(c.agentInstanceId)}`,
          group: group.projectName || 'Conversations',
          convo: c,
        }));
      }
    }

    // Entities from backend search (first page + loaded pages), grouped by type.
    // These hits belong to the DEBOUNCED, last-RESOLVED query (`trimmed`) — only show
    // them when that still matches the CURRENT input AND the fetch has settled.
    // Otherwise a new keystroke would keep rendering the PREVIOUS query's results
    // through the debounce+fetch window; gating here clears stale hits immediately.
    const entitiesFresh = trimmed.length >= MIN_BACKEND_QUERY_LEN && trimmed === query.trim() && !searchQuery.isFetching;
    if (entitiesFresh) {
      for (const hit of entityHits) {
        const t = hit.type || '';
        // Under chain scope the local "Agents in this chain" group already lists
        // the chain's conversations, so drop conversation-type entity hits to
        // avoid showing the same thread twice.
        if (scopeActive && t.toLowerCase() === 'conversation') continue;
        out.push({ kind: 'entity', label: hit.label || hit.id, hint: hit.sublabel, hit, route: hitRoute(hit), group: ENTITY_GROUP_LABEL[t] || t || 'Entities' });
      }
    }
    return out;
  }, [query, trimmed, searchQuery.isFetching, entityHits, actions, conversationGroups, hasScope, scopeActive]);

  // Reset active index when results change.
  useEffect(() => {
    setActiveIndex(0);
  }, [results]);

  // Keep the active item scrolled into view.
  useEffect(() => {
    const node = listRef.current?.querySelector<HTMLElement>(`[data-palette-index="${activeIndex}"]`);
    node?.scrollIntoView({ block: 'nearest' });
  }, [activeIndex]);

  function activate(result: PaletteResult) {
    if (result.kind === 'navigate' || result.kind === 'entity' || result.kind === 'conversation') {
      if (result.route) {
        onNavigate(result.route);
        onClose();
      }
    } else if (result.kind === 'action') {
      onAction?.(result.actionId);
      onClose();
    }
  }

  // Combobox keyboard model: ↑/↓ move the active option, Enter activates it.
  // Esc/Tab are owned by useDialogA11y (document-level), so they're not here.
  function handleKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setActiveIndex((i) => (i + 1) % Math.max(results.length, 1));
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActiveIndex((i) => (i - 1 + Math.max(results.length, 1)) % Math.max(results.length, 1));
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const result = results[activeIndex];
      if (result) activate(result);
    }
  }

  if (!open) return null;

  // Group results for rendering while keeping the flat index for keyboard nav.
  const grouped = new Map<string, { results: PaletteResult[]; indices: number[] }>();
  let flatIndex = 0;
  for (const result of results) {
    const key = result.group;
    if (!grouped.has(key)) grouped.set(key, { results: [], indices: [] });
    grouped.get(key)!.results.push(result);
    grouped.get(key)!.indices.push(flatIndex);
    flatIndex += 1;
  }

  // "Searching" spans the whole in-flight window — the debounce wait (input typed but
  // not yet mirrored into the debounced `trimmed`) AND the network fetch — so the
  // affordance appears immediately on a keystroke and the empty-state never flashes
  // mid-type. `searchFailed` is a settled request that errored (distinct from empty).
  // Only treat the query as "searching" once it's long enough to hit the backend —
  // a 1-char query never calls /search, so it must not show the Searching spinner.
  const qTrim = query.trim();
  const searching = qTrim.length >= MIN_BACKEND_QUERY_LEN && (qTrim !== trimmed || searchQuery.isFetching);
  const searchFailed = qTrim.length >= MIN_BACKEND_QUERY_LEN && !searching && searchQuery.isError;

  return (
    <div
      data-debug-id="command-palette"
      role="presentation"
      className="fixed inset-0 z-modal flex items-start justify-center bg-black/60 px-2 pt-[max(env(safe-area-inset-top),0.5rem)] backdrop-blur-sm sm:px-4 sm:pt-[12vh]"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        data-debug-id="command-palette-panel"
        className="flex max-h-[calc(100dvh-1rem)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface-overlay shadow-overlay outline-none sm:max-h-[70vh]"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-subtle px-4 py-3">
          <span aria-hidden="true" className="text-muted"><Icon name="search" size={16} /></span>
          <input
            ref={inputRef}
            data-debug-id="command-palette-input"
            role="combobox"
            aria-expanded="true"
            aria-controls={listboxId}
            aria-activedescendant={results.length ? optionId(activeIndex) : undefined}
            aria-autocomplete="list"
            aria-label="Search commands, conversations, and entities"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a command or search…"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-primary outline-none placeholder:text-faint"
            autoComplete="off"
            spellCheck={false}
          />
          {searching ? <span data-debug-id="command-palette-loading" className="text-caption text-muted">searching…</span> : null}
          <kbd className="rounded border border-subtle bg-white/5 px-1.5 py-0.5 text-[10px] text-muted">esc</kbd>
        </div>
        {hasScope ? (
          <div data-debug-id="command-palette-scope" className="flex min-w-0 items-center gap-2 border-b border-subtle px-4 py-1.5 text-[11px] text-muted">
            <span className="shrink-0 text-faint">Scope</span>
            <div role="group" aria-label="Search scope" className="inline-flex min-w-0 items-center overflow-hidden rounded-md border border-subtle">
              <button
                type="button"
                data-debug-id="command-palette-scope-chain"
                aria-pressed={scoped}
                onClick={() => setScoped(true)}
                title={scope?.label || 'This chain'}
                className={`max-w-[200px] truncate px-2 py-0.5 ${scoped ? 'bg-accent text-accent-fg' : 'text-muted hover:bg-white/[0.06]'}`}
              >
                {scope?.label || 'This chain'}
              </button>
              <button
                type="button"
                data-debug-id="command-palette-scope-all"
                aria-pressed={!scoped}
                onClick={() => setScoped(false)}
                className={`shrink-0 px-2 py-0.5 ${!scoped ? 'bg-accent text-accent-fg' : 'text-muted hover:bg-white/[0.06]'}`}
              >
                All
              </button>
            </div>
          </div>
        ) : null}
        <div
          ref={listRef}
          id={listboxId}
          role="listbox"
          aria-label="Results"
          aria-busy={searching}
          className="flex-1 overflow-y-auto p-2"
        >
          {!searching && results.length === 0 ? (
            <div data-debug-id="command-palette-empty" role="presentation" className="px-3 py-8 text-center text-sm text-muted">
              {qTrim.length === 0
                ? (scopeActive ? 'Type to search this conversation & its task chain.' : 'Start typing to search or jump.')
                : qTrim.length < MIN_BACKEND_QUERY_LEN
                  ? 'Keep typing to search…'
                  : `No results for “${qTrim}”${scopeActive ? ' in this chain' : ''}.`}
            </div>
          ) : (
            Array.from(grouped.entries()).map(([groupLabel, { results: groupResults, indices }]) => (
              <div key={groupLabel} role="group" aria-label={groupLabel} className="mb-1">
                <div aria-hidden="true" data-debug-id={`command-palette-group-${groupLabel.toLowerCase().replace(/\s+/g, '-')}`} className="px-3 py-1 text-[10.5px] font-semibold uppercase tracking-[0.18em] text-faint">{groupLabel}</div>
                {groupResults.map((result, i) => {
                  const idx = indices[i];
                  const active = idx === activeIndex;
                  const label = result.label;
                  // Message hits show the matched-text SNIPPET as the primary line and
                  // the conversation TITLE (sublabel) as the secondary line — the
                  // inverse of other entities, which show their name then a preview.
                  const isMessage = result.kind === 'entity' && String(result.hit.type || '').toLowerCase() === 'message';
                  const icon: IconName = result.kind === 'entity' ? hitIcon(result.hit.type || '') : ((result as any).icon || 'chevron-right');
                  const isConvo = result.kind === 'conversation';
                  const unread = isConvo ? Number(result.convo.unreadCount || 0) : 0;
                  const isSelectedConvo = isConvo && Boolean(
                    currentPath &&
                    (currentPath === `/conversations/${result.convo.agentInstanceId}` ||
                     currentPath.startsWith(`/conversations/${result.convo.agentInstanceId}/`))
                  );
                  const highlight = active || isSelectedConvo;
                  return (
                    <div
                      key={`${groupLabel}-${idx}`}
                      role="option"
                      id={optionId(idx)}
                      aria-selected={active}
                      data-debug-id={`command-palette-result-${idx}`}
                      data-palette-index={idx}
                      onClick={() => activate(result)}
                      onMouseEnter={() => setActiveIndex(idx)}
                      className={`flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm ${highlight ? 'bg-white/[0.08] text-primary' : 'text-muted hover:bg-white/[0.04]'}`}
                    >
                      {isConvo ? (
                        <span aria-hidden="true" className="grid w-5 place-items-center">
                          <StatusDot tone={convoDot(result.convo).tone} pulse={convoDot(result.convo).pulse} label="" />
                        </span>
                      ) : (
                        <span aria-hidden="true" className="grid w-5 place-items-center text-muted opacity-80"><Icon name={icon} size={16} /></span>
                      )}
                      <span className="flex min-w-0 flex-1 flex-col">
                        <span className={`truncate ${isConvo && result.convo.isCoordinator ? 'text-warning' : ''}`} title={isConvo && result.convo.isCoordinator ? 'Coordinator' : undefined}>
                          {isMessage && result.hit.preview ? renderPreview(result.hit.preview) : label}
                        </span>
                        {isMessage ? (
                          result.hit.sublabel ? <span className="truncate text-caption text-muted">{result.hit.sublabel}</span> : null
                        ) : result.kind === 'entity' && result.hit.preview ? (
                          <span className="truncate text-caption text-muted">{renderPreview(result.hit.preview)}</span>
                        ) : null}
                      </span>
                      {unread > 0 ? <span className="ml-auto shrink-0 rounded-full bg-accent px-1.5 text-center text-[10px] font-bold leading-4 text-accent-fg">{unread > 99 ? '99+' : unread}</span> : null}
                      {result.hint && !isMessage ? <span className="ml-auto shrink-0 truncate self-center pl-2 text-caption text-muted">{result.hint}</span> : null}
                    </div>
                  );
                })}
              </div>
            ))
          )}
          {searching ? (
            // Progress affordance for in-flight entity search. The Spinner is a
            // role="status" live region, so screen readers announce it (the visible
            // label is aria-hidden to avoid a double announcement); the listbox's
            // aria-busy above marks the results region as updating.
            <div data-debug-id="command-palette-searching" className="flex items-center gap-2 px-3 py-2 text-caption text-muted">
              <Spinner size="sm" label="Searching" />
              <span aria-hidden="true">Searching…</span>
            </div>
          ) : null}
          {searchFailed ? (
            <div data-debug-id="command-palette-error" role="status" className="px-3 py-2 text-caption text-danger">
              Search failed — check your connection and try again.
            </div>
          ) : null}
          {!searching && qTrim.length >= MIN_BACKEND_QUERY_LEN && hasMore ? (
            <button
              type="button"
              data-debug-id="command-palette-load-more"
              onClick={loadMore}
              disabled={loadingMore}
              className="mt-1 w-full rounded-lg px-3 py-2 text-center text-[12px] text-muted hover:bg-white/[0.04] focus-visible:shadow-focus focus-visible:outline-none disabled:opacity-50"
            >
              {loadingMore ? 'Loading…' : 'Load more results'}
            </button>
          ) : null}
        </div>
        {/* Keyboard-hint footer is desktop-only: on mobile it wastes vertical
            space the on-screen keyboard already claims, and the hints are
            keyboard-only anyway. */}
        <div className="hidden items-center justify-between border-t border-subtle px-4 py-2 text-caption text-faint sm:flex">
          <span className="flex items-center gap-2">
            <kbd className="rounded border border-subtle bg-white/5 px-1.5 py-0.5">↑↓</kbd> navigate
            <kbd className="ml-2 rounded border border-subtle bg-white/5 px-1.5 py-0.5">↵</kbd> select
          </span>
          <span data-debug-id="command-palette-search-source">{trimmed ? 'Entity results: /api/v1/search' : 'Heimdall'}</span>
        </div>
      </div>
    </div>
  );
}

export default CommandPalette;
