import { useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { useListAgentsQuery, useLazyFetchAgentsPageQuery } from '../api/endpoints/agents';
import {
  AgentEntityType,
  AgentSelection,
  agentInstanceId,
  agentLabel,
  agentProject,
  agentProvider,
  agentTemplate,
  agentTier,
  durableAgentId,
  isAgentLive,
  isUserProxy,
  normalizeDefaultSelection,
  remoteRef,
  selectionKey,
} from '../api/agentIdentity';

// AgentPickerV2 — store-backed, caller-configured agent selector.
//
// The picker OWNS its data (reads agents + durable identities from the RTK
// Query store) and ALL filtering/search/grouping. Callers only configure WHAT
// is selectable (entity types), single vs multi, optional scope/predicate, and
// a default/pre-selected set to highlight. The picker performs NO side effects
// (no launching / binding) — it emits typed AgentSelection[] and lets the
// caller decide intent.
//
// Remote agents (bound proxies) appear inline with a `remote` tag; they are
// just local agent_instance_ids and are addressed by their local id.

export type AgentPickerV2Props = {
  debugId: string;

  // WHAT is selectable
  entityTypes?: AgentEntityType[];          // default ['agent_instance_id']
  projectId?: string;                        // optional scope filter
  includeRemoteProxies?: boolean;            // default true
  includeUserProxy?: boolean;                // default false
  filterPredicate?: (row: AgentRow) => boolean;

  // HOW selection behaves
  multiple?: boolean;                        // default false
  maxSelections?: number;                    // multi only; 0 = unlimited
  defaultSelected?: AgentSelection[] | string[];  // pre-highlighted selection
  autoFocusSearch?: boolean;

  // OUTPUT
  onChange?: (selected: AgentSelection[]) => void;   // fires on single-click (single mode) and on OK (multi)
  onConfirm?: (selected: AgentSelection[]) => void;  // multi-mode OK; falls back to onChange
  onCancel?: () => void;                     // multi-mode Cancel
  onClose?: () => void;                      // header × ; falls back to onCancel

  title?: string;
  emptyHint?: string;
};

export type AgentRow = {
  key: string;
  type: AgentEntityType;
  id: string;
  label: string;
  subtitle: string;
  section: 'agent-ids' | 'instances';
  live: boolean;
  remote: { daemonId: string; peerId: string } | null;
  isUser: boolean;
  conversationTitle: string;
  chips: string[];
  searchText: string;
  sortText: string;
};

function toSelection(row: AgentRow): AgentSelection {
  const sel: AgentSelection = { type: row.type, id: row.id, label: row.label, live: row.live };
  if (row.remote) sel.remote = { daemonId: row.remote.daemonId, peerId: row.remote.peerId };
  return sel;
}

export default function AgentPickerV2({
  debugId,
  entityTypes = ['agent_instance_id'],
  projectId = '',
  includeRemoteProxies = true,
  includeUserProxy = false,
  filterPredicate,
  multiple = false,
  maxSelections = 0,
  defaultSelected,
  autoFocusSearch = false,
  onChange,
  onConfirm,
  onCancel,
  onClose,
  title = 'Select agents',
  emptyHint = 'No matching agents.',
}: AgentPickerV2Props) {
  const session = useSelector((state: any) => state.chat?.session || {});
  const conversationSummaryById = useSelector((state: any) => state.chat?.conversationSummaryById || {});
  const agentsQuery = useListAgentsQuery(undefined, { skip: !session?.daemonUrl });
  const [triggerFetchAgentsPage, fetchAgentsPageResult] = useLazyFetchAgentsPageQuery();
  const agents: any[] = agentsQuery.data?.agents || [];
  const handleLoadMore = () => {
    if (agentsQuery.isFetching || fetchAgentsPageResult.isFetching) return;
    const nextOffset = agents.length;
    triggerFetchAgentsPage({ limit: 20, offset: nextOffset });
  };
  const identities: any[] = agentsQuery.data?.identities || [];

  const wantId = entityTypes.includes('agent_id');
  const wantInstance = entityTypes.includes('agent_instance_id');

  const fallbackType: AgentEntityType = wantInstance ? 'agent_instance_id' : 'agent_id';
  const initialSelection = useMemo(
    () => normalizeDefaultSelection(defaultSelected, fallbackType),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [JSON.stringify(defaultSelected), fallbackType],
  );

  const [selection, setSelection] = useState<AgentSelection[]>(initialSelection);
  const [query, setQuery] = useState('');

  // Re-sync when the caller changes the default set (e.g. reopening for another task).
  useEffect(() => {
    setSelection(initialSelection);
  }, [initialSelection]);

  const isSelected = (key: string) => selection.some((s) => selectionKey(s) === key);

  const rows = useMemo(() => {
    const out: AgentRow[] = [];

    if (wantId) {
      for (const idn of identities) {
        const id = String(idn?.agent_id || idn?.agentId || '');
        if (!id || id === 'user_proxy') continue;
        const rr = remoteRef(idn);
        if (rr && !includeRemoteProxies) continue;
        if (projectId) {
          const scope = String(idn?.default_project_id || idn?.defaultProjectId || '');
          if (scope && scope !== projectId) continue;
        }
        const label = String(idn?.display_name || idn?.displayName || id);
        const template = String(idn?.template_id || idn?.templateId || '');
        const provider = String(idn?.default_provider_profile || idn?.defaultProviderProfile || '');
        const tier = String(idn?.default_model_tier || idn?.defaultModelTier || 'normal');
        const chips = [rr ? `remote · ${rr.daemonId}` : '', 'new instance', template, tier].filter(Boolean);
        out.push({
          key: `agent_id:${id}`,
          type: 'agent_id',
          id,
          label,
          subtitle: `agent_id: ${id}${rr ? ` · ${rr.daemonId}` : ''}`,
          section: 'agent-ids',
          live: false,
          remote: rr,
          isUser: false,
          conversationTitle: '',
          chips,
          searchText: [label, id, template, provider, rr?.daemonId, rr?.peerId].filter(Boolean).join(' ').toLowerCase(),
          sortText: `${label} ${id}`.toLowerCase(),
        });
      }
    }

    if (wantInstance) {
      for (const agent of agents) {
        const id = agentInstanceId(agent);
        if (!id || isUserProxy(agent)) continue;
        const rr = remoteRef(agent);
        if (rr && !includeRemoteProxies) continue;
        if (projectId && agentProject(agent) && agentProject(agent) !== projectId) continue;
        const label = agentLabel(agent);
        const template = agentTemplate(agent);
        const provider = agentProvider(agent);
        const durable = durableAgentId(agent);
        const live = isAgentLive(agent);
        const conversationTitle = String(conversationSummaryById?.[id]?.title || '').trim();
        const project = agentProject(agent);
        const chips = [
          rr ? `remote · ${rr.daemonId}` : '',
          template,
          provider,
          project ? `home ${project}` : '',
          durable === 'conversation' ? 'conversation' : '',
        ].filter(Boolean);
        out.push({
          key: `agent_instance_id:${id}`,
          type: 'agent_instance_id',
          id,
          label,
          subtitle: `${id}${rr ? ` · ${rr.daemonId} via ${rr.peerId}` : ''}`,
          section: 'instances',
          live,
          remote: rr,
          isUser: false,
          conversationTitle,
          chips,
          searchText: [label, id, durable, template, provider, project, conversationTitle, rr?.daemonId, rr?.peerId]
            .filter(Boolean)
            .join(' ')
            .toLowerCase(),
          sortText: `${label} ${id}`.toLowerCase(),
        });
      }

      if (includeUserProxy) {
        out.push({
          key: 'agent_instance_id:user_proxy',
          type: 'agent_instance_id',
          id: 'user_proxy',
          label: 'User / operator',
          subtitle: 'user_proxy',
          section: 'instances',
          live: false,
          remote: null,
          isUser: true,
          conversationTitle: '',
          chips: ['operator'],
          searchText: 'user proxy operator user_proxy',
          sortText: '  user proxy',
        });
      }
    }

    const filtered = filterPredicate ? out.filter(filterPredicate) : out;
    return filtered.sort((a, b) => a.sortText.localeCompare(b.sortText));
  }, [agents, identities, wantId, wantInstance, includeRemoteProxies, includeUserProxy, projectId, conversationSummaryById, filterPredicate]);

  const visibleRows = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? rows.filter((r) => r.searchText.includes(q)) : rows;
  }, [rows, query]);

  const grouped = useMemo(() => {
    const idRows = visibleRows.filter((r) => r.section === 'agent-ids');
    const instRows = visibleRows.filter((r) => r.section === 'instances');
    return { idRows, instRows };
  }, [visibleRows]);

  const maxed = multiple && maxSelections > 0 && selection.length >= maxSelections;

  function toggleRow(row: AgentRow, disabled: boolean) {
    if (disabled) return;
    const key = row.key;
    if (!multiple) {
      const next = [toSelection(row)];
      setSelection(next);
      onChange?.(next);
      return;
    }
    if (isSelected(key)) {
      setSelection((prev) => prev.filter((s) => selectionKey(s) !== key));
    } else {
      if (maxSelections > 0 && selection.length >= maxSelections) return;
      setSelection((prev) => [...prev, toSelection(row)]);
    }
  }

  function removeChip(key: string) {
    setSelection((prev) => prev.filter((s) => selectionKey(s) !== key));
  }

  function handleClose() {
    if (onClose) onClose();
    else onCancel?.();
  }

  function handleConfirm() {
    if (!selection.length) return;
    if (onConfirm) onConfirm(selection);
    else onChange?.(selection);
  }

  function renderRow(row: AgentRow) {
    const selected = isSelected(row.key);
    const disabled = !selected && maxed;
    const lead = multiple ? (
      <div className={`mt-0.5 flex h-[18px] w-[18px] flex-none items-center justify-center rounded-md border text-[12px] ${selected ? 'border-sky-400 bg-sky-400 text-black' : 'border-white/25'}`}>{selected ? '✓' : ''}</div>
    ) : (
      <div
        className={`mt-1.5 h-2.5 w-2.5 flex-none rounded-full ${row.live ? 'bg-emerald-400 shadow-[0_0_0_3px_rgba(52,211,153,0.18)]' : 'bg-zinc-600'}`}
        title={row.live ? 'live' : 'offline'}
      />
    );
    return (
      <button
        key={row.key}
        type="button"
        data-debug-id={`${debugId}-row-${row.key}`}
        aria-pressed={selected}
        disabled={disabled}
        onClick={() => toggleRow(row, disabled)}
        className={`flex w-full items-start gap-2.5 rounded-2xl border px-3 py-2.5 text-left transition ${
          selected
            ? 'border-sky-400/55 bg-sky-400/10'
            : row.type === 'agent_id'
              ? 'border-dashed border-violet-400/25 bg-violet-400/[0.05] hover:border-violet-400/40 hover:bg-violet-400/[0.08]'
              : 'border-white/10 bg-black/20 hover:border-white/20 hover:bg-white/[0.04]'
        } ${disabled ? 'cursor-not-allowed opacity-40' : ''}`}
      >
        {lead}
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5">
            {multiple ? (
              <span className={`h-2 w-2 flex-none rounded-full ${row.live ? 'bg-emerald-400' : 'bg-zinc-600'}`} />
            ) : null}
            <span className="truncate text-sm font-semibold text-zinc-100">{row.label}</span>
            {row.remote ? <span data-debug-id={`${debugId}-row-remote-tag-${row.key}`} className="flex-none rounded-md bg-teal-400/15 px-1.5 py-0.5 text-[9.5px] font-bold uppercase tracking-wide text-teal-200">remote</span> : null}
            {row.isUser ? <span className="flex-none rounded-md bg-white/10 px-1.5 py-0.5 text-[9.5px] font-bold uppercase tracking-wide text-zinc-100">user</span> : null}
          </div>
          <div className="mt-0.5 truncate font-mono text-[11px] text-zinc-500">{row.subtitle}</div>
          {row.conversationTitle ? <div className="mt-0.5 truncate text-[11px] text-sky-200">Conversation: <span className="text-zinc-300">{row.conversationTitle}</span></div> : null}
          {row.chips.length ? (
            <div className="mt-1.5 flex flex-wrap gap-1.5">
              {row.chips.map((chip) => (
                <span key={chip} className={`max-w-full truncate rounded-full px-2 py-0.5 text-[10px] ${chip.startsWith('remote ·') ? 'bg-teal-400/12 text-teal-200' : 'bg-white/[0.05] text-zinc-400'}`}>{chip}</span>
              ))}
            </div>
          ) : null}
        </div>
      </button>
    );
  }

  const loading = agentsQuery.isLoading || agentsQuery.isFetching;

  return (
    <div data-debug-id={debugId} className="rounded-2xl border border-white/10 bg-black/20 p-3 text-sm">
      <div className="flex items-center justify-between gap-3">
        <div className="font-medium text-zinc-100">{title}</div>
        <div className="flex items-center gap-2">
          <span className="rounded-full bg-white/5 px-2.5 py-1 text-[11px] text-zinc-400">
            {multiple ? (maxSelections > 0 ? `multiple · max ${maxSelections}` : 'multiple') : 'single'}
          </span>
          <button
            type="button"
            data-debug-id={`${debugId}-close-btn`}
            onClick={handleClose}
            className="flex h-7 w-7 items-center justify-center rounded-lg border border-white/10 bg-white/[0.03] text-zinc-400 transition hover:border-white/20 hover:text-zinc-100"
            aria-label="Close"
          >
            ×
          </button>
        </div>
      </div>

      {selection.length ? (
        <div data-debug-id={`${debugId}-selected-summary`} className="mt-3 flex flex-wrap items-center gap-1.5">
          {selection.map((s) => {
            const key = selectionKey(s);
            return (
              <span
                key={key}
                data-debug-id={`${debugId}-chip-${key}`}
                className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[12px] ${s.remote ? 'border-teal-400/40 bg-teal-400/12 text-teal-100' : 'border-sky-400/35 bg-sky-400/12 text-sky-50'}`}
              >
                <span className="max-w-[220px] truncate">{s.type === 'agent_id' ? '🆔' : '▣'} {s.id}{s.remote ? ` · ${s.remote.daemonId}` : ''}</span>
                <button type="button" data-debug-id={`${debugId}-chip-remove-btn-${key}`} onClick={() => removeChip(key)} className="text-current/70 hover:text-white" aria-label={`Remove ${s.id}`}>×</button>
              </span>
            );
          })}
          {multiple && selection.length ? (
            <button type="button" data-debug-id={`${debugId}-clear-all-btn`} onClick={() => setSelection([])} className="ml-auto text-[11px] text-zinc-500 hover:text-zinc-200">clear {selection.length}</button>
          ) : null}
        </div>
      ) : null}

      <input
        autoFocus={autoFocusSearch}
        data-debug-id={`${debugId}-search-input`}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search agents, ids, daemons…"
        className="mt-3 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
      />

      <div data-debug-id={`${debugId}-results`} className="mt-3 max-h-[400px] space-y-2 overflow-y-auto pr-1">
        {loading && rows.length === 0 ? (
          <div data-debug-id={`${debugId}-loading`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">Loading agents…</div>
        ) : visibleRows.length === 0 ? (
          <div data-debug-id={`${debugId}-empty`} className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">{emptyHint}</div>
        ) : (
          <>
            {grouped.idRows.length ? (
              <div data-debug-id={`${debugId}-section-agent-ids`}>
                <div className="px-1 pb-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Durable agent IDs</div>
                <div className="space-y-2">{grouped.idRows.map(renderRow)}</div>
              </div>
            ) : null}
            {grouped.instRows.length ? (
              <div data-debug-id={`${debugId}-section-instances`}>
                <div className="px-1 pb-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-zinc-500">Instances</div>
                <div className="space-y-2">{grouped.instRows.map(renderRow)}</div>
              </div>
            ) : null}
            {wantInstance && agentsQuery.data?.hasMore && (
              <div className="pt-2 flex justify-center">
                <button
                  type="button"
                  data-debug-id={`${debugId}-load-more-btn`}
                  onClick={handleLoadMore}
                  disabled={fetchAgentsPageResult.isFetching}
                  className="rounded-lg border border-white/10 px-3 py-1.5 text-xs text-zinc-400 hover:bg-[#141414] hover:text-zinc-100 disabled:opacity-50"
                >
                  {fetchAgentsPageResult.isFetching ? 'Loading…' : 'Show more instances'}
                </button>
              </div>
            )}
          </>
        )}
      </div>

      {multiple ? (
        <div data-debug-id={`${debugId}-footer`} className="mt-3 flex items-center gap-3 border-t border-white/10 pt-3">
          <span className="text-[12px] text-zinc-400">{selection.length} selected{maxSelections > 0 ? ` / ${maxSelections}` : ''}</span>
          <button type="button" data-debug-id={`${debugId}-cancel-btn`} onClick={() => onCancel?.()} className="ml-auto rounded-xl border border-white/10 bg-white/[0.04] px-4 py-2 text-[13px] font-semibold text-zinc-200 transition hover:border-white/20 hover:bg-white/[0.07]">Cancel</button>
          <button type="button" data-debug-id={`${debugId}-ok-btn`} onClick={handleConfirm} disabled={selection.length === 0} className="rounded-xl bg-sky-400 px-5 py-2 text-[13px] font-semibold text-[#05141c] transition hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-40">OK</button>
        </div>
      ) : null}
    </div>
  );
}
