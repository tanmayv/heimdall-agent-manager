import type { KeyboardEvent, ReactNode, RefObject } from 'react';
import type { ChatMessage, ChatDeliveryStatus, ChatTimestamp } from '../chat/types';

export type WorkspaceRouteKind = 'workspace_home' | 'conversation' | 'agent' | 'chain_coordinator' | 'task' | 'project' | 'artifact';

export type WorkspaceSurfaceKind = 'workspace_home' | 'generic_agent' | 'task_detail' | 'project_overview' | 'artifact_viewer';

export type WorkspaceInspectorTabId = 'tasks' | 'task-chains' | 'chain-agents' | 'artifacts' | 'vcs' | 'project' | 'memory' | 'runtime' | string;

export type WorkspaceCapabilities = {
  canChat: boolean;
  canNudge: boolean;
  canInterrupt: boolean;
  canUploadArtifact: boolean;
  canChangeRuntime: boolean;
  canShowTasks: boolean;
  canShowTaskChains: boolean;
  canShowChainAgents: boolean;
  canShowArtifacts: boolean;
  canShowVcs: boolean;
  canShowProject: boolean;
  canShowMemory: boolean;
  canShowRuntime: boolean;
};

export type WorkspaceIdentityRef = {
  agentInstanceId?: string;
  durableAgentId?: string;
  chainId?: string;
  taskId?: string;
  projectId?: string;
  artifactId?: string;
};

export type WorkspaceGenericAgentDebugPlan = {
  headerPrefix: string;
  messageListPrefix: string;
  workBannerPrefix: string;
  composerPrefix: string;
  uploadPrefix: string;
  runtimePrefix: string;
  artifactsPrefix: string;
};

export type WorkspaceSelectedAgentContext = {
  agentPageKind: 'conversation' | 'direct_agent' | 'chain_coordinator';
  agentInstanceId: string;
  durableAgentId: string;
  displayName: string;
  title: string;
  subtitle: string;
  projectId?: string;
  projectName?: string;
  chainId?: string;
  chainTitle?: string;
  runtime: {
    status: string;
    statusLabel: string;
    provider: string;
    modelTier: string;
    projectId?: string;
    canStart: boolean;
    canStop: boolean;
    canRestart: boolean;
  };
  chat: {
    conversationKey: string;
    emptyText: string;
    sendMode: 'message' | 'nudge' | 'coordinator_message';
    supportsNudge: boolean;
    supportsInterrupt: boolean;
    supportsExactResumeCopy: boolean;
  };
  related: {
    taskIds: string[];
    chainIds: string[];
    artifactProjectId?: string;
  };
  capabilities: WorkspaceCapabilities;
  debug: WorkspaceGenericAgentDebugPlan;
};

export type WorkspaceContext = {
  routeKind: WorkspaceRouteKind;
  surfaceKind: WorkspaceSurfaceKind;
  ids: WorkspaceIdentityRef;
  title: string;
  subtitle?: string;
  breadcrumbLabel?: string;
  statusLabel?: string;
  projectName?: string;
  capabilities: WorkspaceCapabilities;
  visibleInspectorTabs: WorkspaceInspectorTabId[];
  genericAgent?: WorkspaceSelectedAgentContext;
};

export type WorkspaceInspectorTab = {
  id: WorkspaceInspectorTabId;
  label: ReactNode;
  content: ReactNode;
  hidden?: boolean;
  disabled?: boolean;
  badge?: ReactNode;
  buttonDebugId?: string;
  panelDebugId?: string;
};

export type WorkspaceGenericAgentHeader = {
  className?: string;
  left?: ReactNode;
  title: ReactNode;
  subtitle?: ReactNode;
  status?: ReactNode;
  actions?: ReactNode;
  bottom?: ReactNode;
};

export type WorkspaceGenericAgentChat = {
  conversationKey: string;
  messages: ChatMessage[];
  debugPrefix: string;
  emptyText?: string;
  emptyState?: ReactNode;
  hasMore?: boolean;
  loadingOlder?: boolean;
  onLoadOlder?: () => void;
  onReply?: (reply: string) => void;
  renderMessageTop?: (args: { message: ChatMessage; index: number; messages: ChatMessage[] }) => ReactNode;
  renderMessageBody?: (args: { message: ChatMessage; onReply: (reply: string) => void }) => ReactNode;
  formatTimestamp?: (unixMs: number) => ChatTimestamp;
  getDeliveryStatus?: (message: ChatMessage) => ChatDeliveryStatus;
  wrapperClassName?: string;
  scrollClassName?: string;
};

export type WorkspaceGenericAgentBanner = {
  agent: any;
  tasksById?: Record<string, any>;
  debugPrefix: string;
  onStart?: () => void;
  startDisabled?: boolean;
};

export type WorkspaceGenericAgentComposer = {
  shellDebugId: string;
  inputDebugId: string;
  sendButtonDebugId: string;
  sendAriaLabel: string;
  value: string;
  onValueChange: (value: string) => void;
  onSubmit: () => void | Promise<void>;
  onPaste?: (event: any) => void | Promise<void>;
  onKeyDown?: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  inputRef?: RefObject<HTMLTextAreaElement | null>;
  placeholder: string;
  rows?: number;
  autoFocus?: boolean;
  sendTitle?: string;
  sendDisabled?: boolean;
  sendLabel?: ReactNode;
  sendError?: string;
  sendErrorDebugId?: string;
  uploadErrorDebugId?: string;
  upload?: any;
  runtimeControls?: any;
  notices?: Array<{ debugId: string; message: ReactNode; tone?: 'error' | 'info' | 'neutral' }>;
  leftAdornment?: ReactNode;
  footer?: ReactNode;
  keyboardHint?: ReactNode;
  shellClassName?: string;
  textareaClassName?: string;
  controlsClassName?: string;
  footerClassName?: string;
};

export type WorkspaceGenericAgentContext = {
  header: WorkspaceGenericAgentHeader;
  chat: WorkspaceGenericAgentChat;
  workBanner?: WorkspaceGenericAgentBanner | null;
  composer?: WorkspaceGenericAgentComposer | null;
  className?: string;
  bodyClassName?: string;
  bodyInnerClassName?: string;
  composerContainerClassName?: string;
};
