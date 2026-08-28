// Runtime primitives for the conversations-first UI rework.
//
// A coordinator conversation runs on a concrete agent instance. Users kept asking
// "which bridge/model is this on, and is it even running?" — these primitives make
// that plain: a color-coded status dot + an explicit label + bridge/provider/tier.
//
// Backed entirely by existing data: instance `runtime_status`, `bridge_id`,
// `provider`, `tier` (agents.ts useFetchAgentInstanceQuery) and bridge labels from
// listBridges. No new backend.

import Icon from '../Icon';

export type RuntimeState = 'live' | 'starting' | 'stopped';

// Normalize the many instance runtime_status strings into three UI states.
// Live: the wrapper is connected (idle/running/busy/ready/live).
// Starting: mid-launch (starting/launching/restarting/pending).
// Stopped: everything else (stopped/failed/unreachable/empty).
export function runtimeStateFromStatus(status: string): RuntimeState {
  const s = String(status || '').toLowerCase();
  if (['idle', 'running', 'busy', 'ready', 'live', 'active'].includes(s)) return 'live';
  if (['starting', 'launching', 'restarting', 'pending', 'booting'].includes(s)) return 'starting';
  return 'stopped';
}

export function runtimeStateLabel(state: RuntimeState): string {
  return state === 'live' ? 'Running' : state === 'starting' ? 'Starting' : 'Stopped';
}

const DOT_CLASS: Record<RuntimeState, string> = {
  live: 'bg-emerald-400 shadow-[0_0_8px_rgba(52,211,153,0.7)]',
  starting: 'bg-amber-400 animate-pulse',
  stopped: 'bg-zinc-500',
};

const TEXT_CLASS: Record<RuntimeState, string> = {
  live: 'text-emerald-300',
  starting: 'text-amber-300',
  stopped: 'text-zinc-400',
};

export function StatusDot({ state, className = '', debugId }: { state: RuntimeState; className?: string; debugId?: string }) {
  return (
    <span
      data-debug-id={debugId}
      className={`inline-block h-2 w-2 rounded-full ${DOT_CLASS[state]} ${className}`.trim()}
      aria-hidden="true"
    />
  );
}

// The clickable runtime chip shown under a conversation title. `onClick` opens the
// change popover/sheet (wired by the caller). When there is no known runtime yet
// (e.g. instance not resolved), pass state='stopped' with placeholder text.
export default function RuntimeChip({
  state,
  bridgeLabel,
  provider,
  tier,
  onClick,
  debugId,
  showChange = true,
}: {
  state: RuntimeState;
  bridgeLabel: string;
  provider: string;
  tier: string;
  onClick?: () => void;
  debugId?: string;
  showChange?: boolean;
}) {
  const parts = [bridgeLabel, provider, tier].filter(Boolean);
  return (
    <button
      type="button"
      data-debug-id={debugId}
      onClick={onClick}
      className="mt-1 inline-flex max-w-full items-center gap-2 whitespace-nowrap rounded-full border border-white/10 px-2.5 py-1 text-[11.5px] text-zinc-400 hover:border-white/25 hover:text-zinc-100"
    >
      <StatusDot state={state} />
      <span className={`font-bold ${TEXT_CLASS[state]}`}>{runtimeStateLabel(state)}</span>
      {parts.length ? <span className="text-zinc-600">·</span> : null}
      <span className="truncate">
        {parts.map((p, i) => (
          <span key={p + i}>
            {i > 0 ? <span className="text-zinc-600"> · </span> : null}
            <span className="font-semibold text-zinc-200">{p}</span>
          </span>
        ))}
      </span>
      {showChange ? (
        <span className="ml-0.5 flex items-center gap-0.5 border-l border-white/10 pl-2 text-zinc-500">
          Change <Icon name="chevron-down" size={12} />
        </span>
      ) : null}
    </button>
  );
}
