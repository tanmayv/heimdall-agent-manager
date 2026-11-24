import React from 'react';
import { Select, Input, FormField } from '@ui';
import type { EventConfig, TriggerEvent, FilterNode } from '../../api/endpoints/actions';
import { useListFlatTaskChainsQuery } from '../../api/endpoints/taskChains';

export default function EventTriggerEditor({ value, onChange, events, debugId }: { value: EventConfig; onChange: (value: EventConfig) => void; events: TriggerEvent[]; debugId: string }) {
  const chains = useListFlatTaskChainsQuery();
  const event = events.find(e => e.event_type === value.event_type);
  const presets = events.flatMap(e => e.presets.map(p => ({ ...p, event_type: e.event_type })));
  const checks: FilterNode[] = value.filter && 'all' in value.filter ? value.filter.all : value.filter && Object.keys(value.filter).length ? [value.filter as FilterNode] : [];
  const fieldValue = (key: string) => {
    const check = checks.find(n => 'field' in n && n.field === 'data.' + key && n.op === 'eq');
    return check && 'field' in check ? String(check.value) : '';
  };
  const setField = (key: string, text: string) => {
    const kept = checks.filter(n => !('field' in n && n.field === 'data.' + key && n.op === 'eq'));
    if (text) kept.push({ field: 'data.' + key, op: 'eq', value: text });
    onChange({ ...value, filter: kept.length ? { all: kept } : {} });
  };
  return <div className="flex flex-col gap-3">
    <FormField label="Preset"><Select data-debug-id={debugId + '-preset'} value="" aria-label="Event preset" options={[{ value: '', label: 'Choose preset' }, ...presets.map(p => ({ value: p.id, label: p.label }))]} onChange={id => { const p = presets.find(p => p.id === id); if (p) onChange({ ...value, event_type: p.event_type, filter: p.filter }); }} /></FormField>
    <FormField label="Event type"><Select data-debug-id={debugId + '-type'} value={value.event_type} aria-label="Event type" options={events.map(e => ({ value: e.event_type, label: e.label }))} onChange={event_type => onChange({ ...value, event_type, filter: {} })} /></FormField>
    <FormField label="Task chain" hint={chains.error ? "Couldn't load task chains." : undefined}><Select data-debug-id={debugId + '-chain'} aria-label="Task chain" value={value.entity_id || ''} onChange={entity_id => onChange({ ...value, entity_id })} options={[{ value: '', label: 'Any task chain' }, ...(Array.isArray(chains.data) ? chains.data : (chains.data as any)?.chains || []).map((c: any) => ({ value: c.chain_id, label: c.title || c.name || c.chain_id }))]} /></FormField>
    {(event?.fields || []).filter(f => f.field.startsWith('data.')).map(({ field, values }) => ({ key: field.slice(5), values })).map(({ key, values }) => <FormField label={key} key={key}>
      {values.length ? <Select data-debug-id={debugId + '-data-' + key} aria-label={key} value={fieldValue(key)} options={[{ value: '', label: 'Any ' + key }, ...values.map(v => ({ value: v, label: v }))]} onChange={v => setField(key, v)} />
        : <Input data-debug-id={debugId + '-data-' + key} aria-label={key} value={fieldValue(key)} onChange={v => setField(key, v)} />}
    </FormField>)}
  </div>;
}
