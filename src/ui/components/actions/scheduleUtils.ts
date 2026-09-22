export const COMMON_TIMEZONES = [
  'UTC',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
  'America/Phoenix',
  'America/Anchorage',
  'America/Toronto',
  'America/Vancouver',
  'America/Sao_Paulo',
  'Europe/London',
  'Europe/Paris',
  'Europe/Berlin',
  'Europe/Amsterdam',
  'Europe/Zurich',
  'Europe/Madrid',
  'Europe/Rome',
  'Asia/Tokyo',
  'Asia/Shanghai',
  'Asia/Singapore',
  'Asia/Hong_Kong',
  'Asia/Seoul',
  'Asia/Kolkata',
  'Asia/Dubai',
  'Australia/Sydney',
  'Australia/Melbourne',
  'Pacific/Auckland',
  'Pacific/Honolulu',
];

export function getLocalTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch (_e) {
    return 'UTC';
  }
}

// SCHED-TZ-1: format an absolute Date instant as a wall-clock string in the given
// IANA time zone. calculateNextRuns() returns correct absolute instants; this only
// controls DISPLAY (previously the UI used Date.toISOString(), which always renders
// UTC while mislabeling it with the selected zone). Returns e.g. "2026-09-04 14:30".
// Falls back to a UTC wall-clock string when the zone is empty/invalid.
export function formatInTimeZone(date: Date, timezone: string): string {
  const tz = timezone || 'UTC';
  try {
    const dtf = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    });
    const parts = dtf.formatToParts(date);
    const get = (type: string) => parts.find((p) => p.type === type)?.value || '';
    return `${get('year')}-${get('month')}-${get('day')} ${get('hour')}:${get('minute')}`;
  } catch (_e) {
    // Invalid zone: render the UTC wall-clock instead of throwing.
    return date.toISOString().replace('T', ' ').slice(0, 16);
  }
}

// SCHED-TZ-1: a human label for the zone a time is shown in, with a short GMT
// offset for clarity (e.g. "Asia/Kolkata GMT+5:30"). The offset is date-dependent
// so DST is reflected correctly. Falls back to the bare zone name (or "UTC").
export function timeZoneLabel(date: Date, timezone: string): string {
  const tz = timezone || 'UTC';
  if (tz === 'UTC') return 'UTC';
  try {
    const dtf = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'shortOffset' });
    const offset = dtf.formatToParts(date).find((p) => p.type === 'timeZoneName')?.value || '';
    return offset && offset !== 'GMT' ? `${tz} ${offset}` : tz;
  } catch (_e) {
    return 'UTC';
  }
}

export function validateCronField(field: string, min: number, max: number): boolean {
  const f = field.trim();
  if (!f) return false;
  if (f === '*') return true;

  if (f.includes('/')) {
    const parts = f.split('/');
    if (parts.length !== 2) return false;
    const base = parts[0];
    const step = parseInt(parts[1], 10);
    if (isNaN(step) || step <= 0) return false;
    if (base !== '*' && !validateCronField(base, min, max)) return false;
    return true;
  }

  if (f.includes(',')) {
    const subparts = f.split(',');
    if (subparts.length === 0) return false;
    return subparts.every((sub) => validateCronField(sub, min, max));
  }

  if (f.includes('-')) {
    const parts = f.split('-');
    if (parts.length !== 2) return false;
    const low = parseInt(parts[0], 10);
    const high = parseInt(parts[1], 10);
    if (isNaN(low) || isNaN(high)) return false;
    if (low < min || high > max || low > high) return false;
    return true;
  }

  const val = parseInt(f, 10);
  if (isNaN(val)) return false;
  return val >= min && val <= max;
}

