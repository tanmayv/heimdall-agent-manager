import React from 'react';
import { Button, Toggle } from '@ui';
import type { ActionTrigger, TriggerTypes } from '../../api/endpoints/actions';
import ScheduleEditor from './ScheduleEditor';
import EventTriggerEditor from './EventTriggerEditor';

export default function TriggerListEditor({ value, onChange, types }: { value: ActionTrigger[]; onChange: (value: ActionTrigger[]) => void; types: TriggerTypes }) {
  const events = types.trigger_kinds.find(k => k.kind === 'event')?.events || [];
  const full = value.length >= types.limits.max_triggers;
  return <div className="flex flex-col gap-4">
    {value.map((trigger, i) => {
      const id = trigger.id || String(i);
      const change = (next: ActionTrigger) => onChange(value.map((t, n) => n === i ? next : t));
      return <fieldset key={id} className="rounded border border-subtle p-3 flex flex-col gap-3">
        <legend>{trigger.kind === 'schedule' ? 'Schedule' : 'Event'} {i + 1}</legend>
        <Toggle aria-label={'Enable trigger ' + (i + 1)} data-debug-id={'action-trigger-enabled-' + id} checked={trigger.enabled} onChange={enabled => change({ ...trigger, enabled })} />
        {trigger.kind === 'schedule' ? <ScheduleEditor debugId={'action-trigger-' + id} value={trigger.config} onChange={config => change({ ...trigger, config })} />
          : <EventTriggerEditor debugId={'action-trigger-' + id} value={trigger.config} onChange={config => change({ ...trigger, config })} events={events} />}
        <Button type="button" variant="danger" data-debug-id={'action-trigger-remove-' + id} onClick={() => onChange(value.filter((_, n) => n !== i))}>Remove trigger</Button>
      </fieldset>;
    })}
    <div className="flex gap-2">
      <Button type="button" variant="secondary" data-debug-id="action-trigger-add-schedule" disabled={full || !types.schedules_supported} onClick={() => onChange([...value, { kind: 'schedule', enabled: true, config: { mode: 'cron', cron_expr: '0 9 * * *', timezone: 'UTC', blackout_dates: [] } }])}>Add Schedule</Button>
      <Button type="button" variant="secondary" data-debug-id="action-trigger-add-event" disabled={full || !events.length} onClick={() => onChange([...value, { kind: 'event', enabled: true, config: { event_type: events[0].event_type, data: {} } }])}>Add Event</Button>
    </div>
    {!types.schedules_supported ? <p>Scheduled triggers need nats-server 2.14 or newer.</p> : null}
  </div>;
}
