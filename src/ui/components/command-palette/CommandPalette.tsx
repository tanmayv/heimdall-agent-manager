import { useEffect, useMemo, useRef, useState } from 'react';
import { useGlobalSearchQuery, type SearchHit } from '../../api/endpoints/search';
import Icon, { type IconName } from '../Icon';

// UI-12: unified command palette — navigation + entity search + actions.
// One component, invoked from Cmd/Ctrl-K, the sidebar "Search" item, and the
// mobile bottom-tab center button. Search-as-you-type with debounce + abort
// of superseded requests (handled by RTK Query: only the latest arg is kept).
// Keyboard-first: up/down to move, Enter to activate, Esc to close.

export type PaletteConversation = {
  conversationId: string;
  title: string;
  agentName?: string;
  runtimeStatus?: string;
  activityStatus?: string;
  unreadCount?: number;
};

export type PaletteConversationGroup = {
  projectId: string;
  projectName: string;
  conversations: PaletteConversation[];
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

// Dot color for a conversation's live runtime state.
function convoDotClass(convo: PaletteConversation): string {
  const s = String(convo.runtimeStatus || '').toLowerCase();
  const busy = ['active', 'busy', 'working'].includes(String(convo.activityStatus || '').toLowerCase());
  if (s === 'running' || s === 'ready' || s === 'live') return busy ? 'bg-emerald-400 animate-pulse' : 'bg-emerald-400';
  if (s === 'starting' || s === 'launching') return 'bg-amber-400';
  return 'bg-zinc-600';
}

const DEFAULT_NAV: { label: string; icon: IconName; route: string }[] = [
  { label: 'New conversation', icon: 'plus', route: '/conversations/new' },
  { label: 'Conversations', icon: 'chat', route: '/conversations' },
  { label: 'Projects', icon: 'grid', route: '/projects' },
  { label: 'Agents', icon: 'tasks', route: '/agents' },
  { label: 'Library', icon: 'device', route: '/library' },
  { label: 'Settings', icon: 'gear', route: '/settings' },
];

const DEFAULT_ACTIONS: PaletteAction[] = [
  { id: 'new-chain', label: 'New task chain', icon: 'tasks', hint: 'Start a chain' },
  { id: 'new-agent', label: 'New agent', icon: 'plus', hint: 'Create a durable identity' },
  { id: 'new-project', label: 'New project', icon: 'grid', hint: 'Grouping + paths' },
];

function matches(haystack: string, q: string): boolean {
  return haystack.toLowerCase().includes(q.toLowerCase());
}

function hitRoute(hit: SearchHit): string {
  // Prefer the backend-provided route; fall back to type-based routes.
  if (hit.route) return hit.route;
  const type = String(hit.type || '').toLowerCase();
  const id = hit.id;
  switch (type) {
    case 'conversation':
      return `/conversations/${id}`;
    case 'agent':
    case 'agent_instance':
      return `/agents/${id}`;
    case 'task-chain':
    case 'chain':
      return `/chains/${id}`;
    case 'task':
      return `/chains`;
    case 'project':
      return `/library`;
    case 'artifact':
      return `/library`;
    default:
      return '';
  }
}

function hitIcon(type: string): IconName {
  switch (String(type || '').toLowerCase()) {
    case 'conversation': return 'chat';
    case 'agent':
    case 'agent_instance': return 'tasks';
    case 'task-chain':
    case 'chain': return 'tasks';
    case 'task': return 'tasks';
    case 'project': return 'grid';
    case 'artifact': return 'device';
    case 'memory': return 'search';
    default: return 'chevron-right';
  }
}

export default function CommandPalette({ open, onClose, onNavigate, onAction, actions = DEFAULT_ACTIONS, conversationGroups = [] }: CommandPaletteProps) {
  const [query, setQuery] = useState('');
  const [debounced, setDebounced] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);

  // Debounce the search query (120–200ms per arch doc) to limit requests.
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(query), 150);
    return () => window.clearTimeout(timer);
  }, [query]);

  // Entity search via the backend global endpoint. RTK Query keeps only the
  // latest arg and aborts superseded requests, so results never jitter.
  const trimmed = debounced.trim();
  const searchQuery = useGlobalSearchQuery(
    { q: trimmed, limit: 12 },
    { skip: !open || trimmed.length < 1 },
  );

  // Reset on open/close.
  useEffect(() => {
    if (open) {
      setQuery('');
      setDebounced('');
      setActiveIndex(0);
      window.setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open]);

  // Build the grouped, flat result list.
  const results = useMemo<PaletteResult[]>(() => {
    const q = query.trim().toLowerCase();
    const out: PaletteResult[] = [];

    // Navigate (local, instant).
    const navItems = q ? DEFAULT_NAV.filter((item) => matches(item.label, q)) : DEFAULT_NAV;
    if (navItems.length) {
      navItems.forEach((item) => out.push({ kind: 'navigate', label: item.label, icon: item.icon, route: item.route, group: 'Navigate' }));
    }

    // Live conversations grouped by project — mirrors the sidebar rail. Each
    // project becomes its own palette group; filtered by query when typing.
    for (const group of conversationGroups) {
      const items = q
        ? group.conversations.filter((c) => matches(`${c.title} ${c.agentName || ''} ${group.projectName}`, q))
        : group.conversations;
      items.forEach((c) => out.push({
        kind: 'conversation',
        label: c.title || c.agentName || c.conversationId,
        hint: c.agentName && c.agentName !== c.title ? c.agentName : undefined,
        route: `/conversations/${c.conversationId}`,
        group: group.projectName || 'Conversations',
        convo: c,
      }));
    }

    // Entities from backend search (grouped by type).
    if (q && searchQuery.data) {
      for (const group of searchQuery.data.groups) {
        for (const hit of group.hits) {
          out.push({ kind: 'entity', label: hit.label || hit.id, hint: hit.sublabel, hit, route: hitRoute(hit), group: ENTITY_GROUP_LABEL[group.type] || group.type || 'Entities' });
        }
      }
    }

    // Actions (local, instant).
    const actionItems = q ? actions.filter((a) => matches(a.label, q)) : actions;
    if (actionItems.length) {
      actionItems.forEach((a) => out.push({ kind: 'action', label: a.label, hint: a.hint, icon: a.icon, actionId: a.id, group: 'Actions' }));
    }
    return out;
  }, [query, searchQuery.data, actions, conversationGroups]);

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

  function handleKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'Escape') {
      event.preventDefault();
      onClose();
    } else if (event.key === 'ArrowDown') {
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

  const loading = trimmed.length >= 1 && searchQuery.isFetching;

  return (
    <div
      data-debug-id="command-palette"
      className="fixed inset-0 z-[90] flex items-start justify-center bg-black/60 px-4 pt-[12vh] backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        data-debug-id="command-palette-panel"
        className="flex max-h-[70vh] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-white/10 bg-[#0d0f14] shadow-2xl shadow-black/50"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-white/10 px-4 py-3">
          <span aria-hidden="true" className="text-zinc-500"><Icon name="search" size={16} /></span>
          <input
            ref={inputRef}
            data-debug-id="command-palette-input"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a command or search…"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-zinc-100 outline-none placeholder:text-zinc-600"
            autoComplete="off"
            spellCheck={false}
          />
          {loading ? <span data-debug-id="command-palette-loading" className="text-[11px] text-zinc-500">searching…</span> : null}
          <kbd className="rounded border border-white/10 bg-white/5 px-1.5 py-0.5 text-[10px] text-zinc-500">esc</kbd>
        </div>
        <div ref={listRef} className="flex-1 overflow-y-auto p-2">
          {results.length === 0 ? (
            <div data-debug-id="command-palette-empty" className="px-3 py-8 text-center text-sm text-zinc-500">
              {trimmed ? `No results for “${trimmed}”.` : 'Start typing to search or jump.'}
            </div>
          ) : (
            Array.from(grouped.entries()).map(([groupLabel, { results: groupResults, indices }]) => (
              <div key={groupLabel} className="mb-1">
                <div data-debug-id={`command-palette-group-${groupLabel.toLowerCase().replace(/\s+/g, '-')}`} className="px-3 py-1 text-[10.5px] font-semibold uppercase tracking-[0.18em] text-zinc-600">{groupLabel}</div>
                {groupResults.map((result, i) => {
                  const idx = indices[i];
                  const active = idx === activeIndex;
                  const label = result.label;
                  const icon: IconName = result.kind === 'entity' ? hitIcon(result.hit.type || '') : ((result as any).icon || 'chevron-right');
                  const isConvo = result.kind === 'conversation';
                  const unread = isConvo ? Number(result.convo.unreadCount || 0) : 0;
                  return (
                    <button
                      key={`${groupLabel}-${idx}`}
                      type="button"
                      data-debug-id={`command-palette-result-${idx}`}
                      data-palette-index={idx}
                      onClick={() => activate(result)}
                      onMouseEnter={() => setActiveIndex(idx)}
                      className={`flex w-full items-center gap-3 rounded-lg px-3 py-2 text-left text-sm ${active ? 'bg-white/[0.08] text-zinc-100' : 'text-zinc-300 hover:bg-white/[0.04]'}`}
                    >
                      {isConvo ? (
                        <span aria-hidden="true" className="grid w-5 place-items-center"><span className={`h-2 w-2 rounded-full ${convoDotClass(result.convo)}`} /></span>
                      ) : (
                        <span aria-hidden="true" className="grid w-5 place-items-center text-zinc-400 opacity-80"><Icon name={icon} size={16} /></span>
                      )}
                      <span className="min-w-0 flex-1 truncate">{label}</span>
                      {unread > 0 ? <span className="ml-auto shrink-0 rounded-full bg-sky-400 px-1.5 text-center text-[10px] font-bold leading-4 text-black">{unread > 99 ? '99+' : unread}</span> : null}
                      {result.hint ? <span className="ml-auto shrink-0 truncate pl-2 text-[11px] text-zinc-500">{result.hint}</span> : null}
                    </button>
                  );
                })}
              </div>
            ))
          )}
        </div>
        <div className="flex items-center justify-between border-t border-white/10 px-4 py-2 text-[11px] text-zinc-600">
          <span className="flex items-center gap-2">
            <kbd className="rounded border border-white/10 bg-white/5 px-1.5 py-0.5">↑↓</kbd> navigate
            <kbd className="ml-2 rounded border border-white/10 bg-white/5 px-1.5 py-0.5">↵</kbd> select
          </span>
          <span data-debug-id="command-palette-search-source">{trimmed ? 'Entity results: /api/v1/search' : 'Heimdall'}</span>
        </div>
      </div>
    </div>
  );
}

const ENTITY_GROUP_LABEL: Record<string, string> = {
  conversation: 'Conversations',
  agent: 'Agents',
  agent_instance: 'Agents',
  'task-chain': 'Task Chains',
  task: 'Tasks',
  project: 'Projects',
  artifact: 'Artifacts',
  memory: 'Memory',
};