export function validateCronExpression(cron: string): { valid: boolean; error?: string } {
  const trimmed = cron.trim();
  if (!trimmed) return { valid: false, error: 'Cron expression cannot be empty' };
  const parts = trimmed.split(/\s+/);
  if (parts.length !== 5) {
    return { valid: false, error: `Expected 5 fields (minute hour dom month dow), got ${parts.length}` };
  }

  if (!validateCronField(parts[0], 0, 59)) return { valid: false, error: 'Invalid minute field (0-59)' };
  if (!validateCronField(parts[1], 0, 23)) return { valid: false, error: 'Invalid hour field (0-23)' };
  if (!validateCronField(parts[2], 1, 31)) return { valid: false, error: 'Invalid day of month field (1-31)' };
  if (!validateCronField(parts[3], 1, 12)) return { valid: false, error: 'Invalid month field (1-12)' };
  if (!validateCronField(parts[4], 0, 7)) return { valid: false, error: 'Invalid day of week field (0-7)' };

  return { valid: true };
}

const DOW_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/**
 * `min`, `hour` -> `HH:MM`, but ONLY when both are plain integers.
 *
 * Returns '' otherwise, and every caller below treats that as "this schedule has no
 * single clock time". Without the guard a stepped or listed field is padded like a
 * number and prints nonsense: a cron whose hour field is a step (minute 30, hour
 * "every 2nd") rendered as "Daily at (step):30", which is not a time and not what
 * the expression means.
 */
