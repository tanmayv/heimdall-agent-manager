import SessionConfig from './SessionConfig';

export default function SettingsPage({ session, onReconnect, onBack }) {
  return (
    <main className="framer-panel flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="flex animate-float-in items-center justify-between border-b border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-6 py-4">
        <div>
          <p className="framer-topline">Settings</p>
          <h2 className="mt-1 truncate text-2xl font-bold text-white">Daemon + User session</h2>
          <p className="framer-subtext mt-1">Manage local connection preferences and reconnect</p>
        </div>
        <button
          type="button"
          data-debug-id="settings-back-btn"
          onClick={onBack}
          className="framer-pill-secondary px-4 py-2 text-xs"
        >
          Back to chat
        </button>
      </header>

      <section className="flex-1 overflow-y-auto px-6 py-6">
        <div className="w-full max-w-2xl">
          <SessionConfig session={session} onReconnect={onReconnect} />
          <div className="framer-card mt-4 p-3 text-xs text-[#999]">
            <p>Session and connection details persist locally in Electron and are used across restarts.</p>
            <p className="mt-2 text-[11px] text-[#777]">Changing user ID regenerates local client identity and credentials.</p>
          </div>
        </div>
      </section>
    </main>
  );
}
