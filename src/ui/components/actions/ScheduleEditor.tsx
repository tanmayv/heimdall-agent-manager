import { useState, useMemo, useEffect } from 'react';

import {
  COMMON_TIMEZONES,
  getLocalTimezone,
  validateCronExpression,
  describeCron,
  calculateNextRuns,
  detectPreset,
  buildEveryNHours,
  buildDaily,
  buildWeekly,
  formatInTimeZone,
  timeZoneLabel,
  type PresetType,
} from './scheduleUtils';
import { Button, Checkbox, Icon, Input, Select } from '@ui';
export type ScheduleEditorValue = {
  cron_expr: string;
  timezone: string;
  blackout_dates: string[];
  active_from?: string;
  active_until?: string;
};

export type ScheduleEditorProps = {
  value: ScheduleEditorValue;
  onChange: (value: ScheduleEditorValue) => void;
};

const DOW_OPTIONS = [
  { label: 'Mon', value: 1 },
  { label: 'Tue', value: 2 },
  { label: 'Wed', value: 3 },
  { label: 'Thu', value: 4 },
  { label: 'Fri', value: 5 },
  { label: 'Sat', value: 6 },
  { label: 'Sun', value: 0 },
];

export default function ScheduleEditor({ value, onChange }: ScheduleEditorProps) {
  const initialPreset = useMemo(() => detectPreset(value.cron_expr || '0 9 * * *'), []);
  const [mode, setMode] = useState<'presets' | 'advanced'>(
    initialPreset.type === 'custom' ? 'advanced' : 'presets'
  );
  const [presetType, setPresetType] = useState<PresetType>(
    initialPreset.type === 'custom' ? 'daily' : initialPreset.type
  );
  const [presetHours, setPresetHours] = useState<number>(initialPreset.hours || 2);
  const [presetTime, setPresetTime] = useState<string>(initialPreset.time || '09:00');
  const [presetDays, setPresetDays] = useState<number[]>(
    initialPreset.days && initialPreset.days.length > 0 ? initialPreset.days : [1, 2, 3, 4, 5]
  );

  const [newBlackoutDate, setNewBlackoutDate] = useState('');
  const [blackoutError, setBlackoutError] = useState('');
  const [enableWindow, setEnableWindow] = useState(Boolean(value.active_from || value.active_until));

  // Sync cron expression when preset settings change in presets mode
  const handlePresetTypeChange = (nextType: PresetType) => {
    setPresetType(nextType);
    let nextCron = value.cron_expr;
    if (nextType === 'every_n_hours') {
      nextCron = buildEveryNHours(presetHours);
    } else if (nextType === 'daily') {
      nextCron = buildDaily(presetTime);
    } else if (nextType === 'weekly') {
      nextCron = buildWeekly(presetTime, presetDays);
    }
    onChange({ ...value, cron_expr: nextCron });
  };

  const handleHoursChange = (hours: number) => {
    setPresetHours(hours);
    onChange({ ...value, cron_expr: buildEveryNHours(hours) });
  };

  const handleTimeChange = (time: string) => {
    setPresetTime(time);
    if (presetType === 'daily') {
      onChange({ ...value, cron_expr: buildDaily(time) });
    } else if (presetType === 'weekly') {
      onChange({ ...value, cron_expr: buildWeekly(time, presetDays) });
    }
  };

  const handleDayToggle = (day: number) => {
    const nextDays = presetDays.includes(day)
      ? presetDays.filter((d) => d !== day)
      : [...presetDays, day];
    const finalDays = nextDays.length === 0 ? [day] : nextDays;
    setPresetDays(finalDays);
    onChange({ ...value, cron_expr: buildWeekly(presetTime, finalDays) });
  };

  const handleQuickDays = (type: 'weekdays' | 'weekends' | 'all') => {
    let days: number[] = [];
    if (type === 'weekdays') days = [1, 2, 3, 4, 5];
    else if (type === 'weekends') days = [6, 0];
    else days = [1, 2, 3, 4, 5, 6, 0];
    setPresetDays(days);
    onChange({ ...value, cron_expr: buildWeekly(presetTime, days) });
  };

  const handleAddBlackoutDate = (e: React.FormEvent) => {
    e.preventDefault();
    setBlackoutError('');
    const trimmed = newBlackoutDate.trim();
    if (!trimmed) return;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) {
      setBlackoutError('Date must be in YYYY-MM-DD format');
      return;
    }
    if (value.blackout_dates.includes(trimmed)) {
      setBlackoutError('Date already added');
      return;
    }
    const next = [...value.blackout_dates, trimmed].sort();
    onChange({ ...value, blackout_dates: next });
    setNewBlackoutDate('');
  };

  const handleRemoveBlackoutDate = (dateToRemove: string) => {
    const next = value.blackout_dates.filter((d) => d !== dateToRemove);
    onChange({ ...value, blackout_dates: next });
  };

  const validation = useMemo(() => validateCronExpression(value.cron_expr || ''), [value.cron_expr]);
  const description = useMemo(() => describeCron(value.cron_expr || ''), [value.cron_expr]);

  const nextRuns = useMemo(() => {
    if (!validation.valid) return [];
    return calculateNextRuns(
      value.cron_expr,
      value.timezone,
      value.blackout_dates,
      3,
      new Date(),
      value.active_from,
      value.active_until
    );
  }, [value.cron_expr, value.timezone, value.blackout_dates, value.active_from, value.active_until, validation.valid]);

  return (
    <div data-debug-id="schedule-editor" className="space-y-4 rounded-xl border border-subtle bg-surface p-4">
      {/* Mode Switcher */}
      <div className="flex items-center justify-between border-b border-subtle pb-3">
        <label className="text-xs font-semibold uppercase tracking-wider text-faint">
          Schedule Configuration
        </label>
        <div className="inline-flex rounded-lg border border-subtle bg-surface-raised p-0.5 text-xs font-medium">
          <button
            type="button"
            data-debug-id="schedule-mode-presets-btn"
            onClick={() => {
              setMode('presets');
              if (presetType === 'every_n_hours') onChange({ ...value, cron_expr: buildEveryNHours(presetHours) });
              else if (presetType === 'daily') onChange({ ...value, cron_expr: buildDaily(presetTime) });
              else if (presetType === 'weekly') onChange({ ...value, cron_expr: buildWeekly(presetTime, presetDays) });
            }}
            className={`px-3 py-1 rounded-md transition-colors ${
              mode === 'presets' ? 'bg-accent text-accent-fg font-semibold shadow-sm' : 'text-muted hover:text-primary'
            }`}
          >
            Presets
          </button>
          <button
            type="button"
            data-debug-id="schedule-mode-advanced-btn"
            onClick={() => setMode('advanced')}
            className={`px-3 py-1 rounded-md transition-colors ${
              mode === 'advanced' ? 'bg-accent text-accent-fg font-semibold shadow-sm' : 'text-muted hover:text-primary'
            }`}
          >
            Advanced (Cron)
          </button>
        </div>
      </div>

      {/* Preset Controls */}
      {mode === 'presets' && (
        <div className="space-y-3 animate-fade-in">
          <div className="grid grid-cols-3 gap-2">
            {[
              { id: 'every_n_hours' as PresetType, label: 'Every N Hours' },
              { id: 'daily' as PresetType, label: 'Daily' },
              { id: 'weekly' as PresetType, label: 'Weekly' },
            ].map((p) => (
              <button
                key={p.id}
                type="button"
                data-debug-id={`schedule-preset-tab-${p.id}`}
                onClick={() => handlePresetTypeChange(p.id)}
                className={`flex items-center justify-center gap-1.5 py-2 px-3 rounded-lg border text-xs font-medium transition-colors ${
                  presetType === p.id
                    ? 'border-accent bg-accent/10 text-accent'
                    : 'border-subtle bg-surface text-muted hover:bg-neutral-soft hover:text-primary'
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>

          {presetType === 'every_n_hours' && (
            <div className="rounded-lg border border-subtle bg-surface-raised p-3 flex items-center gap-3">
              <span className="text-xs text-primary">Run every:</span>
              <Select
                data-debug-id="schedule-preset-hours-select"
                size="sm"
                value={String(presetHours)}
                onChange={(next) => handleHoursChange(parseInt(next, 10))}
              >
                <option value={1}>1 hour (every hour)</option>
                <option value={2}>2 hours</option>
                <option value={4}>4 hours</option>
                <option value={6}>6 hours</option>
                <option value={8}>8 hours</option>
                <option value={12}>12 hours</option>
                <option value={24}>24 hours</option>
              </Select>
              <span className="text-xs text-muted">at minute 0</span>
            </div>
          )}

          {presetType === 'daily' && (
            <div className="rounded-lg border border-subtle bg-surface-raised p-3 flex items-center gap-3">
              <span className="text-xs text-primary">At time:</span>
              <input
                type="time"
                data-debug-id="schedule-preset-time-input"
                value={presetTime}
                onChange={(e) => handleTimeChange(e.target.value)}
                className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs text-primary outline-none focus:border-accent"
              />
              <span className="text-xs text-muted">every single day</span>
            </div>
          )}

          {presetType === 'weekly' && (
            <div className="rounded-lg border border-subtle bg-surface-raised p-3 space-y-3">
              <div className="flex items-center gap-3">
                <span className="text-xs text-primary">At time:</span>
                <input
                  type="time"
                  data-debug-id="schedule-preset-time-input"
                  value={presetTime}
                  onChange={(e) => handleTimeChange(e.target.value)}
                  className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs text-primary outline-none focus:border-accent"
                />
              </div>

              <div>
                <div className="flex items-center justify-between mb-1.5">
                  <span className="text-xs text-muted font-medium">On days:</span>
                  <div className="flex gap-2 text-caption text-accent">
                    <button type="button" onClick={() => handleQuickDays('weekdays')} className="hover:underline">
                      Weekdays
                    </button>
                    <span className="text-faint">•</span>
                    <button type="button" onClick={() => handleQuickDays('weekends')} className="hover:underline">
                      Weekends
                    </button>
                    <span className="text-faint">•</span>
                    <button type="button" onClick={() => handleQuickDays('all')} className="hover:underline">
                      All
                    </button>
                  </div>
                </div>

                <div className="flex flex-wrap gap-1.5">
                  {DOW_OPTIONS.map((d) => {
                    const checked = presetDays.includes(d.value);
                    return (
                      <button
                        key={d.value}
                        type="button"
                        data-debug-id={`schedule-preset-dow-checkbox-${d.value}`}
                        onClick={() => handleDayToggle(d.value)}
                        className={`px-2.5 py-1 rounded-md text-xs font-semibold border transition-colors ${
                          checked
                            ? 'bg-accent/20 border-accent text-accent'
                            : 'bg-surface border-subtle text-muted hover:text-primary'
                        }`}
                      >
                        {d.label}
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Advanced Raw Cron */}
      {mode === 'advanced' && (
        <div className="space-y-2 animate-fade-in">
          <label className="block text-xs font-medium text-muted">
            Raw 5-Field Cron Expression <span className="text-faint">(minute hour dom month dow)</span>
          </label>
          <Input
            data-debug-id="schedule-cron-input"
            value={value.cron_expr}
            onChange={(cron_expr) => onChange({ ...value, cron_expr })}
            placeholder="0 9 * * 1-5"
            invalid={!validation.valid}
            width="full"
            className="font-mono"
          />
          {!validation.valid && (
            <p data-debug-id="schedule-cron-error" className="text-xs text-danger">
              {validation.error}
            </p>
          )}
        </div>
      )}

      {/* Human-Readable Description & Preview */}
      <div
        data-debug-id="schedule-cron-preview"
        className={`flex items-start gap-2 rounded-lg border p-2.5 text-xs ${
          validation.valid
            ? 'border-success/30 bg-success-soft text-success'
            : 'border-subtle bg-surface text-muted'
        }`}
      >
        <Icon name="clock" size={13} className="mt-0.5 shrink-0" />
        <div>
          <span className="font-semibold">{description}</span>
          <span className="ml-2 font-mono text-faint text-caption">({value.cron_expr || '* * * * *'})</span>
        </div>
      </div>

      {/* Timezone Selector */}
      <div className="space-y-1.5">
        <div className="flex items-center justify-between">
          <label className="text-xs font-medium text-muted">Timezone</label>
          <button
            type="button"
            data-debug-id="schedule-tz-local-btn"
            onClick={() => onChange({ ...value, timezone: getLocalTimezone() })}
            className="text-caption text-accent hover:underline"
          >
            Use Local ({getLocalTimezone()})
          </button>
        </div>
        <Select
          data-debug-id="schedule-timezone-select"
          size="sm"
          width="full"
          value={value.timezone || 'UTC'}
          onChange={(timezone) => onChange({ ...value, timezone })}
        >
          {COMMON_TIMEZONES.map((tz) => (
            <option key={tz} value={tz}>
              {tz}
            </option>
          ))}
          {!COMMON_TIMEZONES.includes(value.timezone || '') && value.timezone && (
            <option value={value.timezone}>{value.timezone}</option>
          )}
        </Select>
      </div>

      {/* Next 3 Runs Preview */}
      {validation.valid && (
        <div className="space-y-1.5 rounded-lg border border-subtle bg-surface-raised p-3">
          <label className="block text-xs font-medium text-muted">
            Next 3 Scheduled Executions:
          </label>
          {nextRuns.length > 0 ? (
            <ul data-debug-id="schedule-next-runs-list" className="space-y-1">
              {nextRuns.map((runDate, i) => (
                <li key={i} className="flex items-center gap-2 text-xs text-primary font-mono">
                  <span className="text-muted">#{i + 1}</span>
                  <span>{formatInTimeZone(runDate, value.timezone)}</span>
                  <span className="text-muted text-caption">({timeZoneLabel(runDate, value.timezone)})</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-xs text-muted italic">No upcoming runs found within active window</p>
          )}
        </div>
      )}

      {/* Blackout Dates Picker */}
      <div className="space-y-2 border-t border-subtle pt-3">
        <div className="flex items-center justify-between">
          <div>
            <label className="text-xs font-semibold text-primary">Blackout Dates</label>
            <p className="text-caption text-muted">Dates on which execution is suppressed</p>
          </div>
        </div>

        {/* Existing Blackout Date Chips */}
        {value.blackout_dates && value.blackout_dates.length > 0 ? (
          <div data-debug-id="schedule-blackout-chips" className="flex flex-wrap gap-1.5">
            {value.blackout_dates.map((date) => (
              <span
                key={date}
                className="inline-flex items-center gap-1.5 rounded-md border border-subtle bg-surface px-2 py-1 text-xs text-primary"
              >
                <span>{date}</span>
                <button
                  type="button"
                  data-debug-id={`schedule-remove-blackout-btn-${date}`}
                  onClick={() => handleRemoveBlackoutDate(date)}
                  className="text-muted hover:text-danger transition-colors"
                  title="Remove blackout date"
                  aria-label={`Remove blackout date ${date}`}
                >
                  <Icon name="close" size={12} />
                </button>
              </span>
            ))}
          </div>
        ) : (
          <p className="text-xs text-faint italic">No blackout dates configured</p>
        )}

        {/* Add Blackout Date Form */}
        <div className="flex items-center gap-2">
          <input
            type="date"
            data-debug-id="schedule-blackout-input"
            value={newBlackoutDate}
            onChange={(e) => setNewBlackoutDate(e.target.value)}
            className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs text-primary outline-none focus:border-accent"
          />
          <Button
            variant="secondary"
            size="sm"
            data-debug-id="schedule-add-blackout-btn"
            onClick={handleAddBlackoutDate}
          >
            Add Date
          </Button>
        </div>
        {blackoutError && <p className="text-xs text-danger">{blackoutError}</p>}
      </div>

      {/* Active Window (Optional) */}
      <div className="space-y-2 border-t border-subtle pt-3">
        <Checkbox
          checked={enableWindow}
          onChange={(checked) => {
            setEnableWindow(checked);
            if (!checked) {
              onChange({ ...value, active_from: undefined, active_until: undefined });
            }
          }}
        >
          <span className="text-xs font-semibold text-primary">Set Active Date/Time Window</span>
        </Checkbox>

        {enableWindow && (
          <div className="grid gap-3 sm:grid-cols-2 rounded-lg border border-subtle bg-surface-raised p-3">
            <div>
              <label className="block text-xs text-muted mb-1">Active From</label>
              <input
                type="datetime-local"
                data-debug-id="schedule-active-from-input"
                value={value.active_from ? value.active_from.slice(0, 16) : ''}
                onChange={(e) => onChange({ ...value, active_from: e.target.value ? new Date(e.target.value).toISOString() : undefined })}
                className="w-full rounded-lg border border-subtle bg-surface px-2.5 py-1.5 text-xs text-primary outline-none focus:border-accent"
              />
            </div>
            <div>
              <label className="block text-xs text-muted mb-1">Active Until</label>
              <input
                type="datetime-local"
                data-debug-id="schedule-active-until-input"
                value={value.active_until ? value.active_until.slice(0, 16) : ''}
                onChange={(e) => onChange({ ...value, active_until: e.target.value ? new Date(e.target.value).toISOString() : undefined })}
                className="w-full rounded-lg border border-subtle bg-surface px-2.5 py-1.5 text-xs text-primary outline-none focus:border-accent"
              />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
