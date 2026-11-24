import React from 'react';
import { Select, Input, FormField } from '@ui';
import type { EventConfig, TriggerEvent } from '../../api/endpoints/actions';
import { useListFlatTaskChainsQuery } from '../../api/endpoints/taskChains';

export default function EventTriggerEditor({ value, onChange, events, debugId }: { value: EventConfig; onChange: (value: EventConfig) => void; events: TriggerEvent[]; debugId: string }) {
  const chains = useListFlatTaskChainsQuery();
  const event = events.find(e => e.event_type === value.event_type);
  const presets = events.flatMap(e => e.presets.map(p => ({ ...p, event_type: e.event_type })));
  return <div className="flex flex-col gap-3">
    <FormField label="Preset"><Select data-debug-id={debugId + '-preset'} value="" aria-label="Event preset" options={[{ value: '', label: 'Choose preset' }, ...presets.map(p => ({ value: p.id, label: p.label }))]} onChange={id => { const p = presets.find(p => p.id === id); if (p) onChange({ ...value, event_type: p.event_type, data: { ...p.data } }); }} /></FormField>
    <FormField label="Event type"><Select data-debug-id={debugId + '-type'} value={value.event_type} aria-label="Event type" options={events.map(e => ({ value: e.event_type, label: e.label }))} onChange={event_type => onChange({ ...value, event_type, data: {} })} /></FormField>
    <FormField label="Task chain" hint={chains.error ? "Couldn't load task chains." : undefined}><Select data-debug-id={debugId + '-chain'} aria-label="Task chain" value={value.chain_id || ''} onChange={chain_id => onChange({ ...value, chain_id })} options={[{ value: '', label: 'Any task chain' }, ...(Array.isArray(chains.data) ? chains.data : (chains.data as any)?.chains || []).map((c: any) => ({ value: c.chain_id, label: c.title || c.name || c.chain_id }))]} /></FormField>
    {(event?.data_keys || []).map(({ key, values }) => <FormField label={key} key={key}>
      {values.length ? <Select data-debug-id={debugId + '-data-' + key} aria-label={key} value={value.data?.[key] || ''} options={[{ value: '', label: 'Any ' + key }, ...values.map(v => ({ value: v, label: v }))]} onChange={v => { const data = { ...value.data }; if (v) data[key] = v; else delete data[key]; onChange({ ...value, data }); }} />
        : <Input data-debug-id={debugId + '-data-' + key} aria-label={key} value={value.data?.[key] || ''} onChange={v => { const data = { ...value.data }; if (v) data[key] = v; else delete data[key]; onChange({ ...value, data }); }} />}
    </FormField>)}
  </div>;
}
