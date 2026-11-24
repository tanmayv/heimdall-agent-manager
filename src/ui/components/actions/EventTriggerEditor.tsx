import React from 'react';
import { Select, Input, FormField, Text } from '@ui';
import type { EventConfig, TriggerEvent, FilterLimits } from '../../api/endpoints/actions';
import { useListFlatTaskChainsQuery } from '../../api/endpoints/taskChains';
import ConditionTreeEditor from './ConditionTreeEditor';
import type { FilterIssue } from './filterTree';

export default function EventTriggerEditor({ value, onChange, events, debugId, limits, error }: { value: EventConfig; onChange: (value: EventConfig) => void; events: TriggerEvent[]; debugId: string; limits?: FilterLimits; error?: FilterIssue }) {
  const chains = useListFlatTaskChainsQuery();
  const event = events.find(e => e.event_type === value.event_type);
  const presets = events.flatMap(e => e.presets.map(p => ({ ...p, event_type: e.event_type })));
  function selectEvent(next: EventConfig) {
    if (Object.keys(value.filter || {}).length && !window.confirm('Replace the current conditions?')) return;
    onChange(next);
  }
  return <div className="flex min-w-0 flex-col gap-[var(--space-3)]">
    <FormField label="Preset"><Select data-debug-id={debugId + '-preset'} value="" aria-label="Event preset" options={[{ value: '', label: 'Choose preset' }, ...presets.map(p => ({ value: p.id, label: p.label }))]} onChange={id => { const p = presets.find(p => p.id === id); if (p) selectEvent({ event_type: p.event_type, filter: structuredClone(p.filter) }); }} /></FormField>
    <FormField label="Event type"><Select data-debug-id={debugId + '-type'} value={value.event_type} aria-label="Event type" options={events.map(e => ({ value: e.event_type, label: e.label }))} onChange={event_type => selectEvent({ event_type, filter: {} })} /></FormField>
    {event?.scope === 'chain' || value.event_type.startsWith('chain.') ? <FormField label="Task chain" hint={chains.error ? "Couldn't load task chains. Try again after reloading." : chains.isLoading ? 'Loading task chains…' : 'Leave empty to match any task chain.'}><Select data-debug-id={debugId + '-chain'} aria-label="Task chain" value={value.entity_id || ''} onChange={entity_id => onChange({ ...value, entity_id })} options={[{ value: '', label: 'Any task chain' }, ...(Array.isArray(chains.data) ? chains.data : (chains.data as any)?.chains || []).map((c: any) => ({ value: c.chain_id, label: c.title || c.name || c.chain_id }))]} /></FormField>
      : <FormField label="Entity ID (optional)" hint="Match one entity, or leave empty to match any. To filter a task's chain, add a data.chain_id check below."><Input data-debug-id={debugId + '-entity'} aria-label="Entity ID" value={value.entity_id || ''} onChange={entity_id => onChange({ ...value, entity_id })} /></FormField>}
    {event && limits ? <ConditionTreeEditor key={event.event_type} debugId={debugId + '-conditions'} value={value.filter || {}} onChange={filter => onChange({ ...value, filter })} event={event} limits={limits} error={error} />
      : <Text role="body-sm" tone="muted">{event ? 'Condition limits are unavailable. Reload before editing conditions.' : 'Choose an event type to add conditions.'}</Text>}
  </div>;
}
