import { useState, useMemo, useEffect } from 'react';
import Icon from '../Icon';
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
  type PresetType,
} from './scheduleUtils';

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
    <div data-debug-id="schedule-editor" className="space-y-4 rounded-xl border border-white/10 bg-white/[0.02] p-4">
      {/* Mode Switcher */}
      <div className="flex items-center justify-between border-b border-white/10 pb-3">
        <label className="text-xs font-semibold uppercase tracking-wider text-zinc-400">
          Schedule Configuration
        </label>
        <div className="inline-flex rounded-lg border border-white/10 bg-black/40 p-0.5 text-xs font-medium">
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
              mode === 'presets' ? 'bg-sky-500 text-black font-semibold shadow-sm' : 'text-zinc-400 hover:text-white'
            }`}
          >
            Presets
          </button>
          <button
            type="button"
            data-debug-id="schedule-mode-advanced-btn"
            onClick={() => setMode('advanced')}
            className={`px-3 py-1 rounded-md transition-colors ${
              mode === 'advanced' ? 'bg-sky-500 text-black font-semibold shadow-sm' : 'text-zinc-400 hover:text-white'
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
                    ? 'border-sky-500/50 bg-sky-500/10 text-sky-400'
                    : 'border-white/10 bg-black/30 text-zinc-400 hover:bg-white/5 hover:text-white'
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>

          {presetType === 'every_n_hours' && (
            <div className="rounded-lg border border-white/10 bg-black/20 p-3 flex items-center gap-3">
              <span className="text-xs text-zinc-300">Run every:</span>
              <select
                data-debug-id="schedule-preset-hours-select"
                value={presetHours}
                onChange={(e) => handleHoursChange(parseInt(e.target.value, 10))}
                className="rounded-lg border border-white/10 bg-zinc-900 px-3 py-1.5 text-xs text-zinc-200 outline-none focus:border-sky-400"
              >
                <option value={1}>1 hour (every hour)</option>
                <option value={2}>2 hours</option>
                <option value={4}>4 hours</option>
                <option value={6}>6 hours</option>
                <option value={8}>8 hours</option>
                <option value={12}>12 hours</option>
                <option value={24}>24 hours</option>
              </select>
              <span className="text-xs text-zinc-500">at minute 0</span>
            </div>
          )}

          {presetType === 'daily' && (
            <div className="rounded-lg border border-white/10 bg-black/20 p-3 flex items-center gap-3">
              <span className="text-xs text-zinc-300">At time:</span>
              <input
                type="time"
                data-debug-id="schedule-preset-time-input"
                value={presetTime}
                onChange={(e) => handleTimeChange(e.target.value)}
                className="rounded-lg border border-white/10 bg-zinc-900 px-3 py-1.5 text-xs text-zinc-200 outline-none focus:border-sky-400"
              />
              <span className="text-xs text-zinc-500">every single day</span>
            </div>
          )}

          {presetType === 'weekly' && (
            <div className="rounded-lg border border-white/10 bg-black/20 p-3 space-y-3">
              <div className="flex items-center gap-3">
                <span className="text-xs text-zinc-300">At time:</span>
                <input
                  type="time"
                  data-debug-id="schedule-preset-time-input"
                  value={presetTime}
                  onChange={(e) => handleTimeChange(e.target.value)}
                  className="rounded-lg border border-white/10 bg-zinc-900 px-3 py-1.5 text-xs text-zinc-200 outline-none focus:border-sky-400"
                />
              </div>

              <div>
                <div className="flex items-center justify-between mb-1.5">
                  <span className="text-xs text-zinc-400 font-medium">On days:</span>
                  <div className="flex gap-2 text-[11px] text-sky-400">
                    <button type="button" onClick={() => handleQuickDays('weekdays')} className="hover:underline">
                      Weekdays
                    </button>
                    <span className="text-zinc-600">•</span>
                    <button type="button" onClick={() => handleQuickDays('weekends')} className="hover:underline">
                      Weekends
                    </button>
                    <span className="text-zinc-600">•</span>
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
                            ? 'bg-sky-500/20 border-sky-500/50 text-sky-300'
                            : 'bg-zinc-900 border-white/10 text-zinc-400 hover:text-white'
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
          <label className="block text-xs font-medium text-zinc-400">
            Raw 5-Field Cron Expression <span className="text-zinc-600">(minute hour dom month dow)</span>
          </label>
          <input
            type="text"
            data-debug-id="schedule-cron-input"
            value={value.cron_expr}
            onChange={(e) => onChange({ ...value, cron_expr: e.target.value })}
            placeholder="0 9 * * 1-5"
            className={`w-full font-mono text-sm rounded-lg border bg-black/40 px-3 py-2 outline-none transition-colors ${
              validation.valid ? 'border-white/10 text-zinc-100 focus:border-sky-400' : 'border-red-500/60 text-red-200 focus:border-red-500'
            }`}
          />
          {!validation.valid && (
            <p data-debug-id="schedule-cron-error" className="text-xs text-red-400">
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
            ? 'border-emerald-500/30 bg-emerald-950/15 text-emerald-300'
            : 'border-zinc-800 bg-black/20 text-zinc-400'
        }`}
      >
        <Icon name="clock" size={13} className="mt-0.5 shrink-0" />
        <div>
          <span className="font-semibold">{description}</span>
          <span className="ml-2 font-mono text-zinc-500 text-[11px]">({value.cron_expr || '* * * * *'})</span>
        </div>
      </div>

      {/* Timezone Selector */}
      <div className="space-y-1.5">
        <div className="flex items-center justify-between">
          <label className="text-xs font-medium text-zinc-400">Timezone</label>
          <button
            type="button"
            data-debug-id="schedule-tz-local-btn"
            onClick={() => onChange({ ...value, timezone: getLocalTimezone() })}
            className="text-[11px] text-sky-400 hover:underline"
          >
            Use Local ({getLocalTimezone()})
          </button>
        </div>
        <select
          data-debug-id="schedule-timezone-select"
          value={value.timezone || 'UTC'}
          onChange={(e) => onChange({ ...value, timezone: e.target.value })}
          className="w-full rounded-lg border border-white/10 bg-zinc-900 px-3 py-2 text-xs text-zinc-200 outline-none focus:border-sky-400"
        >
          {COMMON_TIMEZONES.map((tz) => (
            <option key={tz} value={tz}>
              {tz}
            </option>
          ))}
          {!COMMON_TIMEZONES.includes(value.timezone || '') && value.timezone && (
            <option value={value.timezone}>{value.timezone}</option>
          )}
        </select>
      </div>

      {/* Next 3 Runs Preview */}
      {validation.valid && (
        <div className="space-y-1.5 rounded-lg border border-white/10 bg-black/20 p-3">
          <label className="block text-xs font-medium text-zinc-400">
            Next 3 Scheduled Executions:
          </label>
          {nextRuns.length > 0 ? (
            <ul data-debug-id="schedule-next-runs-list" className="space-y-1">
              {nextRuns.map((runDate, i) => (
                <li key={i} className="flex items-center gap-2 text-xs text-zinc-300 font-mono">
                  <span className="text-zinc-500">#{i + 1}</span>
                  <span>{runDate.toISOString().replace('T', ' ').slice(0, 19)} UTC</span>
                  <span className="text-zinc-500 text-[11px]">({value.timezone || 'UTC'})</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-xs text-zinc-500 italic">No upcoming runs found within active window</p>
          )}
        </div>
      )}

      {/* Blackout Dates Picker */}
      <div className="space-y-2 border-t border-white/10 pt-3">
        <div className="flex items-center justify-between">
          <div>
            <label className="text-xs font-semibold text-zinc-300">Blackout Dates</label>
            <p className="text-[11px] text-zinc-500">Dates on which execution is suppressed</p>
          </div>
        </div>

        {/* Existing Blackout Date Chips */}
        {value.blackout_dates && value.blackout_dates.length > 0 ? (
          <div data-debug-id="schedule-blackout-chips" className="flex flex-wrap gap-1.5">
            {value.blackout_dates.map((date) => (
              <span
                key={date}
                className="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-zinc-900 px-2 py-1 text-xs text-zinc-200"
              >
                <span>{date}</span>
                <button
                  type="button"
                  data-debug-id={`schedule-remove-blackout-btn-${date}`}
                  onClick={() => handleRemoveBlackoutDate(date)}
                  className="text-zinc-500 hover:text-red-400 transition-colors"
                  title="Remove blackout date"
                  aria-label={`Remove blackout date ${date}`}
                >
                  <Icon name="close" size={12} />
                </button>
              </span>
            ))}
          </div>
        ) : (
          <p className="text-xs text-zinc-600 italic">No blackout dates configured</p>
        )}

        {/* Add Blackout Date Form */}
        <div className="flex items-center gap-2">
          <input
            type="date"
            data-debug-id="schedule-blackout-input"
            value={newBlackoutDate}
            onChange={(e) => setNewBlackoutDate(e.target.value)}
            className="rounded-lg border border-white/10 bg-zinc-900 px-3 py-1.5 text-xs text-zinc-200 outline-none focus:border-sky-400"
          />
          <button
            type="button"
            data-debug-id="schedule-add-blackout-btn"
            onClick={handleAddBlackoutDate}
            className="px-3 py-1.5 rounded-lg border border-white/10 bg-white/5 hover:bg-white/10 text-xs font-medium text-white transition-colors"
          >
            Add Date
          </button>
        </div>
        {blackoutError && <p className="text-xs text-red-400">{blackoutError}</p>}
      </div>

      {/* Active Window (Optional) */}
      <div className="space-y-2 border-t border-white/10 pt-3">
        <label className="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            checked={enableWindow}
            onChange={(e) => {
              const checked = e.target.checked;
              setEnableWindow(checked);
              if (!checked) {
                onChange({ ...value, active_from: undefined, active_until: undefined });
              }
            }}
            className="rounded border-white/20 bg-zinc-900 text-sky-500 focus:ring-0"
          />
          <span className="text-xs font-semibold text-zinc-300">Set Active Date/Time Window</span>
        </label>

        {enableWindow && (
          <div className="grid gap-3 sm:grid-cols-2 rounded-lg border border-white/10 bg-black/20 p-3">
            <div>
              <label className="block text-xs text-zinc-400 mb-1">Active From</label>
              <input
                type="datetime-local"
                data-debug-id="schedule-active-from-input"
                value={value.active_from ? value.active_from.slice(0, 16) : ''}
                onChange={(e) => onChange({ ...value, active_from: e.target.value ? new Date(e.target.value).toISOString() : undefined })}
                className="w-full rounded-lg border border-white/10 bg-zinc-900 px-2.5 py-1.5 text-xs text-zinc-200 outline-none focus:border-sky-400"
              />
            </div>
            <div>
              <label className="block text-xs text-zinc-400 mb-1">Active Until</label>
              <input
                type="datetime-local"
                data-debug-id="schedule-active-until-input"
                value={value.active_until ? value.active_until.slice(0, 16) : ''}
                onChange={(e) => onChange({ ...value, active_until: e.target.value ? new Date(e.target.value).toISOString() : undefined })}
                className="w-full rounded-lg border border-white/10 bg-zinc-900 px-2.5 py-1.5 text-xs text-zinc-200 outline-none focus:border-sky-400"
              />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
