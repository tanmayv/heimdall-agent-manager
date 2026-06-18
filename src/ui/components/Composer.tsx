import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { sendMessageToSelectedAgent } from '../store/chatSlice';

export default function Composer({ selectedAgent, disabled }) {
  const dispatch = useDispatch<any>();
  const [body, setBody] = useState('');
  const canSend = selectedAgent && body.trim() && !disabled;

  function handleSubmit(event) {
    event.preventDefault();
    const nextBody = body.trim();
    if (!canSend) return;
    setBody('');
    dispatch(sendMessageToSelectedAgent(nextBody));
  }

  return (
    <form className="border-t border-slate-800 bg-slate-950/80 p-4" onSubmit={handleSubmit}>
      <div className="orbit-ring animate-float-in relative rounded-[2rem] border border-slate-700 bg-slate-900/90 p-2 shadow-xl shadow-slate-950/30 transition-all duration-300 focus-within:-translate-y-0.5 focus-within:border-blue-400/70 focus-within:shadow-blue-500/10">
        <label htmlFor="composer" className="sr-only">
          Message {selectedAgent?.label ?? 'agent'}
        </label>
        <textarea
          id="composer"
          rows={2}
          value={body}
          onChange={(event) => setBody(event.target.value)}
          placeholder={selectedAgent ? `Message ${selectedAgent.id}...` : 'Select a connected agent to start chatting'}
          className="max-h-32 w-full resize-none rounded-[1.5rem] bg-transparent px-3 py-2 text-sm text-slate-100 placeholder:text-slate-500 transition-colors duration-300 focus:bg-slate-950/30 focus:outline-none"
        />
        <div className="flex items-center justify-between px-2 pb-1">
          <p className="text-xs text-slate-500">Messages send through /user-rpc send_to_agent</p>
          <button
            type="submit"
            disabled={!canSend}
            className="rounded-full bg-blue-500 px-4 py-2 text-sm font-semibold text-white shadow-lg shadow-blue-950/30 transition-all duration-200 hover:-translate-y-0.5 hover:scale-105 hover:bg-blue-400 active:translate-y-0 active:scale-95 disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:translate-y-0 disabled:hover:scale-100"
          >
            Send
          </button>
        </div>
      </div>
    </form>
  );
}
