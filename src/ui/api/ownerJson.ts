// Request-only JSON validation tree. Never serialize/forward this tree: valid
// JSON numbers that are not canonical safe nonnegative integers are type markers,
// not rounded Numbers. Protocol version/limit only accept small integer slots.
export const OWNER_JSON_MAX_DEPTH = 32;
const nonIntegerSlot = Symbol('noncanonical-or-large-number');

export function parseOwnerRequestDocument(raw: string): unknown {
  let at = 0;
  const fail = (): never => { throw new SyntaxError('Invalid owner request JSON'); };
  const space = () => {
    while (raw[at] === ' ' || raw[at] === '\t' || raw[at] === '\r' || raw[at] === '\n') ++at;
  };
  const string = (): string => {
    if (raw[at] !== '"') return fail();
    const start = at++;
    while (at < raw.length) {
      const ch = raw[at++];
      if (ch === '\\') {
        if (at >= raw.length) return fail();
        ++at; // JSON.parse validates the exact string token, including escapes.
      } else if (ch === '"') {
        return JSON.parse(raw.slice(start, at)) as string;
      }
    }
    return fail();
  };
  const value = (depth: number): unknown => {
    if (depth > OWNER_JSON_MAX_DEPTH) return fail();
    space();
    const ch = raw[at];
    if (ch === '"') return string();
    if (ch === '{') {
      ++at;
      const o: Record<string, unknown> = Object.create(null);
      space();
      if (raw[at] === '}') { ++at; return o; }
      for (;;) {
        space();
        const key = string();
        if (Object.hasOwn(o, key)) return fail();
        space();
        if (raw[at++] !== ':') return fail();
        o[key] = value(depth + 1); // Retain even the empty key for unknown-field checks.
        space();
        if (raw[at] === '}') { ++at; return o; }
        if (raw[at++] !== ',') return fail();
      }
    }
    if (ch === '[') {
      ++at;
      const a: unknown[] = [];
      space();
      if (raw[at] === ']') { ++at; return a; }
      for (;;) {
        a.push(value(depth + 1));
        space();
        if (raw[at] === ']') { ++at; return a; }
        if (raw[at++] !== ',') return fail();
      }
    }
    for (const [token, result] of [['true', true], ['false', false], ['null', null]] as const) {
      if (raw.startsWith(token, at)) { at += token.length; return result; }
    }
    const m = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(raw.slice(at));
    if (!m) return fail();
    const token = m[0];
    at += token.length;
    if (!/^(?:0|[1-9][0-9]*)$/.test(token) || token.length > 16
      || (token.length === 16 && token > '9007199254740991')) return nonIntegerSlot;
    return Number(token); // Checked exact and safe BEFORE conversion.
  };
  const result = value(0);
  space();
  if (at !== raw.length) return fail();
  return result;
}
