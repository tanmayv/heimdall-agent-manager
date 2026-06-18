import Composer from './Composer';
import MessageBubble from './MessageBubble';

export default function ChatPane({ agent, messages, session, sending }) {
  return (
    <main className="flex min-w-0 flex-1 flex-col bg-slate-950">
      <header className="animate-float-in flex items-center justify-between border-b border-slate-800 bg-slate-950/90 px-6 py-4">
        <div className="min-w-0">
          <p className="text-xs font-semibold uppercase tracking-[0.25em] text-slate-500">Selected agent</p>
          <h2 className="mt-1 truncate text-xl font-bold text-white">{agent?.label ?? 'No agent selected'}</h2>
          <p className="mt-1 truncate font-mono text-xs text-slate-400">{agent?.id ?? 'Choose an agent from the sidebar'}</p>
        </div>
        <div className="animate-halo-breathe rounded-[1.5rem] border border-slate-800 bg-slate-900 px-3 py-2 text-right shadow-lg shadow-slate-950/20 transition-all duration-300 hover:-translate-y-0.5 hover:border-blue-400/40">
          <p className="text-xs text-slate-500">User</p>
          <p className="font-mono text-xs text-slate-300">{session.userId}</p>
        </div>
      </header>

      <section className="flex-1 overflow-y-auto bg-[radial-gradient(circle_at_top_right,_rgba(59,130,246,0.12),_transparent_35%),linear-gradient(180deg,_#0f172a,_#020617)] px-1 py-4 sm:px-2">
        <div className="w-full flex flex-col gap-3">
          {messages.length ? (
            messages.map((message) => <MessageBubble key={message.id} message={message} />)
          ) : (
            <div className="animate-float-in rounded-[2rem] border border-dashed border-slate-800 bg-slate-950/50 p-8 text-center text-sm text-slate-500 transition-all duration-300 hover:border-blue-400/30">
              {agent ? 'No chat messages for this agent yet.' : 'Select a connected agent to view chat history.'}
            </div>
          )}
        </div>
      </section>

      <Composer selectedAgent={agent} disabled={!session.connected || sending} />
    </main>
  );
}
