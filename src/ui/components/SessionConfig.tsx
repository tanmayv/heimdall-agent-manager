import { useEffect, useState } from 'react';

export default function SessionConfig({ session, onReconnect }) {
  const [daemonUrl, setDaemonUrl] = useState(session.daemonUrl);
  const [userId, setUserId] = useState(session.userId);

  useEffect(() => {
    setDaemonUrl(session.daemonUrl);
    setUserId(session.userId);
  }, [session.daemonUrl, session.userId]);

  const changed = daemonUrl.trim() !== session.daemonUrl || userId.trim() !== session.userId;
  const canConnect = daemonUrl.trim() && userId.trim();

  function handleSubmit(event) {
    event.preventDefault();
    if (!canConnect) return;
    onReconnect({ daemonUrl: daemonUrl.trim(), userId: userId.trim() });
  }

  return (
    <form onSubmit={handleSubmit} className="animate-float-in mt-3 rounded-[1.75rem] border border-slate-800 bg-slate-900/70 p-3 shadow-lg shadow-slate-950/20">
      <div className="flex items-center justify-between gap-3">
        <span className="text-xs font-semibold uppercase tracking-[0.2em] text-slate-500">Config</span>
        <button
          type="submit"
          disabled={!canConnect}
          className="rounded-full bg-blue-500 px-3 py-1 text-xs font-semibold text-white shadow-lg shadow-blue-950/30 transition-all duration-200 hover:-translate-y-0.5 hover:scale-105 hover:bg-blue-400 active:scale-95 disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:translate-y-0 disabled:hover:scale-100"
        >
          {changed ? 'Save + reconnect' : 'Reconnect'}
        </button>
      </div>
      <label className="mt-3 block text-xs text-slate-500" htmlFor="daemon-url">
        Daemon URL
      </label>
      <input
        id="daemon-url"
        value={daemonUrl}
        onChange={(event) => setDaemonUrl(event.target.value)}
        className="mt-1 w-full rounded-2xl border border-slate-800 bg-slate-950/60 px-3 py-2 font-mono text-xs text-slate-200 outline-none transition-all duration-200 focus:border-blue-400/70 focus:shadow-lg focus:shadow-blue-950/20"
        placeholder="http://127.0.0.1:49322"
      />
      <label className="mt-3 block text-xs text-slate-500" htmlFor="user-id">
        User ID
      </label>
      <input
        id="user-id"
        value={userId}
        onChange={(event) => setUserId(event.target.value)}
        className="mt-1 w-full rounded-2xl border border-slate-800 bg-slate-950/60 px-3 py-2 font-mono text-xs text-slate-200 outline-none transition-all duration-200 focus:border-blue-400/70 focus:shadow-lg focus:shadow-blue-950/20"
        placeholder="operator@local"
      />
      <p className="mt-2 text-[11px] leading-4 text-slate-500">Persists daemon URL, user, client id, and local client token for restart reuse.</p>
    </form>
  );
}
