import { formatInTimeZone, timeZoneLabel } from '../actions/scheduleUtils';

/** Prefer the actual fire over the requested schedule slot. */
export function actionRunTime(metadata: any): { label: string; timestamp: string } {
  let meta = metadata;
  if (typeof meta === 'string') {
    try { meta = JSON.parse(meta); } catch { meta = {}; }
  }
  meta = meta && typeof meta === 'object' ? meta : {};
  const timezone = String(meta.timezone ?? meta.time_zone ?? meta.tz ?? '');
  for (const raw of [meta.triggered_at, meta.triggeredAt, meta.fired_at, meta.firedAt, meta.target_run_at, meta.targetRunAt]) {
    if (!raw) continue;
    const date = new Date(raw);
    if (!Number.isFinite(date.getTime())) continue;
    return { label: `${formatInTimeZone(date, timezone)} (${timeZoneLabel(date, timezone)})`, timestamp: date.toISOString() };
  }
  return { label: '', timestamp: '' };
}
