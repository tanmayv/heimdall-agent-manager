const MAX_ENTRIES = 500;

export interface LogEntry {
  level: 'log' | 'warn' | 'error';
  message: string;
  timestamp: number;
}

const ring: LogEntry[] = [];

function push(level: LogEntry['level'], args: unknown[]) {
  const message = args
    .map((a) => (a instanceof Error ? `${a.name}: ${a.message}` : typeof a === 'object' ? JSON.stringify(a) : String(a)))
    .join(' ');
  if (ring.length >= MAX_ENTRIES) ring.shift();
  ring.push({ level, message, timestamp: Date.now() });
}

const _log = console.log.bind(console);
const _warn = console.warn.bind(console);
const _error = console.error.bind(console);

console.log = (...args) => { _log(...args); push('log', args); };
console.warn = (...args) => { _warn(...args); push('warn', args); };
console.error = (...args) => { _error(...args); push('error', args); };

window.onerror = (msg, _src, _line, _col, err) => {
  push('error', [err ?? msg]);
};

window.onunhandledrejection = (ev) => {
  push('error', [ev.reason]);
};

(window as any).__debugLogs = ring;
