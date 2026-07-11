const toneByStatus = {
  connected: 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200',
  connecting: 'border-[var(--fd-accent-blue)]/30 bg-[var(--fd-accent-blue)]/6 text-[var(--fd-accent-blue)]',
  error: 'border-rose-400/30 bg-rose-400/10 text-rose-200',
  reconnecting: 'border-[var(--fd-accent-blue)]/30 bg-[var(--fd-accent-blue)]/6 text-[var(--fd-accent-blue)]',
  idle: 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] text-[#999]',
};

export default function ConnectionBadge({ session }) {
  const isConnected = session.status === 'connected';
  const wsConnected = session.wsStatus === 'connected';

  return (
    <div className="framer-card framer-panel mt-3 relative overflow-hidden p-3">
      <div className="relative flex items-center justify-between gap-3">
        <span className="framer-topline">Daemon</span>
        <span
          className={`inline-flex items-center gap-2 rounded-full border px-2.5 py-1 text-[11px] font-medium transition-colors duration-500 ${
            toneByStatus[session.status] ?? toneByStatus.idle
          }`}
        >
          <span className={`h-2 w-2 rounded-full ${isConnected ? 'animate-soft-pulse bg-emerald-300' : 'bg-[#999]'}`} />
          {isConnected ? 'Connected' : session.status}
        </span>
      </div>
      <p className="framer-subtext mt-2 truncate">{session.daemonUrl}</p>
      <div className="relative mt-2 flex items-center justify-between gap-2 rounded-[var(--fd-radius-sm)] bg-[var(--fd-surface-2)] px-2.5 py-1.5 border border-[var(--fd-hairline)]">
        <span className="framer-subtext truncate">{session.clientInstanceId}</span>
        <span
          className={`inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] ${
            toneByStatus[session.wsStatus] ?? toneByStatus.idle
          }`}
        >
          <span
            className={`h-1.5 w-1.5 rounded-full ${
              wsConnected ? 'animate-soft-pulse bg-emerald-300' : 'bg-[#999]'
            }`}
          />
          WS {session.wsStatus ?? 'idle'}
        </span>
      </div>
      {session.error ? <p className="framer-subtext mt-2 animate-bubble-pop text-rose-200">{session.error}</p> : null}
    </div>
  );
}
