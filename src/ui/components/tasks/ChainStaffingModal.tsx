import { useRef, useState } from 'react';
import { Button, Input, Modal, ModalBody, ModalFooter, Select, Text } from '@ui';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { taskChainsApi, useGetTaskChainFleetsQuery, useUpdateTaskChainFleetMutation, type TaskChainFleet } from '../../api/endpoints/taskChains';
import { useDispatch } from 'react-redux';
import { bridgeIdOf, bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { apiErrorText } from '../../api/cookieFetch';
import { formatFleetRoleName } from './fleetNames';
import { fleetFocusHref } from '../home/fleetDraft';

/** Chain staffing and placement only. Runtime policy lives in Home Fleet. */
export function ChainStaffingModal({ chainId, open, onClose, focusRole = 'worker' }: { chainId: string; open: boolean; onClose: () => void; focusRole?: string }) {
  const dispatch = useDispatch<any>();
  const rows = useGetTaskChainFleetsQuery({ chainId }, { skip: !open });
  const identities = useListAgentIdentitiesQuery(undefined, { skip: !open });
  const bridges = useListBridgesQuery(undefined, { skip: !open });
  const [update] = useUpdateTaskChainFleetMutation();
  const [agentId, setAgentId] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const lock = useRef(false);
  const run = async (fn: () => Promise<unknown>) => {
    if (lock.current) return;
    lock.current = true; setBusy(true); setError('');
    try { await fn(); } catch (e) { setError(apiErrorText(e)); } finally { lock.current = false; setBusy(false); }
  };
  const save = (row: TaskChainFleet, patch: Partial<{ capacity: number; minWarm: number; idleTtlSeconds: number; bridgeId: string; roles: string[] }>) =>
    update({ chainId, agentId: row.agent_id, capacity: row.capacity, minWarm: row.min_warm, idleTtlSeconds: row.idle_ttl_seconds, ...patch }).unwrap();
  const agents: any[] = identities.data?.agents || [];
  const failed = rows.isError || identities.isError || bridges.isError;
  return <Modal open={open} onOpenChange={(next) => !next && onClose()} title="Chain staffing" size="md" data-debug-id="chain-staffing-modal">
    <ModalBody className="space-y-4">
      <Text role="body-sm" tone="muted">Staffing and bridge placement affect future grants in this chain. Existing leases and required reviews stay in place.</Text>
      <a href={fleetFocusHref()} data-debug-id="chain-staffing-home-fleet" onClick={onClose} className="text-accent underline">Runtime defaults and overrides in Home Fleet</a>
      {failed ? <div role="alert">Could not load staffing. <Button size="sm" data-debug-id="chain-staffing-refresh" onClick={() => { void rows.refetch(); void identities.refetch(); void bridges.refetch(); }}>Retry</Button></div> : !rows.data || !identities.data || !bridges.data ? <Text role="body-sm">Loading staffing…</Text> : <>
        {(rows.data || []).map((row) => <StaffingRow key={row.agent_id} row={row} name={formatFleetRoleName(row.agent_id, agents)} bridges={bridges.data.bridges || []} busy={busy} onSave={(patch) => void run(() => save(row, patch))} onPause={(paused) => void run(() => dispatch(taskChainsApi.endpoints.setTaskChainStaffingPaused.initiate({ chainId, agentId: row.agent_id, paused, roles: row.roles })).unwrap())} onRemove={() => void run(() => dispatch(taskChainsApi.endpoints.deleteTaskChainFleet.initiate({ chainId, agentId: row.agent_id })).unwrap())} />)}
        <div className="flex flex-wrap items-center gap-2">
          <Select size="sm" value={agentId} disabled={busy} aria-label="Agent to staff" data-debug-id="chain-staffing-agent" onChange={setAgentId}>
            <option value="">Choose an agent…</option>
            {agents.filter((a) => String(a.state || 'active').toLowerCase() === 'active').map((a) => <option key={a.agent_id} value={a.agent_id}>{formatFleetRoleName(a.agent_id, agents)}</option>)}
          </Select>
          <Button size="sm" disabled={busy || !agentId} data-debug-id="chain-staffing-add-worker" onClick={() => void run(async () => {
            const row = rows.data?.find((r) => r.agent_id === agentId);
            const role = focusRole === 'named' ? 'reviewer' : focusRole;
            await update({ chainId, agentId, capacity: row?.capacity || 1, minWarm: row?.min_warm, idleTtlSeconds: row?.idle_ttl_seconds, roles: Array.from(new Set([...(row?.roles || []), role])) }).unwrap();
          })}>Add {focusRole === 'named' ? 'reviewer' : focusRole} holder</Button>
        </div>
      </>}
      {error && <Text role="body-sm" tone="danger" data-debug-id="chain-staffing-error">{error}</Text>}
    </ModalBody>
    <ModalFooter><Button variant="ghost" data-debug-id="chain-staffing-close" onClick={onClose}>Close</Button></ModalFooter>
  </Modal>;
}
function StaffingRow({ row, name, bridges, busy, onSave, onPause, onRemove }: {
  row: TaskChainFleet; name: string; bridges: any[]; busy: boolean;
  onSave: (patch: { capacity?: number; minWarm?: number; idleTtlSeconds?: number; bridgeId?: string }) => void; onPause: (paused: boolean) => void; onRemove: () => void;
}) {
  const [capacity, setCapacity] = useState(String(row.capacity));
  const [warm, setWarm] = useState(String(row.min_warm || 0));
  const [ttl, setTtl] = useState(String(row.idle_ttl_seconds ?? 600));
  const valid = /^\d+$/.test(capacity) && Number(capacity) >= 1 && /^\d+$/.test(warm) && Number(warm) <= Number(capacity) && /^\d+$/.test(ttl);
  return <div className="space-y-2 border-t border-subtle pt-3" data-debug-id={`chain-staffing-row-${row.agent_id}`}>
    <Text role="label">{name} · {(row.roles || []).join(', ')}{row.paused ? ' · paused' : ''}</Text>
    <div className="grid grid-cols-3 gap-2">
      <label className="text-xs">Capacity<Input size="sm" value={capacity} onChange={setCapacity} aria-label={`${name} capacity`} data-debug-id={`chain-staffing-capacity-${row.agent_id}`} /></label>
      <label className="text-xs">Warm instances<Input size="sm" value={warm} onChange={setWarm} aria-label={`${name} warm instances`} data-debug-id={`chain-staffing-warm-${row.agent_id}`} /></label>
      <label className="text-xs">Idle TTL (s)<Input size="sm" value={ttl} onChange={setTtl} aria-label={`${name} idle TTL seconds`} data-debug-id={`chain-staffing-ttl-${row.agent_id}`} /></label>
    </div>
    <Button size="sm" disabled={busy || !valid} data-debug-id={`chain-staffing-save-${row.agent_id}`} onClick={() => onSave({ capacity: Number(capacity), minWarm: Number(warm), idleTtlSeconds: Number(ttl) })}>Save staffing</Button>
    <Button size="sm" variant="ghost" disabled={busy} data-debug-id={`chain-staffing-pause-${row.agent_id}`} onClick={() => onPause(!row.paused)}>{row.paused ? 'Resume grants' : 'Pause grants'}</Button>
    <Button size="sm" variant="ghost" tone="danger" disabled={busy} data-debug-id={`chain-staffing-remove-${row.agent_id}`} onClick={onRemove}>Remove holder</Button>
    <Select size="sm" value={row.bridge_id || ''} disabled={busy} aria-label={`${name} placement bridge`} data-debug-id={`chain-staffing-bridge-${row.agent_id}`} onChange={(bridgeId) => onSave({ bridgeId })}>
      <option value="">Inherit chain placement</option>
      {row.bridge_id && !bridges.some((b) => bridgeIdOf(b) === row.bridge_id) && <option value={row.bridge_id} disabled>Unavailable bridge</option>}
      {bridges.map((b) => <option key={bridgeIdOf(b)} value={bridgeIdOf(b)}>{bridgeLabel(b)}</option>)}
    </Select>
  </div>;
}
