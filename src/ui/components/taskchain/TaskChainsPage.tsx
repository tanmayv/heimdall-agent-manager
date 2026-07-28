import React, { useState, useEffect } from 'react';
import { TaskChainOverview } from './TaskChainOverview';

interface TaskChainsPageProps {
  chainId?: string;
  isMobile?: boolean;
}

export const TaskChainsPage: React.FC<TaskChainsPageProps> = ({ chainId: initialChainId, isMobile }) => {
  const [selectedChainId, setSelectedChainId] = useState<string>(initialChainId || '');

  useEffect(() => {
    setSelectedChainId(initialChainId || '');
  }, [initialChainId]);

  if (selectedChainId) {
    return (
      <div className="h-full w-full">
        <TaskChainOverview
          chainId={selectedChainId}
          onClose={() => setSelectedChainId('')}
          isMobile={isMobile}
        />
      </div>
    );
  }

  return (
    <div data-debug-id="task-chains-page" className="w-full max-w-4xl p-6 text-left">
      <h1 className="text-2xl font-bold text-white">Task Chains</h1>
      <p className="mt-2 text-sm text-zinc-400">
        Task Chains manage complex multi-agent workflows with owner-scoped tasks, dependencies, membership, and reviewer votes.
      </p>
      <div className="mt-6 rounded-2xl border border-white/10 bg-white/[0.03] p-6 text-sm text-zinc-300">
        Select a conversation with an active Task Chain or navigate to a chain ID hash:
        <span className="ml-2 font-mono text-sky-400">#/chains/&lt;chainId&gt;</span>
      </div>
    </div>
  );
};

export default TaskChainsPage;
