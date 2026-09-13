/**
 * RuntimeChip — a product pattern: an agent instance's runtime status chip.
 * ------------------------------------------------------------------
 * Purpose: the chip shown under a conversation title answering "which bridge /
 * provider / tier is this on, and is it running?" — a `StatusDot` + state label +
 * bridge·provider·tier, with an optional "Change" affordance.
 *
 * Layer: pattern (product-specific). Built from @ui primitives (StatusDot, Icon).
 * Backed by existing instance data (runtime_status / bridge / provider / tier);
 * no new backend.
 *
 * The three UI states are derived from the many raw `runtime_status` strings via
 * `runtimeStateFromStatus`. Tokens only — the old emerald/amber/zinc + rgba glow
 * are replaced by the semantic StatusDot tones and text tokens.
 */
import React from 'react';
import { Icon, StatusDot } from '../primitives';
import type { Tone } from '../types';

export type RuntimeState = 'live' | 'starting' | 'stopped';

/** Normalize the many instance `runtime_status` strings into three UI states. */
export function runtimeStateFromStatus(status: string): RuntimeState {
  const s = String(status || '').toLowerCase();
  if (['idle', 'running', 'busy', 'ready', 'live', 'active'].includes(s)) return 'live';
  if (['starting', 'launching', 'restarting', 'pending', 'booting'].includes(s)) return 'starting';
  return 'stopped';
}

export function runtimeStateLabel(state: RuntimeState): string {
  return state === 'live' ? 'Running' : state === 'starting' ? 'Starting' : 'Stopped';
}

/**
 * THE canonical runtime-liveness tone map. Every status DOT that means
 * "is this running?" resolves its color through here (via `runtimeStatusToTone`)
 * so live/starting/stopped read identically everywhere — no more per-file
 * emerald/amber/zinc ladders. (EL-050 status-dot consolidation.)
 */
export const RUNTIME_STATE_TONE: Record<RuntimeState, Tone> = {
  live: 'success',
  starting: 'pending',
  stopped: 'neutral',
};

/** Raw `runtime_status` string → semantic `Tone`, in one hop. */
export function runtimeStatusToTone(status: string): Tone {
  return RUNTIME_STATE_TONE[runtimeStateFromStatus(status)];
}

const STATE_TONE = RUNTIME_STATE_TONE;

const STATE_TEXT: Record<RuntimeState, string> = {
  live: 'text-success',
  starting: 'text-warning',
  stopped: 'text-muted',
};

export interface RuntimeChipProps {
  state: RuntimeState;
  bridgeLabel: string;
  provider: string;
  tier: string;
  /** Opens the change popover/sheet (wired by the caller). */
  onClick?: () => void;
  /** Test hook. */
  debugId?: string;
  /** Show the "Change" affordance. Default true. */
  showChange?: boolean;
}

export function RuntimeChip({
  state,
  bridgeLabel,
  provider,
  tier,
  onClick,
  debugId,
  showChange = true,
}: RuntimeChipProps) {
  const parts = [bridgeLabel, provider, tier].filter(Boolean);
  return (
    <button
      type="button"
      data-debug-id={debugId}
      onClick={onClick}
      className="mt-1 inline-flex max-w-full items-center gap-2 whitespace-nowrap rounded-pill border border-subtle px-2.5 py-1 text-[length:var(--text-caption-size)] text-muted transition-colors hover:border-strong hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
    >
      <StatusDot tone={STATE_TONE[state]} pulse={state === 'starting'} label={runtimeStateLabel(state)} />
      <span className={`font-bold ${STATE_TEXT[state]}`}>{runtimeStateLabel(state)}</span>
      {parts.length ? <span aria-hidden="true" className="text-faint">·</span> : null}
      <span className="truncate">
        {parts.map((p, i) => (
          <span key={p + i}>
            {i > 0 ? <span aria-hidden="true" className="text-faint"> · </span> : null}
            <span className="font-semibold text-primary">{p}</span>
          </span>
        ))}
      </span>
      {showChange ? (
        <span className="ml-0.5 flex items-center gap-0.5 border-l border-subtle pl-2 text-muted">
          Change <Icon name="chevron-down" size="sm" />
        </span>
      ) : null}
    </button>
  );
}

export default RuntimeChip;
