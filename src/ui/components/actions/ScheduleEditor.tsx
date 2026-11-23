import React from 'react';
import { FormField, Input, Select } from '@ui';
import type { ScheduleConfig } from '../../api/endpoints/actions';
import { COMMON_TIMEZONES, validateCronExpression, calculateNextRuns } from './scheduleUtils';

export type ScheduleEditorValue = ScheduleConfig;
export default function ScheduleEditor({ value, onChange, debugId = 'action-schedule' }: { value: ScheduleConfig; onChange: (value: ScheduleConfig) => void; debugId?: string }) {
  const [blackoutText, setBlackoutText] = React.useState((value.blackout_dates || []).join(', '));
  const update = (patch: Partial<ScheduleConfig>) => onChange({ ...value, ...patch });
  const cron = value.mode === 'cron' ? validateCronExpression(value.cron_expr || '') : null;
  const previews = React.useMemo(() => value.mode === 'cron' && cron?.valid ? calculateNextRuns(value.cron_expr || '', value.timezone || 'UTC', value.blackout_dates || [], 3, new Date(), value.active_from, value.active_until) : [], [value.mode, value.cron_expr, value.timezone, value.blackout_dates, value.active_from, value.active_until]);
  return <div className="flex flex-col gap-3">
    <FormField label="Schedule mode"><Select aria-label="Schedule mode" data-debug-id={debugId + '-mode'} value={value.mode} options={['cron', 'interval', 'once'].map(v => ({ value: v, label: v }))} onChange={mode => onChange({ timezone: value.timezone || 'UTC', blackout_dates: value.blackout_dates || [], active_from: value.active_from, active_until: value.active_until, ...(mode === 'cron' ? { mode: 'cron', cron_expr: '0 9 * * *' } : mode === 'interval' ? { mode: 'interval', interval_s: 3600 } : { mode: 'once', run_at: new Date().toISOString() }) })} /></FormField>
    {value.mode === 'cron' ? <>
      <FormField label="Cron expression" error={cron?.valid ? undefined : cron?.error}><Input data-debug-id={debugId + '-cron'} aria-label="Cron expression" value={value.cron_expr || ''} onChange={cron_expr => update({ cron_expr })} /></FormField>
      <FormField label="Time zone"><div><input list={debugId + '-zones'} data-debug-id={debugId + '-timezone'} aria-label="Time zone" value={value.timezone || 'UTC'} onChange={e => update({ timezone: e.target.value })} /><datalist id={debugId + '-zones'}>{COMMON_TIMEZONES.map(tz => <option key={tz} value={tz} />)}</datalist></div></FormField>
      {(value.timezone || 'UTC') !== 'UTC' ? <p>In this time zone, a time skipped by daylight saving does not run, and a time that occurs twice runs twice.</p> : null}
      {previews.length ? <p>Preview: {previews.map(d => d.toISOString()).join(', ')}</p> : null}
    </> : value.mode === 'interval' ? <FormField label="Interval (seconds)"><Input type="number" min={60} max={31536000} data-debug-id={debugId + '-interval'} aria-label="Interval seconds" value={String(value.interval_s || '')} onChange={v => update({ interval_s: Number(v) })} /></FormField>
      : <FormField label="Once at (RFC3339 with time zone)"><Input data-debug-id={debugId + '-once'} aria-label="Once at" value={value.run_at || ''} onChange={run_at => update({ run_at })} /></FormField>}
    <FormField label="Blackout dates" hint="YYYY-MM-DD, separated by commas"><Input data-debug-id={debugId + '-blackouts'} aria-label="Blackout dates" value={blackoutText} onChange={v => { setBlackoutText(v); update({ blackout_dates: v.split(',').map(s => s.trim()).filter(Boolean) }); }} /></FormField>
    <FormField label="Active from (RFC3339)"><Input data-debug-id={debugId + '-from'} aria-label="Active from" value={value.active_from || ''} onChange={active_from => update({ active_from })} /></FormField>
    <FormField label="Active until (RFC3339)"><Input data-debug-id={debugId + '-until'} aria-label="Active until" value={value.active_until || ''} onChange={active_until => update({ active_until })} /></FormField>
  </div>;
}
