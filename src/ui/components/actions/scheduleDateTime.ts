/** Native datetime-local values are wall clocks, never browser-local instants. */
function wallClock(ms: number, timezone: string): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(ms));
  const part = (name: string) => parts.find(p => p.type === name)!.value;
  return part('year') + '-' + part('month') + '-' + part('day') + 'T' + part('hour') + ':' + part('minute') + ':' + part('second');
}

export function instantToScheduleLocal(value: string, timezone: string): string {
  if (!value) return '';
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) throw new Error('Invalid stored date/time.');
  return wallClock(ms, timezone) + (value.match(/\.\d{1,3}/)?.[0] || '');
}

export function scheduleLocalToInstant(value: string, timezone: string): string {
  if (!value) return '';
  const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(:\d{2})?(\.\d{1,3})?$/.exec(value);
  if (!match) throw new Error('Choose a complete date and time.');
  const local = match[1] + (match[2] || ':00');
  const wallMs = Date.parse(local + 'Z');
  if (!Number.isFinite(wallMs) || new Date(wallMs).toISOString().slice(0, 19) !== local) throw new Error('Choose a valid date and time.');
  // Sample both sides of DST transitions, reject gaps, choose the earlier fold.
  const candidates = new Set<number>();
  for (let hours = -36; hours <= 36; hours += 6) {
    const sample = wallMs + hours * 3600000;
    const offset = Date.parse(wallClock(sample, timezone) + 'Z') - sample;
    const candidate = wallMs - offset;
    if (wallClock(candidate, timezone) === local) candidates.add(candidate);
  }
  if (!candidates.size) throw new Error('This time does not exist in the selected time zone. Choose another time.');
  const instant = Math.min(...candidates);
  const offsetMinutes = (wallMs - instant) / 60000;
  const sign = offsetMinutes < 0 ? '-' : '+';
  const magnitude = Math.abs(offsetMinutes);
  if (!Number.isInteger(magnitude)) throw new Error('Choose a modern date with a whole-minute time-zone offset.');
  const offset = sign + String(Math.floor(magnitude / 60)).padStart(2, '0') + ':' + String(magnitude % 60).padStart(2, '0');
  return local + (match[3] || '') + offset;
}
