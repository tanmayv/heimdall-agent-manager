import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { sendMessageToSelectedAgent } from '../store/chatSlice';

export default function Composer({ selectedAgent, disabled, onSubmit }) {
  const dispatch = useDispatch<any>();
  const [body, setBody] = useState('');
  const canSend = selectedAgent && body.trim() && !disabled;

  function handleSubmit(event) {
    const nextBody = body.trim();
    event.preventDefault();
    if (!canSend) return;
    if (onSubmit) {
      onSubmit();
    }
    setBody('');
    dispatch(sendMessageToSelectedAgent(nextBody));
  }

  return (
    <form className="border-t border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-4" onSubmit={handleSubmit}>
      <div className="framer-card relative rounded-[var(--fd-radius-xxl)] p-2 transition-all duration-300 focus-within:border-[var(--fd-accent-blue)]/60 focus-within:shadow-[0_0_0_1px_var(--fd-accent-blue)]">
        <label htmlFor="composer" className="sr-only">
          Message {selectedAgent?.label ?? 'agent'}
        </label>
        <textarea
          id="composer"
          rows={2}
          value={body}
          onChange={(event) => setBody(event.target.value)}
          placeholder={selectedAgent ? `Message ${selectedAgent.id}...` : 'Select a connected agent to start chatting'}
          className="framer-input max-h-32 w-full resize-none rounded-[var(--fd-radius-md)] border-0 bg-transparent px-3 py-2 text-sm transition-colors duration-300 placeholder:text-[#999]"
        />
        <div className="flex items-center justify-between px-2 pb-1">
          <p className="framer-subtext">Messages send through /user-rpc send_to_agent</p>
          <button
            type="submit"
            disabled={!canSend}
            className="framer-pill bg-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            Send
          </button>
        </div>
      </div>
    </form>
  );
}
