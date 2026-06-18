const toneByStatus = {
  connected: 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200',
  connecting: 'border-amber-300/30 bg-amber-300/10 text-amber-100',
  error: 'border-rose-400/30 bg-rose-400/10 text-rose-200',
  reconnecting: 'border-amber-300/30 bg-amber-300/10 text-amber-100',
  idle: 'border-slate-600 bg-slate-800 text-slate-300',
};

export default function ConnectionBadge({ session }) {
  const isConnected = session.status === 'connected';
  const wsConnected = session.wsStatus === 'connected';

  return (
    <div className="orbit-ring shimmer-surface animate-float-in relative overflow-hidden rounded-[1.75rem] border border-slate-700/80 bg-slate-900/80 p-3 shadow-lg shadow-blue-950/20 transition-all duration-500 hover:-translate-y-0.5 hover:border-blue-400/50 hover:shadow-blue-500/10">
      <div className="relative flex items-center justify-between gap-3">
        <span className="text-xs font-semibold uppercase tracking-[0.2em] text-slate-400">Daemon</span>
        <span className={`inline-flex items-center gap-2 rounded-full border px-2.5 py-1 text-xs font-medium transition-all duration-500 ${toneByStatus[session.status] ?? toneByStatus.idle}`}>
          <span className={`h-2 w-2 rounded-full ${isConnected ? 'animate-soft-pulse bg-emerald-300' : 'bg-slate-400'}`} />
          {isConnected ? 'Connected' : session.status}
        </span>
      </div>
      <p className="relative mt-2 truncate font-mono text-xs text-slate-400">{session.daemonUrl}</p>
      <div className="relative mt-2 flex items-center justify-between gap-2 rounded-full bg-slate-950/40 px-2.5 py-1">
        <span className="truncate font-mono text-xs text-slate-500">{session.clientInstanceId}</span>
        <span className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] ${toneByStatus[session.wsStatus] ?? toneByStatus.idle}`}>
          <span className={`h-1.5 w-1.5 rounded-full ${wsConnected ? 'animate-soft-pulse bg-emerald-300' : 'bg-amber-200'}`} />
          WS {session.wsStatus ?? 'idle'}
        </span>
      </div>
      {session.error ? <p className="relative mt-2 animate-bubble-pop text-xs text-rose-200">{session.error}</p> : null}
    </div>
  );
}
