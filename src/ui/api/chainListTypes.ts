// Chain-list row shapes shared by the sidebar, home search, the chain selector
// and the command palette. Every row now comes from the owner registry
// (/api/v1/owner-local/chains, see ownerChains.ts ownerChainListItem): the Hub
// task-chain listing is gone.

export type ChainListItem = {
  chainId: string;
  title: string;
  status: string;
  kind?: string;
  updatedAt: string;
  coordinatorAgentInstanceId: string;
  projectId: string;
  projectName: string;
  taskCount: number;
  completedTaskCount: number;
  userValidationCount: number;
  hasUserValidation: boolean;
  isPinned: boolean;
  pinnedAt: string;
};

export type ChainProjectGroup = {
  projectId: string;
  projectName: string;
  chains: ChainListItem[];
  chainTotal: number;
  hasMore: boolean;
  nextCursor: string;
};
