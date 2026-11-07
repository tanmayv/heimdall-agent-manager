// Where a new chain lives (R4b). The default is the user's own online Bridge
// (an owner chain: the Bridge holds its tasks and history); the Hub is an
// explicit, non-default legacy option.

import React, { useEffect, useState } from 'react';
import { readBridgeRows } from '../../api/endpoints/bridgeSupport';
import { HUB_PLACEMENT, defaultChainPlacement, ownerBridgeChoices, type OwnerBridgeChoice } from '../../api/ownerChains';
import { getKeyringSession, subscribeKeyringSession } from '../../utils/vaultKeyringSession';

export interface ChainPlacementState {
  choices: OwnerBridgeChoice[];
  loading: boolean;
  /** Why no Bridge can own the chain right now ('' when one can). */
  reason: string;
  /** The default the modal starts from. */
  initial: string;
}

export function placementReason(hasSession: boolean, choices: OwnerBridgeChoice[]): string {
  if (!hasSession) return 'Unlock the vault on this device to keep the chain on your Bridge.';
  if (choices.length === 0) return 'No Bridge is enrolled in your vault yet.';
  if (!choices.some((c) => c.online)) return 'None of your enrolled Bridges is online.';
  return '';
}

export function useChainPlacementChoices(open: boolean, readRows: () => Promise<any[]> = readBridgeRows): ChainPlacementState {
  const [state, setState] = useState<ChainPlacementState>({ choices: [], loading: true, reason: '', initial: HUB_PLACEMENT });
  const [sessionTick, setSessionTick] = useState(0);
  useEffect(() => subscribeKeyringSession(() => setSessionTick((n) => n + 1)), []);
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    const session = getKeyringSession();
    setState((prev) => ({ ...prev, loading: true }));
    (async () => {
      let rows: any[] = [];
      try { rows = await readRows(); } catch { rows = []; }
      const choices = ownerBridgeChoices(session?.chain, rows);
      if (!cancelled) setState({ choices, loading: false, reason: placementReason(Boolean(session), choices), initial: defaultChainPlacement(choices) });
    })();
    return () => { cancelled = true; };
  }, [open, sessionTick, readRows]);
  return state;
}

export function ChainPlacementField({ value, onChange, state, hubOnly }: {
  value: string; onChange: (value: string) => void; state: ChainPlacementState; hubOnly?: string;
}) {
  const option = (id: string, label: string, detail: string, disabled: boolean, debugId: string) => (
    <label key={id} data-debug-id={debugId}
      className={`flex cursor-pointer items-start gap-2 rounded-xl border p-2.5 ${value === id ? 'border-accent bg-accent/10' : 'border-subtle bg-surface-raised'} ${disabled ? 'cursor-not-allowed opacity-50' : ''}`}>
      <input type="radio" name="chain-placement" value={id} checked={value === id} disabled={disabled}
        data-debug-id={`${debugId}-input`} onChange={() => onChange(id)} className="mt-0.5 accent-accent" />
      <span className="flex min-w-0 flex-col">
        <span className="text-xs font-bold text-primary">{label}</span>
        <span className="text-[11px] leading-tight text-muted">{detail}</span>
      </span>
    </label>
  );
  return (
    <fieldset data-debug-id="create-chain-placement" className="flex flex-col gap-1.5">
      <legend className="mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-muted">Where the chain lives</legend>
      {state.loading && <p role="status" className="text-[11px] text-muted">Checking your Bridges…</p>}
      {state.choices.map((c) => option(c.bridgeId, c.name, c.online ? 'Your Bridge keeps the tasks, comments and history. Recommended.' : 'Offline — bring this Bridge online to create a chain on it.',
        !c.online || Boolean(hubOnly), `create-chain-placement-bridge-${c.bridgeId}`))}
      {option(HUB_PLACEMENT, 'Hub (legacy)', 'The Hub stores the chain. Kept for existing workflows.', false, 'create-chain-placement-hub')}
      {(hubOnly || state.reason) && !state.loading && (
        <p data-debug-id="create-chain-placement-note" className="text-[11px] text-muted">{hubOnly || state.reason}</p>
      )}
    </fieldset>
  );
}
