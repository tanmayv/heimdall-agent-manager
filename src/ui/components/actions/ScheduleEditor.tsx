import React from 'react';
import { Button, FormField, Input, Select } from '@ui';
import type { ScheduleConfig } from '../../api/endpoints/actions';
import { COMMON_TIMEZONES, validateCronExpression, calculateNextRuns } from './scheduleUtils';

import { instantToScheduleLocal, scheduleLocalToInstant } from './scheduleDateTime';

export type ScheduleEditorValue = ScheduleConfig;
export default function ScheduleEditor({ value, onChange, debugId = 'action-schedule' }: { value: ScheduleConfig; onChange: (value: ScheduleConfig) => void; debugId?: string }) {
  const [blackoutDraft, setBlackoutDraft] = React.useState('');
  const blackoutValid = /^\d{4}-\d{2}-\d{2}$/.test(blackoutDraft)
    && Number(blackoutDraft.slice(0, 4)) >= 2000
    && Number.isFinite(Date.parse(blackoutDraft + 'T00:00:00Z'))
    && new Date(blackoutDraft + 'T00:00:00Z').toISOString().slice(0, 10) === blackoutDraft;
  const addBlackout = () => {
    if (!blackoutValid) return;
    if (!(value.blackout_dates || []).includes(blackoutDraft)) {
      update({ blackout_dates: [...(value.blackout_dates || []), blackoutDraft] });
    }
    setBlackoutDraft('');
  };
  const timezone = value.timezone || 'UTC';
  const update = (patch: Partial<ScheduleConfig>) => onChange({ ...value, ...patch });
  const hasOnceRestrictions = value.mode === 'once' && Boolean(value.active_from || value.active_until || value.blackout_dates?.length);
  let onceWillBeSkipped = false;
  if (hasOnceRestrictions && value.run_at) {
    const runAt = Date.parse(value.run_at);
    onceWillBeSkipped = Boolean(
      (value.active_from && runAt < Date.parse(value.active_from))
      || (value.active_until && runAt > Date.parse(value.active_until))
    );
    try {
      const date = instantToScheduleLocal(value.run_at, timezone).slice(0, 10);
      onceWillBeSkipped ||= Boolean(value.blackout_dates?.includes(date));
    } catch { /* Invalid dates/zones are reported by the date/time picker. */ }
  }
  const clearRestrictions = () => {
    const { active_from, active_until, blackout_dates, ...config } = value;
    onChange(config);
  };
  const cron = value.mode === 'cron' ? validateCronExpression(value.cron_expr || '') : null;
  const previews = React.useMemo(() => value.mode === 'cron' && cron?.valid ? calculateNextRuns(value.cron_expr || '', value.timezone || 'UTC', value.blackout_dates || [], 3, new Date(), value.active_from, value.active_until) : [], [value.mode, value.cron_expr, value.timezone, value.blackout_dates, value.active_from, value.active_until]);
  return <div className="flex flex-col gap-3">
    <FormField label="Schedule mode"><Select aria-label="Schedule mode" data-debug-id={debugId + '-mode'} value={value.mode} options={['cron', 'interval', 'once'].map(v => ({ value: v, label: v }))} onChange={mode => onChange({ timezone: value.timezone || 'UTC', ...(mode === 'once' ? {} : { blackout_dates: value.blackout_dates || [], active_from: value.active_from, active_until: value.active_until }), ...(mode === 'cron' ? { mode: 'cron', cron_expr: '0 9 * * *' } : mode === 'interval' ? { mode: 'interval', interval_s: 3600 } : { mode: 'once', run_at: '' }) })} /></FormField>
    <FormField label="Time zone"><Input list={debugId + '-zones'} data-debug-id={debugId + '-timezone'} aria-label="Time zone" value={timezone} onChange={timezone => update({ timezone })} /></FormField>
    <datalist id={debugId + '-zones'}>{COMMON_TIMEZONES.map(tz => <option key={tz} value={tz} />)}</datalist>
    {value.mode === 'cron' ? <>
      <FormField label="Cron expression" error={cron?.valid ? undefined : cron?.error}><Input data-debug-id={debugId + '-cron'} aria-label="Cron expression" value={value.cron_expr || ''} onChange={cron_expr => update({ cron_expr })} /></FormField>
      {(value.timezone || 'UTC') !== 'UTC' ? <p>In this time zone, a time skipped by daylight saving does not run, and a time that occurs twice runs twice.</p> : null}
      {previews.length ? <p>Preview: {previews.map(d => d.toISOString()).join(', ')}</p> : null}
    </> : value.mode === 'interval' ? <FormField label="Interval (seconds)"><Input type="number" min={60} max={31536000} data-debug-id={debugId + '-interval'} aria-label="Interval seconds" value={String(value.interval_s || '')} onChange={v => update({ interval_s: Number(v) })} /></FormField>
      : <ScheduleDateTime key={'once-' + timezone} label="Once at" debugId={debugId + '-once'} value={value.run_at || ''} timezone={timezone} onChange={run_at => update({ run_at })} pastHint />}
    {hasOnceRestrictions ? <div role="alert" className="text-sm">
      {onceWillBeSkipped ? 'This Once action will be skipped by its active window or blackout dates.' : 'This Once action has an active window or blackout dates that may prevent it from running.'}
      {' '}Clear these restrictions before saving.
      <Button type="button" variant="ghost" size="sm" data-debug-id={debugId + '-once-clear-restrictions'} onClick={clearRestrictions}>Clear</Button>
    </div> : null}
    {value.mode !== 'once' ? <>
      <FormField label="Blackout dates" hint="Choose a date from year 2000 onward, then add it. Dates use the schedule time zone.">
        <div className="flex items-center gap-2">
          <Input type="date" min="2000-01-01" max="9999-12-31" data-debug-id={debugId + '-blackouts'} aria-label="Blackout dates" value={blackoutDraft} onChange={setBlackoutDraft} onKeyDown={event => {
            if (event.key === 'Enter') { event.preventDefault(); addBlackout(); }
          }} />
          <Button type="button" data-debug-id={debugId + '-blackout-add'} aria-label="Add blackout date" disabled={!blackoutValid} onClick={addBlackout}>Add</Button>
        </div>
      </FormField>
      <ul className="flex flex-wrap gap-2" aria-label="Selected blackout dates">{(value.blackout_dates || []).map(date => <li key={date} className="inline-flex items-center gap-1 rounded border border-subtle px-2 py-1 text-sm">
        <span>{date}</span><Button type="button" variant="ghost" size="sm" data-debug-id={debugId + '-blackout-remove-' + date} aria-label={'Remove blackout date ' + date} onClick={() => update({ blackout_dates: (value.blackout_dates || []).filter(d => d !== date) })}>×</Button>
      </li>)}</ul>
      <ScheduleDateTime key={'from-' + timezone} label="Active from" debugId={debugId + '-from'} value={value.active_from || ''} timezone={timezone} onChange={active_from => update({ active_from })} />
      <ScheduleDateTime key={'until-' + timezone} label="Active until" debugId={debugId + '-until'} value={value.active_until || ''} timezone={timezone} onChange={active_until => update({ active_until })} />
    </> : null}
  </div>;
}

