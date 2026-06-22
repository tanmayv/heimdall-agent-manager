import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { evaluateTaskChain } from '../store/taskSlice';

export default function AuditCard({ chain }: { chain: any }) {
  const dispatch = useDispatch<any>();
  const [expanded, setExpanded] = useState(false);
  const [isExiting, setIsExiting] = useState(false);
  const [loadingRating, setLoadingRating] = useState<'good' | 'bad' | null>(null);

  async function handleRate(rating: 'good' | 'bad') {
    if (loadingRating) return;
    setLoadingRating(rating);
    try {
      await dispatch(evaluateTaskChain({ chainId: chain.chainId, evaluation: rating })).unwrap();
      // Trigger slide-out animation
      setIsExiting(true);
    } catch (e) {
      setLoadingRating(null);
    }
  }

  return (
    <div
      className={`framer-card rounded-[var(--fd-radius-xl)] border border-[#222] bg-[#111] p-4 transition-all duration-300 flex flex-col gap-3 shadow-md ${
        isExiting ? 'translate-x-[120%] opacity-0 pointer-events-none' : ''
      }`}
      style={{
        transition: 'transform 350ms cubic-bezier(0.4, 0, 0.2, 1), opacity 300ms ease-out',
      }}
    >
      {/* Collapsed Header */}
      <div
        className="flex items-start justify-between cursor-pointer select-none"
        onClick={() => setExpanded(!expanded)}
      >
        <div className="flex flex-col gap-1.5 min-w-0 flex-1 pr-2">
          <h3 className="text-[#eee] text-sm font-semibold truncate hover:text-[var(--fd-accent-blue)] transition-colors">
            {chain.title || 'Untitled Task Chain'}
          </h3>
          <div className="flex items-center gap-2 text-xs text-[#888]">
            <span className="bg-[#1a1a1a] px-2 py-0.5 rounded border border-[#2a2a2a] truncate max-w-[120px]">
              {chain.coordinatorAgentInstanceId.split('@')[0]}
            </span>
            <span>•</span>
            <span>{new Date(chain.completedAtUnixMs).toLocaleTimeString()}</span>
          </div>
        </div>
        <button
          type="button"
          className="text-[#666] hover:text-[#eee] p-0.5 rounded transition-colors self-start mt-0.5"
        >
          <svg
            className={`w-4 h-4 transform transition-transform duration-200 ${expanded ? 'rotate-180' : ''}`}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
      </div>

      {/* Expanded Content */}
      {expanded && (
        <div className="flex flex-col gap-3 border-t border-[#1a1a1a] pt-3 animate-slide-down">
          {chain.description && (
            <div className="text-xs text-[#888] italic leading-relaxed bg-[#0a0a0a] p-2.5 rounded border border-[#181818]">
              {chain.description}
            </div>
          )}
          
          <div className="flex flex-col gap-1.5">
            <span className="text-[10px] text-[#555] font-bold uppercase tracking-wider">Final Summary</span>
            <div className="text-xs text-[#bbb] bg-[#0a0a0a] p-3 rounded border border-[#181818] max-h-48 overflow-y-auto whitespace-pre-wrap font-sans leading-relaxed">
              {chain.finalSummary || 'No summary provided by coordinator agent.'}
            </div>
          </div>

          {/* Action Footer */}
          <div className="flex items-center justify-between gap-2 pt-1">
            <button
              type="button"
              disabled={loadingRating !== null}
              onClick={() => handleRate('bad')}
              className={`flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-lg border border-[#3a1a1a] hover:border-[#833] text-[#c99] hover:text-[#fcc] hover:bg-[#2a0c0c]/40 text-xs font-semibold transition-all active:scale-95 disabled:opacity-40 disabled:pointer-events-none ${
                loadingRating === 'bad' ? 'bg-[#2a0c0c] border-[#833]' : ''
              }`}
            >
              {loadingRating === 'bad' ? (
                <div className="w-3.5 h-3.5 border-2 border-t-transparent border-[#fcc] rounded-full animate-spin" />
              ) : (
                <>
                  <svg className="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M6 18L18 6M6 6l12 12" />
                  </svg>
                  Mark Bad
                </>
              )}
            </button>

            <button
              type="button"
              disabled={loadingRating !== null}
              onClick={() => handleRate('good')}
              className={`flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-lg bg-white hover:bg-[#e0e0e0] text-black text-xs font-bold transition-all active:scale-95 disabled:opacity-40 disabled:pointer-events-none ${
                loadingRating === 'good' ? 'bg-[#bbb]' : ''
              }`}
            >
              {loadingRating === 'good' ? (
                <div className="w-3.5 h-3.5 border-2 border-t-transparent border-black rounded-full animate-spin" />
              ) : (
                <>
                  <svg className="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M5 13l4 4L19 7" />
                  </svg>
                  Mark Good
                </>
              )}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
