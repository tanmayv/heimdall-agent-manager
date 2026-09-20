// Agent Monitor — full-screen grid of live agent terminals (REQ-AM-3..9).
//
// Renders the user's pinned agents (persisted per-browser via clientPersistence) as a
// responsive grid whose rows are exactly half the viewport height below the header, so
// two rows fill the screen and only additional rows scroll. Each cell shows the agent's
// status + start/stop + unpin controls, its live terminal, and a slim composer. An Add
// Pane dialog lets the user pin more agents from a searchable list.

import { useEffect, useMemo, useState } from 'react';
import Icon from '../Icon';
import { readPinnedMonitorAgents, writePinnedMonitorAgents } from '../../utils/clientPersistence';
import {
  useFetchAgentInstanceQuery,
  useListAgentInstancesQuery,
  useStartAgentInstanceMutation,
  useStopAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { AgentPaneComposerPanel } from '../chat/AgentPaneComposerPanel';
import { AgentCellComposer } from './AgentCellComposer';

// ---- One monitor cell -------------------------------------------------------

function MonitorCell({ agentInstanceId, onUnpin }: { agentInstanceId: string; onUnpin: () => void }) {
  const { data } = useFetchAgentInstanceQuery({ instanceId: agentInstanceId });
  const instance = data?.instance;
  const displayName: string = instance?.display_name || agentInstanceId;
  const runtimeStatus: string = instance?.runtime_status || '';
  const agentId: string = instance?.agent_id || '';
  const conversationId: string = instance?.conversation_id ?? '';
  const running = runtimeStatus === 'running';

  const [startInstance, startState] = useStartAgentInstanceMutation();
  const [stopInstance, stopState] = useStopAgentInstanceMutation();
  const busy = startState.isLoading || stopState.isLoading;

  const toggleRun = () => {
    if (!agentId) return;
    if (running) void stopInstance({ agentId, instanceId: agentInstanceId });
    else void startInstance({ agentId, instanceId: agentInstanceId });
  };

  return (
    <div data-debug-id={`monitor-cell-${agentInstanceId}`} className="flex min-h-0 flex-col overflow-hidden rounded-lg border border-subtle bg-surface">
      {/* Cell header */}
      <div className="flex h-8 shrink-0 items-center gap-2 border-b border-subtle bg-surface-raised px-2">
        <span className={`h-2 w-2 shrink-0 rounded-full ${running ? 'bg-success' : 'bg-muted/50'}`} title={runtimeStatus || 'unknown'} />
        <span className="min-w-0 flex-1 truncate text-[12px] font-medium text-primary" title={displayName}>{displayName}</span>
        <button
          type="button"
          onClick={toggleRun}
          disabled={busy || !agentId}
          title={running ? 'Stop agent' : 'Start agent'}
          aria-label={running ? 'Stop agent' : 'Start agent'}
          data-debug-id={`monitor-cell-runtoggle-${agentInstanceId}`}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40"
        >
          <Icon name={running ? 'stop' : 'play'} size={12} />
        </button>
        <button
          type="button"
          onClick={onUnpin}
          title="Unpin from monitor"
          aria-label="Unpin from monitor"
          data-debug-id={`monitor-cell-unpin-${agentInstanceId}`}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="close" size={12} />
        </button>
      </div>
      {/* Live terminal (fills remaining height; only it scrolls) */}
      <AgentPaneComposerPanel agentInstanceId={agentInstanceId} isExpanded={true} className="min-h-0 flex-1 overflow-hidden" />
      {/* Slim composer */}
      <AgentCellComposer agentInstanceId={agentInstanceId} conversationId={conversationId} />
    </div>
  );
}

// ---- Add Pane dialog --------------------------------------------------------

function AddPaneDialog({ pinned, onAdd, onClose }: { pinned: string[]; onAdd: (id: string) => void; onClose: () => void }) {
  const [search, setSearch] = useState('');
  const { data, isLoading } = useListAgentInstancesQuery({ limit: 200 });
  const instances: any[] = data?.instances || [];

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const q = search.trim().toLowerCase();
  const filtered = instances.filter((i) => {
    const id = String(i?.agent_instance_id || '');
    const name = String(i?.display_name || '');
    if (!id) return false;
    if (!q) return true;
    return name.toLowerCase().includes(q) || id.toLowerCase().includes(q);
  });

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose} data-debug-id="monitor-add-pane-overlay">
      <div className="flex max-h-[70vh] w-80 flex-col gap-2 rounded-lg border border-subtle bg-surface p-2 shadow-lg" onClick={(e) => e.stopPropagation()}>
        <input
          autoFocus
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search agents…"
          data-debug-id="monitor-add-pane-search"
          className="w-full rounded border border-subtle bg-canvas px-2 py-1 text-[12px] text-primary placeholder:text-muted focus:outline-none focus:ring-1 focus:ring-accent"
        />
        <div className="min-h-0 flex-1 overflow-y-auto">
          {isLoading ? (
            <div className="p-3 text-center text-xs text-muted">Loading…</div>
          ) : filtered.length === 0 ? (
            <div className="p-3 text-center text-xs text-muted">No agents found.</div>
          ) : (
            filtered.map((i) => {
              const id = String(i.agent_instance_id);
              const already = pinned.includes(id);
              return (
                <button
                  key={id}
                  type="button"
                  disabled={already}
                  onClick={() => onAdd(id)}
                  title={id}
                  data-debug-id={`monitor-add-pane-item-${id}`}
                  className={`flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-[12px] ${already ? 'opacity-40' : 'hover:bg-neutral-soft'}`}
                >
                  <span className={`h-2 w-2 shrink-0 rounded-full ${i?.runtime_status === 'running' ? 'bg-success' : 'bg-muted/50'}`} />
                  <span className="min-w-0 flex-1 truncate text-primary">{i?.display_name || id}</span>
                  {already ? <span className="shrink-0 text-[10px] text-muted">pinned</span> : null}
                </button>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
}

// ---- Page -------------------------------------------------------------------

export function AgentMonitorPage() {
  const [pinned, setPinned] = useState<string[]>(readPinnedMonitorAgents);
  const [addOpen, setAddOpen] = useState(false);

  // Persist to localStorage on every change.
  useEffect(() => { writePinnedMonitorAgents(pinned); }, [pinned]);

  const addPinned = (id: string) => {
    setPinned((prev) => (prev.includes(id) ? prev : [...prev, id]));
    setAddOpen(false);
  };
  const unpin = (id: string) => setPinned((prev) => prev.filter((x) => x !== id));
  const clearAll = () => {
    if (pinned.length === 0) return;
    if (typeof window !== 'undefined' && !window.confirm('Remove all pinned agents from the monitor?')) return;
    setPinned([]);
  };

  const cells = useMemo(() => pinned, [pinned]);

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-canvas">
      {/* Header */}
      <div className="flex h-12 shrink-0 items-center gap-3 border-b border-subtle bg-surface px-3">
        <span className="text-[14px] font-semibold text-primary">Agent Monitor</span>
        <span className="text-[11px] text-muted">{pinned.length} pinned</span>
        <div className="ml-auto flex items-center gap-2">
          <button
            type="button"
            onClick={() => setAddOpen(true)}
            data-debug-id="monitor-add-pane-btn"
            className="inline-flex items-center gap-1 rounded border border-subtle bg-neutral-soft px-2 py-1 text-[12px] font-medium text-muted hover:text-primary"
          >
            <Icon name="plus" size={12} />
            <span>Add Pane</span>
          </button>
          <button
            type="button"
            onClick={clearAll}
            disabled={pinned.length === 0}
            data-debug-id="monitor-clear-all-btn"
            className="inline-flex items-center gap-1 rounded border border-subtle px-2 py-1 text-[12px] font-medium text-muted hover:text-primary disabled:opacity-40"
          >
            <Icon name="trash" size={12} />
            <span>Clear All</span>
          </button>
        </div>
      </div>

      {/* Grid body — rows are half the viewport below the 3rem header, so 2 rows fill it */}
      <div className="min-h-0 flex-1 overflow-y-auto">
        {cells.length === 0 ? (
          <div className="grid h-full place-items-center p-8 text-center text-sm text-muted">
            No agents pinned. Use “Add Pane” to pin one, or the pin button on an agent’s terminal.
          </div>
        ) : (
          <div className="grid grid-cols-1 gap-2 p-2 auto-rows-[calc((100vh-3rem)/2)] md:grid-cols-2 xl:grid-cols-3">
            {cells.map((id) => (
              <MonitorCell key={id} agentInstanceId={id} onUnpin={() => unpin(id)} />
            ))}
          </div>
        )}
      </div>

      {addOpen ? <AddPaneDialog pinned={pinned} onAdd={addPinned} onClose={() => setAddOpen(false)} /> : null}
    </div>
  );
}

export default AgentMonitorPage;
