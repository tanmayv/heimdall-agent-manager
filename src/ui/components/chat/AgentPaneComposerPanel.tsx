import { useCallback, useEffect, useRef, useState } from 'react';
import { useAgentPaneSubscription } from '../../hooks/useAgentPaneSubscription';
import Icon from '../Icon';

export interface AgentPaneComposerPanelProps {
  agentInstanceId?: string | null;
  isExpanded: boolean;
  onClose?: () => void;
  onToggleExpand?: () => void;
  isActiveTab?: boolean;
  runtimeStatus?: string;
  className?: string;
}

export function AgentPaneComposerPanel({
  agentInstanceId,
  isExpanded,
  onClose,
  onToggleExpand,
  isActiveTab = true,
  runtimeStatus,
  className = '',
}: AgentPaneComposerPanelProps) {
  const {
    output,
    isLoading,
    isFetching,
    refetch,
  } = useAgentPaneSubscription({
    agentInstanceId,
    isExpanded,
    isActiveTab,
    runtimeStatus,
  });

  const preRef = useRef<HTMLPreElement | null>(null);
  const userScrolledUpRef = useRef<boolean>(false);

  // Detect manual scroll up
  const handleScroll = useCallback(() => {
    const node = preRef.current;
    if (!node) return;
    // If user is within 25px of the bottom, consider at bottom; otherwise manual scroll up
    const isAtBottom = node.scrollHeight - node.scrollTop - node.clientHeight <= 25;
    userScrolledUpRef.current = !isAtBottom;
  }, []);

  // Auto-scroll to bottom on update unless user has manually scrolled up
  useEffect(() => {
    const node = preRef.current;
    if (!node) return;
    if (!userScrolledUpRef.current) {
      node.scrollTop = node.scrollHeight;
    }
  }, [output]);

  // Reset scroll on expand
  useEffect(() => {
    if (isExpanded) {
      userScrolledUpRef.current = false;
      const node = preRef.current;
      if (node) {
        node.scrollTop = node.scrollHeight;
      }
    }
  }, [isExpanded]);

  if (!isExpanded) {
    return null;
  }

  const isStopped = runtimeStatus === 'stopped' || runtimeStatus === 'failed';
  const isUpdatingOrRunning = Boolean(isFetching || runtimeStatus === 'running' || runtimeStatus === 'active');
  const intervalLabel = !agentInstanceId || isStopped || isActiveTab === false ? 'paused' : isExpanded ? '15s' : '5m';

  const handleClose = onClose || onToggleExpand;

  return (
    <div
      data-debug-id="agent-pane-composer-panel"
      className={`overflow-hidden rounded-xl border border-white/10 bg-black/40 ${className}`}
    >
      {/* Header controls */}
      <div
        data-debug-id="agent-pane-composer-header"
        className="flex items-center justify-between border-b border-white/10 bg-white/[0.03] px-3 py-1.5 text-xs text-zinc-300"
      >
        <div className="flex items-center gap-2">
          {/* Status indicator dot (pulsing green if updating/running) */}
          <span
            data-debug-id="agent-pane-status-dot"
            title={isUpdatingOrRunning ? 'Running / updating' : (isStopped ? 'Stopped' : 'Idle')}
            className={`h-2 w-2 rounded-full ${
              isUpdatingOrRunning
                ? 'bg-emerald-400 animate-pulse'
                : isStopped
                ? 'bg-zinc-600'
                : 'bg-emerald-500/70'
            }`}
          />
          <span data-debug-id="agent-pane-title" className="font-semibold text-zinc-200">
            Terminal Output
          </span>
          {/* Refresh interval tag */}
          <span
            data-debug-id="agent-pane-interval-tag"
            className="rounded bg-white/10 px-1.5 py-0.5 text-[10px] font-mono text-zinc-400"
          >
            {intervalLabel}
          </span>
        </div>

        <div className="flex items-center gap-1">
          {/* Manual refresh button */}
          <button
            type="button"
            data-debug-id="agent-pane-refresh-btn"
            title="Refresh terminal output"
            aria-label="Refresh terminal output"
            onClick={() => refetch()}
            disabled={isLoading || isFetching}
            className="grid h-6 w-6 place-items-center rounded text-zinc-400 hover:bg-white/10 hover:text-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            <Icon name="refresh" size={12} className={isFetching ? 'animate-spin' : ''} />
          </button>

          {/* Collapse chevron */}
          {handleClose ? (
            <button
              type="button"
              data-debug-id="agent-pane-collapse-btn"
              title="Collapse terminal output"
              aria-label="Collapse terminal output"
              onClick={handleClose}
              className="grid h-6 w-6 place-items-center rounded text-zinc-400 hover:bg-white/10 hover:text-white"
            >
              <Icon name="chevron-down" size={14} />
            </button>
          ) : null}
        </div>
      </div>

      {/* Terminal Output content */}
      <pre
        ref={preRef}
        onScroll={handleScroll}
        data-debug-id="agent-pane-output"
        className="chat-scrollbar max-h-[300px] overflow-auto whitespace-pre-wrap p-3 font-mono text-xs leading-5 text-zinc-200"
      >
        {output || (isLoading ? 'Loading terminal output…' : '')}
      </pre>
    </div>
  );
}

export default AgentPaneComposerPanel;