function ScheduleDateTime({ label, debugId, value, timezone, onChange, pastHint = false }: {
  label: string; debugId: string; value: string; timezone: string; onChange: (value: string) => void; pastHint?: boolean;
}) {
  const [draft, setDraft] = React.useState<string | null>(null);
  const [editError, setEditError] = React.useState('');
  const input = React.useRef<HTMLInputElement>(null);
  const lastEmitted = React.useRef<string | null>(null);
  let local = '', conversionError = '';
  try { local = instantToScheduleLocal(value, timezone); }
  catch { conversionError = 'Choose a valid time zone and date/time.'; }
  const error = editError || conversionError;
  React.useEffect(() => { input.current?.setCustomValidity(error); }, [error]);
  // Rendering alone never rewrites the RFC3339 string.
  React.useEffect(() => {
    // Keep the exact native input string during our own edits (including omitted
    // seconds), so React does not interrupt keyboard segment entry.
    if (value !== lastEmitted.current) { setDraft(null); setEditError(''); }
    lastEmitted.current = null;
  }, [value]);
  const hint = value && !error
    ? local.replace('T', ' ') + ' ' + timezone + ' · ' + new Date(value).toISOString() + ' UTC' + (pastHint && Date.parse(value) < Date.now() ? ' · This time has passed; the action runs as soon as you save' : '')
    : 'Choose a time in ' + timezone + '. If a time occurs twice, the earlier occurrence is used.';
  return <FormField label={label} error={error || undefined} hint={hint}>
    <Input ref={input} type="datetime-local" step="any" data-debug-id={debugId} aria-label={label} value={draft ?? local} onChange={next => {
      setDraft(next);
      try { const instant = scheduleLocalToInstant(next, timezone); setEditError(''); lastEmitted.current = instant; onChange(instant); }
      catch (e) { setEditError((e as Error).message); }
    }} />
  </FormField>;
}
