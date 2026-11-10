// Fleet (Bridge-owned chains): the chain's fleet rows from fleet.policy.read,
// one per agent: placement (provider/model/bridge), capacity and whether the
// row takes new work. Edit, pause and resume write fleet.policy.set (as
// `ham-ctl task-chain fleet set|pause|resume`); live leases are unaffected.
// Rows are worker rows; reviewers are named per ticket.

import { useState } from 'react';
import { Button, EmptyState, FormField, IconButton, Input, StatusPill, Text } from '@ui';
import type { OwnerFleetPolicy, OwnerFleetPolicyChange } from '../../api/ownerChains';

export interface OwnerFleetTableProps {
  /** null while loading. */
  rows: OwnerFleetPolicy[] | null;
  error?: string;
  /** Hub agent id -> display name. */
  names?: Record<string, string>;
  /** False when the viewer cannot change the chain (offline, completed). */
  editable: boolean;
  busy: boolean;
  save: (row: OwnerFleetPolicy, change: OwnerFleetPolicyChange) => Promise<boolean>;
}

interface Draft { agentId: string; provider: string; model: string; bridgeId: string; capacity: string }

export function fleetPlacement(row: OwnerFleetPolicy): string {
  const model = [row.provider, row.model].filter(Boolean).join(' · ');
  return model || 'Agent default';
}

export function OwnerFleetTable({ rows, error, names = {}, editable, busy, save }: OwnerFleetTableProps) {
  const [draft, setDraft] = useState<Draft | null>(null);
  const [draftError, setDraftError] = useState('');

  async function submit(row: OwnerFleetPolicy) {
    if (!draft) return;
    const capacity = Number(draft.capacity);
    if (!Number.isInteger(capacity) || capacity < 1) { setDraftError('Capacity must be a whole number of at least 1.'); return; }
    setDraftError('');
    if (await save(row, { provider: draft.provider, model: draft.model, bridgeId: draft.bridgeId, capacity })) setDraft(null);
  }

  return (
    <section aria-label="Fleet" data-debug-id="owner-chain-fleet" className="space-y-1.5">
      <Text as="h3" role="overline" tone="muted">Fleet</Text>
      {error ? <Text as="p" role="caption" tone="danger" data-debug-id="owner-chain-fleet-error">{error}</Text>
        : rows === null ? <Text as="p" role="caption" tone="muted" aria-live="polite">Loading fleet…</Text>
        : rows.length === 0 ? <EmptyState data-debug-id="owner-chain-no-fleet" title="No fleet rows" description="The coordinator adds fleet rows with `ham-ctl task-chain fleet set`." />
        : (
          <ul className="space-y-1.5">
            {rows.map((row) => {
              const name = names[row.agentId];
              const editing = draft?.agentId === row.agentId;
              return (
                <li key={row.agentId} data-debug-id={`owner-chain-fleet-${row.agentId}`} className="space-y-2 rounded-lg border border-subtle bg-surface-raised px-3 py-2">
                  <div className="flex min-w-0 flex-wrap items-center gap-1.5">
                    <Text as="span" role="label" className="min-w-0 truncate" title={row.agentId}>{name || row.agentId}</Text>
                    {name && <Text as="code" role="code-sm" tone="muted">{row.agentId}</Text>}
                    <StatusPill tone={row.paused ? 'neutral' : 'success'} data-debug-id={`owner-chain-fleet-state-${row.agentId}`}>{row.paused ? 'Paused' : 'Active'}</StatusPill>
                    <Text as="span" role="caption" tone="muted" data-debug-id={`owner-chain-fleet-placement-${row.agentId}`}>
                      {fleetPlacement(row)}{row.bridgeId ? ` on ${row.bridgeId}` : ''} · capacity {row.capacity}
                    </Text>
                    {editable && !editing && (
                      <span className="ml-auto flex items-center gap-0.5">
                        <IconButton size="sm" variant="ghost" icon={row.paused ? 'play' : 'stop'} disabled={busy}
                          label={`${row.paused ? 'Resume' : 'Pause'} ${name || row.agentId}`}
                          data-debug-id={`owner-chain-fleet-${row.paused ? 'resume' : 'pause'}-${row.agentId}`}
                          onClick={() => void save(row, { paused: !row.paused })} />
                        <IconButton size="sm" variant="ghost" icon="pencil" disabled={busy} label={`Edit ${name || row.agentId}`}
                          data-debug-id={`owner-chain-fleet-edit-${row.agentId}`}
                          onClick={() => { setDraftError(''); setDraft({ agentId: row.agentId, provider: row.provider, model: row.model, bridgeId: row.bridgeId, capacity: String(row.capacity) }); }} />
                      </span>
                    )}
                  </div>
                  {editing && draft && (
                    <div className="grid gap-2 sm:grid-cols-2" data-debug-id={`owner-chain-fleet-form-${row.agentId}`}>
                      <FormField label="Provider" hint="Empty uses the agent's default.">
                        <Input size="sm" data-debug-id="owner-chain-fleet-provider" value={draft.provider} onChange={(v) => setDraft((d) => d && { ...d, provider: v })} />
                      </FormField>
                      <FormField label="Model">
                        <Input size="sm" data-debug-id="owner-chain-fleet-model" value={draft.model} onChange={(v) => setDraft((d) => d && { ...d, model: v })} />
                      </FormField>
                      <FormField label="Bridge" hint="Empty places it on the owner Bridge.">
                        <Input size="sm" data-debug-id="owner-chain-fleet-bridge" value={draft.bridgeId} onChange={(v) => setDraft((d) => d && { ...d, bridgeId: v })} />
                      </FormField>
                      <FormField label="Capacity">
                        <Input size="sm" inputMode="numeric" data-debug-id="owner-chain-fleet-capacity" value={draft.capacity} onChange={(v) => setDraft((d) => d && { ...d, capacity: v })} />
                      </FormField>
                      {draftError && <Text as="p" role="caption" tone="danger" className="sm:col-span-2" data-debug-id="owner-chain-fleet-form-error">{draftError}</Text>}
                      <div className="flex gap-2 sm:col-span-2">
                        <Button size="sm" data-debug-id="owner-chain-fleet-save" disabled={busy} onClick={() => void submit(row)}>Save</Button>
                        <Button size="sm" variant="ghost" disabled={busy} onClick={() => setDraft(null)}>Cancel</Button>
                      </div>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
    </section>
  );
}

export default OwnerFleetTable;