function clockTime(min: string, hour: string): string {
  const m = /^\d{1,2}$/.test(min.trim()) ? parseInt(min, 10) : NaN;
  const h = /^\d{1,2}$/.test(hour.trim()) ? parseInt(hour, 10) : NaN;
  if (!Number.isFinite(m) || !Number.isFinite(h)) return '';
  if (m < 0 || m > 59 || h < 0 || h > 23) return '';
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}`;
}

export function describeCron(cron: string): string {
  const check = validateCronExpression(cron);
  if (!check.valid) return check.error || 'Invalid cron expression';

  const parts = cron.trim().split(/\s+/);
  const [min, hour, dom, month, dow] = parts;

  if (cron === '* * * * *') return 'Every minute';
  if (min.startsWith('*/') && hour === '*' && dom === '*' && month === '*' && dow === '*') {
    return `Every ${min.slice(2)} minutes`;
  }
  if (min === '0' && hour === '*' && dom === '*' && month === '*' && dow === '*') {
    return 'Every hour, on the hour';
  }
  if (min === '0' && hour.startsWith('*/') && dom === '*' && month === '*' && dow === '*') {
    return `Every ${hour.slice(2)} hours, on the hour`;
  }
  if (dom === '*' && month === '*' && dow === '*') {
    const at = clockTime(min, hour);
    if (at) return `Daily at ${at}`;
  }
  if (dom === '*' && month === '*' && (dow === '1-5' || dow === '1,2,3,4,5')) {
    const at = clockTime(min, hour);
    if (at) return `Weekdays (Mon-Fri) at ${at}`;
  }
  if (dom === '*' && month === '*' && (dow === '0,6' || dow === '6,0' || dow === '7,6' || dow === '6,7')) {
    const at = clockTime(min, hour);
    if (at) return `Weekends at ${at}`;
  }
  if (dom === '*' && month === '*' && dow !== '*') {
    const at = clockTime(min, hour);
    if (at) {
      const days = dow.split(',').map((d) => {
        const num = parseInt(d, 10);
        return !isNaN(num) && num >= 0 && num <= 7 ? DOW_NAMES[num] : d;
      }).join(', ');
      return `Every ${days} at ${at}`;
    }
  }

  // Day-of-month schedules. These used to fall through to a field-by-field dump
  // that read as noise in a list row ("At minute 0, hour 3, day-of-month 1, month *,
  // day-of-week *") and was wide enough to wrap the row's pill line onto a second.
  if (dow === '*' && dom !== '*') {
    const at = clockTime(min, hour);
    const day = ordinal(dom);
    if (!at) return `Custom: ${cron}`;
    // A day-of-month that is not a single day (a step, a list, a range) is not
    // "monthly on the Nth" — saying so would be a confident wrong reading, so it
    // falls through to the expression itself.
    if (!day) return `Custom: ${cron}`;
    if (month === '*') return `Monthly on the ${day} at ${at}`;
    const monthName = MONTH_NAMES[parseInt(month, 10)];
    if (monthName) return `Yearly on ${monthName} ${day} at ${at}`;
  }
  if (dom === '*' && dow === '*' && month !== '*') {
    const at = clockTime(min, hour);
    const monthName = MONTH_NAMES[parseInt(month, 10)];
    if (at && monthName) return `Daily in ${monthName} at ${at}`;
  }

  // Anything genuinely irregular (a list of months, a step on day-of-month). Naming
  // it as custom and showing the expression is shorter and more honest than reading
  // five fields aloud.
  return `Custom: ${cron}`;
}

const MONTH_NAMES: Record<number, string> = {
  1: 'January', 2: 'February', 3: 'March', 4: 'April', 5: 'May', 6: 'June',
  7: 'July', 8: 'August', 9: 'September', 10: 'October', 11: 'November', 12: 'December',
};

/** `1` -> `1st`. Returns '' for anything that is not a plain day number. */
function ordinal(value: string): string {
  const n = parseInt(value, 10);
  if (!Number.isFinite(n) || String(n) !== value.trim() || n < 1 || n > 31) return '';
  const rem100 = n % 100;
  if (rem100 >= 11 && rem100 <= 13) return `${n}th`;
  switch (n % 10) {
    case 1: return `${n}st`;
    case 2: return `${n}nd`;
    case 3: return `${n}rd`;
    default: return `${n}th`;
  }
}

export function buildEveryNHours(hours: number): string {
  if (hours <= 1) return '0 * * * *';
  return `0 */${hours} * * *`;
}

export function buildDaily(timeStr: string): string {
  const [h, m] = (timeStr || '09:00').split(':');
  const hour = parseInt(h, 10) || 0;
  const min = parseInt(m, 10) || 0;
  return `${min} ${hour} * * *`;
}

export function buildWeekly(timeStr: string, days: number[]): string {
  const [h, m] = (timeStr || '09:00').split(':');
  const hour = parseInt(h, 10) || 0;
  const min = parseInt(m, 10) || 0;
  const sortedDays = Array.from(new Set(days)).sort();
  const dowStr = sortedDays.length > 0 ? sortedDays.join(',') : '*';
  return `${min} ${hour} * * ${dowStr}`;
}

export type PresetType = 'every_n_hours' | 'daily' | 'weekly' | 'custom';

export function detectPreset(cron: string): {
  type: PresetType;
  hours?: number;
  time?: string;
  days?: number[];
} {
  const trimmed = cron.trim();
  const parts = trimmed.split(/\s+/);
  if (parts.length !== 5) return { type: 'custom' };

  const [min, hour, dom, month, dow] = parts;

  // Check every N hours: "0 * * * *" or "0 */N * * *"
  if (min === '0' && dom === '*' && month === '*' && dow === '*') {
    if (hour === '*') return { type: 'every_n_hours', hours: 1 };
    if (hour.startsWith('*/')) {
      const h = parseInt(hour.slice(2), 10);
      if (!isNaN(h) && h > 0) return { type: 'every_n_hours', hours: h };
    }
  }

  // Check daily: "MM HH * * *"
  const minNum = parseInt(min, 10);
  const hourNum = parseInt(hour, 10);
  if (!isNaN(minNum) && !isNaN(hourNum) && dom === '*' && month === '*' && dow === '*') {
    const time = `${String(hourNum).padStart(2, '0')}:${String(minNum).padStart(2, '0')}`;
    return { type: 'daily', time };
  }

  // Check weekly: "MM HH * * DOW"
  if (!isNaN(minNum) && !isNaN(hourNum) && dom === '*' && month === '*' && dow !== '*') {
    const days = dow.split(',').map((d) => parseInt(d.trim(), 10)).filter((n) => !isNaN(n));
    if (days.length > 0) {
      const time = `${String(hourNum).padStart(2, '0')}:${String(minNum).padStart(2, '0')}`;
      return { type: 'weekly', time, days };
    }
  }

  return { type: 'custom' };
}

function fieldMatches(val: number, expr: string, min: number, max: number): boolean {
  const f = expr.trim();
  if (f === '*') return true;

  if (f.includes('/')) {
    const parts = f.split('/');
    const base = parts[0];
    const step = parseInt(parts[1], 10);
    if (isNaN(step) || step <= 0) return false;
    if (base === '*') {
      return (val - min) % step === 0;
    }
    if (base.includes('-')) {
      const rangeParts = base.split('-');
      const low = parseInt(rangeParts[0], 10);
      const high = parseInt(rangeParts[1], 10);
      if (val < low || val > high) return false;
      return (val - low) % step === 0;
    }
    return false;
  }

  if (f.includes(',')) {
    return f.split(',').some((sub) => fieldMatches(val, sub, min, max));
  }

  if (f.includes('-')) {
    const parts = f.split('-');
    const low = parseInt(parts[0], 10);
    const high = parseInt(parts[1], 10);
    return val >= low && val <= high;
  }

  return val === parseInt(f, 10);
}

function getZonedParts(date: Date, tz: string) {
  let dtf: Intl.DateTimeFormat;
  try {
    dtf = new Intl.DateTimeFormat('en-US', {
      timeZone: tz || 'UTC',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
      weekday: 'short',
      hourCycle: 'h23',
    });
  } catch (_e) {
    dtf = new Intl.DateTimeFormat('en-US', {
      timeZone: 'UTC',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
      weekday: 'short',
      hourCycle: 'h23',
    });
  }

  const parts = dtf.formatToParts(date);
  let year = 1970;
  let month = 1;
  let day = 1;
  let hour = 0;
  let minute = 0;
  let weekdayStr = 'Sun';

  for (const p of parts) {
    if (p.type === 'year') year = parseInt(p.value, 10);
    else if (p.type === 'month') month = parseInt(p.value, 10);
    else if (p.type === 'day') day = parseInt(p.value, 10);
    else if (p.type === 'hour') hour = parseInt(p.value, 10);
    else if (p.type === 'minute') minute = parseInt(p.value, 10);
    else if (p.type === 'weekday') weekdayStr = p.value;
  }

  const dows: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const dow = dows[weekdayStr] ?? 0;
  const dateStr = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;

  return { year, month, day, hour, minute, dow, dateStr };
}

export function calculateNextRuns(
  cronExpr: string,
  timezone: string,
  blackoutDates: string[],
  count: number = 3,
  fromDate: Date = new Date(),
  activeFrom?: string,
  activeUntil?: string,
): Date[] {
  const val = validateCronExpression(cronExpr);
  if (!val.valid) return [];

  const parts = cronExpr.trim().split(/\s+/);
  const [minPart, hourPart, domPart, monthPart, dowPart] = parts;

  const tz = timezone || 'UTC';
  const blackouts = new Set(blackoutDates.map((d) => d.trim()));

  const actFromDate = activeFrom ? new Date(activeFrom) : null;
  const actUntilDate = activeUntil ? new Date(activeUntil) : null;

  // Start from the next whole minute after fromDate
  let currentMs = Math.floor(fromDate.getTime() / 60000) * 60000 + 60000;
  if (actFromDate && actFromDate.getTime() > currentMs) {
    currentMs = Math.floor(actFromDate.getTime() / 60000) * 60000;
  }

  const results: Date[] = [];
  const maxIterations = 525600; // max 1 year of minutes

  for (let i = 0; i < maxIterations && results.length < count; i++) {
    const candidate = new Date(currentMs);
    if (actUntilDate && candidate.getTime() > actUntilDate.getTime()) {
      break;
    }

    const { month, day, hour, minute, dow, dateStr } = getZonedParts(candidate, tz);

    // Check blackout date
    if (!blackouts.has(dateStr)) {
      const matchMin = fieldMatches(minute, minPart, 0, 59);
      const matchHour = fieldMatches(hour, hourPart, 0, 23);
      const matchDom = fieldMatches(day, domPart, 1, 31);
      const matchMonth = fieldMatches(month, monthPart, 1, 12);
      const matchDow = fieldMatches(dow, dowPart, 0, 7) || (dow === 0 && fieldMatches(7, dowPart, 0, 7));

      if (matchMin && matchHour && matchDom && matchMonth && matchDow) {
        results.push(candidate);
      }
    }

    currentMs += 60000;
  }

  return results;
}
