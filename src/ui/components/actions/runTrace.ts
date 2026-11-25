/** Render recorded values without re-evaluating a historical rule. */
function display(value: unknown): string {
  if (value && typeof value === 'object' && '_truncated' in value && value._truncated === true) {
    return 'value truncated (' + String((value as { bytes?: number }).bytes ?? '?') + ' bytes)';
  }
  return JSON.stringify(value) ?? 'missing';
}
export function seenValue(snapshot: Record<string, unknown>, field: string): string {
  if (Array.isArray(snapshot._omitted) && snapshot._omitted.some(path => typeof path === 'string' && (field === path || field.startsWith(path + '.')))) return 'value not recorded (snapshot limit)';
  let value: unknown = snapshot;
  for (const segment of field.split('.')) {
    if (value && typeof value === 'object' && '_truncated' in value && value._truncated === true) return display(value);
    if (!value || typeof value !== 'object' || !Object.hasOwn(value, segment)) return Array.isArray(snapshot._omitted) && !(typeof snapshot._omitted_count === 'number' && snapshot._omitted_count > snapshot._omitted.length) ? 'missing' : 'missing or value not recorded';
    value = (value as Record<string, unknown>)[segment];
  }
  return display(value);
}
export function recordedValues(snapshot: Record<string, unknown>, prefix = ''): [string, string][] {
  const values: [string, string][] = Object.entries(snapshot).filter(([key]) => prefix || !key.startsWith('_')).flatMap(([key, value]) => {
    const path = prefix ? prefix + '.' + key : key;
    return value && typeof value === 'object' && !Array.isArray(value) && !('_truncated' in value) && Object.keys(value).length > 0
      ? recordedValues(value as Record<string, unknown>, path) : [[path, display(value)] as [string, string]];
  });
  if (!prefix && Array.isArray(snapshot._omitted)) for (const path of snapshot._omitted) if (typeof path === 'string') values.push([path, 'value not recorded (snapshot limit)']);
  if (!prefix && Array.isArray(snapshot._omitted) && typeof snapshot._omitted_count === 'number' && snapshot._omitted_count > snapshot._omitted.length) values.push(['Additional omitted values', String(snapshot._omitted_count - snapshot._omitted.length) + ' paths were not recorded']);
  return values;
}
