import SessionConfig from './SessionConfig';

export default function SettingsPage({ session, onReconnect, onBack }) {
  return (
    <main className="flex min-w-0 flex-1 flex-col bg-slate-950">
      <header className="flex animate-float-in items-center justify-between border-b border-slate-800 bg-slate-950/90 px-6 py-4">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.25em] text-slate-500">Settings</p>
          <h2 className="mt-1 truncate text-xl font-bold text-white">Daemon + User session</h2>
          <p className="mt-1 text-xs text-slate-400">Manage local connection preferences and reconnect</p>
        </div>
        <button
          type="button"
          onClick={onBack}
          className="rounded-full border border-slate-800 bg-slate-900 px-4 py-2 text-xs font-semibold text-slate-200 shadow-lg shadow-slate-950/20 transition-all duration-200 hover:-translate-y-0.5 hover:border-blue-500/50 hover:bg-slate-800"
        >
          Back to chat
        </button>
      </header>

      <section className="flex-1 overflow-y-auto px-6 py-6">
        <div className="w-full max-w-2xl">
          <SessionConfig session={session} onReconnect={onReconnect} />
          <div className="mt-4 rounded-[1.75rem] border border-slate-800 bg-slate-900/70 p-3 text-xs text-slate-500 shadow-lg shadow-slate-950/20">
            <p>Session and connection details persist locally in Electron and are used across restarts.</p>
            <p className="mt-2 text-[11px] text-slate-600">Changing user ID regenerates local client identity and credentials.</p>
          </div>
        </div>
      </section>
    </main>
  );
}
