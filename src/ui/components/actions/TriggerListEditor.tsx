import React from 'react';
import { Button, Toggle, Input, FormField } from '@ui';
import type { TriggerTypes } from '../../api/endpoints/actions';
import type { FormTrigger } from './actionModel';
import ScheduleEditor from './ScheduleEditor';
import EventTriggerEditor from './EventTriggerEditor';
import type { FilterIssue } from './filterTree';

export default function TriggerListEditor({ value, onChange, types, filterErrors }: { value: FormTrigger[]; onChange: (value: FormTrigger[]) => void; types: TriggerTypes; filterErrors?: Record<number, FilterIssue> }) {
  const events = types.trigger_kinds.find(k => k.kind === 'event')?.events || [];
  const full = value.length >= types.limits.max_triggers;
  return <div className="action-trigger-editor flex min-w-0 flex-col gap-4">
    {value.map((trigger, i) => {
      const id = trigger.id || trigger.clientKey;
      const change = (next: FormTrigger) => onChange(value.map((t, n) => n === i ? next : t));
      return <fieldset key={id} className="condition-editor-fieldset rounded-[var(--radius-lg)] border border-subtle p-[var(--space-2)] sm:p-[var(--space-3)] flex min-w-0 flex-col gap-3">
        <legend>{trigger.kind === 'schedule' ? 'Schedule' : 'Event'} {i + 1}</legend>
        <Toggle aria-label={'Enable trigger ' + (i + 1)} data-debug-id={'action-trigger-enabled-' + id} checked={trigger.enabled} onChange={enabled => change({ ...trigger, enabled })} />
        {trigger.kind === 'schedule' ? <ScheduleEditor debugId={'action-trigger-' + id} value={trigger.config} onChange={config => change({ ...trigger, config })} />
          : <EventTriggerEditor debugId={'action-trigger-' + id} value={trigger.config} onChange={config => change({ ...trigger, config, delay_s: events.find(e => e.event_type === config.event_type)?.no_delay || config.event_type === 'webhook.received' ? 0 : trigger.delay_s })} events={events} limits={types.limits.filter} error={filterErrors?.[i]} />}
        {trigger.kind === 'event' && trigger.config.event_type !== 'webhook.received' && !events.find(e => e.event_type === trigger.config.event_type)?.no_delay ? <FormField label="Delay (seconds)" hint="Wait for the event to settle before delivery. A matching event restarts the timer. Zero delivers immediately."><Input type="number" min={0} max={86400} step={1} data-debug-id={'action-trigger-delay-' + id} aria-label="Delay (seconds)" value={String(trigger.delay_s || 0)} onChange={v => change({ ...trigger, delay_s: Number(v) })} /></FormField> : null}
        <Button type="button" variant="danger" data-debug-id={'action-trigger-remove-' + id} onClick={() => { if (window.confirm('Remove this trigger and all its conditions?')) { onChange(value.filter((_, n) => n !== i)); requestAnimationFrame(() => document.querySelector<HTMLElement>('[data-debug-id="action-trigger-add-event"]')?.focus()); } }}>Remove trigger</Button>
      </fieldset>;
    })}
    <div className="condition-editor-toolbar">
      <Button type="button" variant="secondary" data-debug-id="action-trigger-add-schedule" disabled={full || !types.schedules_supported} onClick={() => onChange([...value, { clientKey: crypto.randomUUID(), kind: 'schedule', enabled: true, config: { mode: 'interval', interval_s: 3600, timezone: 'UTC', blackout_dates: [] } }])}>Add Schedule</Button>
      <Button type="button" variant="secondary" data-debug-id="action-trigger-add-event" disabled={full || !events.length} onClick={() => onChange([...value, { clientKey: crypto.randomUUID(), kind: 'event', enabled: true, config: { event_type: events[0].event_type, filter: {} } }])}>Add Event</Button>
    </div>
    {!types.schedules_supported ? <p>Scheduled triggers need nats-server 2.14 or newer.</p> : null}
  </div>;
}
