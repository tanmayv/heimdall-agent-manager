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
    <form onSubmit={handleSubmit} className="framer-card mt-3 p-4">
      <div className="flex items-center justify-between gap-3">
        <span className="framer-topline">Connection config</span>
        <button
          type="submit"
          disabled={!canConnect}
          className="framer-pill bg-white px-3 py-1 text-xs disabled:cursor-not-allowed disabled:opacity-40"
        >
          {changed ? 'Save + reconnect' : 'Reconnect'}
        </button>
      </div>
      <label className="framer-subtext mt-4 block" htmlFor="daemon-url">
        Daemon URL
      </label>
      <input
        id="daemon-url"
        value={daemonUrl}
        onChange={(event) => setDaemonUrl(event.target.value)}
        className="framer-input mt-1 h-10 w-full rounded-[var(--fd-radius-md)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-3 py-2 text-xs"
        placeholder="http://127.0.0.1:49322"
      />
      <label className="framer-subtext mt-4 block" htmlFor="user-id">
        User ID
      </label>
      <input
        id="user-id"
        value={userId}
        onChange={(event) => setUserId(event.target.value)}
        className="framer-input mt-1 h-10 w-full rounded-[var(--fd-radius-md)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-3 py-2 text-xs"
        placeholder="operator@local"
      />
      <p className="framer-subtext mt-2 leading-4 text-[#999]">Persists daemon URL, user, client id, and local client token for restart reuse.</p>
    </form>
  );
}
