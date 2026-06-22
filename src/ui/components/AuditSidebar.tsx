import { useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { fetchUnreviewedChains } from '../store/taskSlice';
import AuditCard from './AuditCard';

interface AuditSidebarProps {
  open: boolean;
  onClose: () => void;
}

export default function AuditSidebar({ open, onClose }: AuditSidebarProps) {
  const dispatch = useDispatch<any>();
  const unreviewedChains = useSelector((state: any) => state.tasks.unreviewedChains || []);
  const loading = useSelector((state: any) => state.tasks.loading);

  useEffect(() => {
    if (open) {
      dispatch(fetchUnreviewedChains());
    }
  }, [open, dispatch]);

  return (
    <>
      {/* Backdrop overlay */}
      {open && (
        <div
          className="fixed inset-0 bg-black/50 z-40 transition-opacity duration-300"
          onClick={onClose}
        />
      )}

      {/* Right Sidebar Panel */}
      <div
        className={`fixed top-0 right-0 h-full w-[360px] bg-[#0a0a0a] border-l border-[#1c1c1c] shadow-[var(--fd-shadow-elevated)] z-50 transition-transform duration-300 ease-[cubic-bezier(0.16,1,0.3,1)] flex flex-col ${
          open ? 'translate-x-0' : 'translate-x-full'
        }`}
      >
        {/* Sidebar Header */}
        <div className="p-5 border-b border-[#1c1c1c] flex items-center justify-between">
          <div className="flex flex-col gap-1">
            <h2 className="text-[#eee] text-base font-bold tracking-tight">Task Chain Audit</h2>
            <p className="text-[11px] text-[#666] leading-relaxed">
              Review and grade completed agent task chains.
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-[#666] hover:text-[#eee] hover:bg-[#1a1a1a] p-1.5 rounded-lg transition-all active:scale-95"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Sidebar Body */}
        <div className="flex-1 overflow-y-auto p-5 flex flex-col gap-4">
          {loading && unreviewedChains.length === 0 ? (
            <div className="flex-1 flex flex-col items-center justify-center gap-2">
              <div className="w-6 h-6 border-2 border-t-transparent border-white rounded-full animate-spin" />
              <span className="text-xs text-[#555]">Loading pending audits...</span>
            </div>
          ) : unreviewedChains.length === 0 ? (
            <div className="flex-1 flex flex-col items-center justify-center text-center px-4 py-8 animate-fade-in">
              <div className="w-12 h-12 rounded-full bg-[#111] border border-[#222] flex items-center justify-center text-[#444] mb-3">
                <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-6 9l2 2 4-4" />
                </svg>
              </div>
              <h4 className="text-[#eee] text-xs font-semibold mb-1">All Caught Up!</h4>
              <p className="text-[10px] text-[#555] max-w-[200px] leading-relaxed">
                No completed task chains are currently pending quality audit.
              </p>
            </div>
          ) : (
            unreviewedChains.map((chain: any) => (
              <AuditCard key={chain.chainId} chain={chain} />
            ))
          )}
        </div>
      </div>
    </>
  );
}
