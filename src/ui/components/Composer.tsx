import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { sendMessageToSelectedAgent } from '../store/chatSlice';
import { handleKeyDownCtrlW } from '../utils/keyboard';

export default function Composer({ selectedAgent, disabled, onSubmit, smartReplies }) {
  const dispatch = useDispatch<any>();
  const [body, setBody] = useState('');
  console.log('[Render] Composer', { hasAgent: !!selectedAgent, disabled, bodyLength: body.length });
  const canSend = selectedAgent && body.trim() && !disabled;

  function handleSubmit(event) {
    const nextBody = body.trim();
    if (event) event.preventDefault();
    if (!canSend) return;
    if (onSubmit) {
      onSubmit();
    }
    setBody('');
    const tempId = `local_temp_${Date.now()}`;
    dispatch(sendMessageToSelectedAgent({ body: nextBody, tempId }));
  }

  function handleSmartReplyClick(replyText: string) {
    if (!selectedAgent || disabled) return;
    if (onSubmit) {
      onSubmit();
    }
    setBody('');
    const tempId = `local_temp_${Date.now()}`;
    dispatch(sendMessageToSelectedAgent({ body: replyText, tempId }));
  }

  const showReplies = smartReplies && smartReplies.length > 0 && !disabled;

  return (
    <div className="border-t border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-4 flex flex-col gap-2.5">
      {/* Smart Replies Row */}
      {showReplies && (
        <div className="flex flex-wrap gap-2 animate-float-in px-1">
          {smartReplies.map((reply: string, idx: number) => (
            <button
              key={idx}
              type="button"
              onClick={() => handleSmartReplyClick(reply)}
              className="bg-[#181818] hover:bg-[var(--fd-accent-blue)] hover:text-black border border-[#2a2a2a] hover:border-[var(--fd-accent-blue)]/50 text-[#ccc] text-xs px-3.5 py-1.5 rounded-full transition-all active:scale-95 font-semibold shadow-sm"
            >
              {reply}
            </button>
          ))}
        </div>
      )}

      <form className="w-full" onSubmit={handleSubmit}>
        <div className="framer-card relative rounded-[var(--fd-radius-xxl)] p-2 transition-all duration-300 focus-within:border-[var(--fd-accent-blue)]/60 focus-within:shadow-[0_0_0_1px_var(--fd-accent-blue)]">
          <label htmlFor="composer" className="sr-only">
            Message {selectedAgent?.label ?? 'agent'}
          </label>
          <textarea
            id="composer"
            data-debug-id="message-input"
            rows={2}
            value={body}
            onChange={(event) => setBody(event.target.value)}
            onKeyDown={(event) => {
              handleKeyDownCtrlW(event);
              if (event.defaultPrevented) return;
              if (event.key === 'Enter' && event.ctrlKey) {
                handleSubmit(event);
              }
            }}
            placeholder={selectedAgent ? `Message ${selectedAgent.id}...` : 'Select a connected agent to start chatting'}
            className="framer-input max-h-32 w-full resize-none rounded-[var(--fd-radius-md)] border-0 bg-transparent px-3 py-2 text-sm transition-colors duration-300 placeholder:text-[#999]"
          />
          <div className="flex items-center justify-between px-2 pb-1">
            <p className="framer-subtext">Messages send through /user-rpc send_to_agent</p>
            <button
              type="submit"
              data-debug-id="send-message-btn"
              disabled={!canSend}
              className="framer-pill bg-white disabled:cursor-not-allowed disabled:opacity-40"
            >
              Send
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}
