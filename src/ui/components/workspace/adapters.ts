import { agentDetailChatDebug, chainCoordinatorChatDebug, conversationChatDebug } from '../chat/debugPrefixes';
import type { WorkspaceCapabilities, WorkspaceContext, WorkspaceGenericAgentDebugPlan, WorkspaceInspectorTabId } from './types';

function durableAgentId(agent: any) {
  return String(agent?.agentId || agent?.agent_id || agent?.id || '').split('@')[0] || '';
}

function visibleInspectorTabs(capabilities: WorkspaceCapabilities): WorkspaceInspectorTabId[] {
  const tabs: WorkspaceInspectorTabId[] = [];
  if (capabilities.canShowTasks) tabs.push('tasks');
  if (capabilities.canShowTaskChains) tabs.push('task-chains');
  if (capabilities.canShowChainAgents) tabs.push('chain-agents');
  if (capabilities.canShowArtifacts) tabs.push('artifacts');
  if (capabilities.canShowVcs) tabs.push('vcs');
  if (capabilities.canShowProject) tabs.push('project');
  if (capabilities.canShowMemory) tabs.push('memory');
  if (capabilities.canShowRuntime) tabs.push('runtime');
  return tabs;
}

function debugPlan(prefixes: {
  header?: string;
  messageList: string;
  workBanner: string;
  composer: string;
  upload: string;
  runtime: string;
  artifacts?: string;
}): WorkspaceGenericAgentDebugPlan {
  return {
    headerPrefix: prefixes.header || prefixes.messageList,
    messageListPrefix: prefixes.messageList,
    workBannerPrefix: prefixes.workBanner,
    composerPrefix: prefixes.composer,
    uploadPrefix: prefixes.upload,
    runtimePrefix: prefixes.runtime,
    artifactsPrefix: prefixes.artifacts || prefixes.messageList,
  };
}

export function adaptConversationWorkspaceContext({
  agent,
  title,
  projectName,
  live,
  runtimeLabel,
  provider,
  modelTier,
}: {
  agent: any;
  title: string;
  projectName: string;
  live: boolean;
  runtimeLabel: string;
  provider: string;
  modelTier: string;
}): WorkspaceContext {
  const capabilities: WorkspaceCapabilities = {
    canChat: true,
    canNudge: false,
    canInterrupt: false,
    canUploadArtifact: true,
    canChangeRuntime: true,
    canShowTasks: false,
    canShowTaskChains: false,
    canShowChainAgents: false,
    canShowArtifacts: true,
    canShowVcs: false,
    canShowProject: true,
    canShowMemory: false,
    canShowRuntime: true,
  };
  return {
    routeKind: 'conversation',
    surfaceKind: 'generic_agent',
    ids: {
      agentInstanceId: agent?.id || '',
      durableAgentId: durableAgentId(agent),
      projectId: agent?.projectId || '',
    },
    title,
    subtitle: agent?.id || 'conversation@s-…',
    projectName,
    statusLabel: live ? 'Active' : runtimeLabel,
    capabilities,
    visibleInspectorTabs: visibleInspectorTabs(capabilities),
    genericAgent: {
      agentPageKind: 'conversation',
      agentInstanceId: agent?.id || '',
      durableAgentId: durableAgentId(agent),
      displayName: title,
      title,
      subtitle: agent?.id || 'conversation@s-…',
      projectId: agent?.projectId || '',
      projectName,
      runtime: {
        status: live ? 'active' : 'stopped',
        statusLabel: live ? 'Active' : runtimeLabel,
        provider: provider || 'pi',
        modelTier: modelTier || 'smart',
        projectId: agent?.projectId || '',
        canStart: true,
        canStop: true,
        canRestart: true,
      },
      chat: {
        conversationKey: agent?.id || 'conversation-thread',
        emptyText: 'This thread is ready.',
        sendMode: 'message',
        supportsNudge: false,
        supportsInterrupt: false,
        supportsExactResumeCopy: true,
      },
      related: {
        taskIds: [],
        chainIds: [],
        artifactProjectId: agent?.projectId || '',
      },
      capabilities,
      debug: debugPlan(conversationChatDebug),
    },
  };
}

export function adaptDirectAgentWorkspaceContext({
  agent,
  tasksById,
  chainsById,
  runtimeLabel,
  live,
  provider,
  modelTier,
}: {
  agent: any;
  tasksById: Record<string, any>;
  chainsById: Record<string, any>;
  runtimeLabel: string;
  live: boolean;
  provider: string;
  modelTier: string;
}): WorkspaceContext {
  const taskIds = Object.values(tasksById || {}).filter((task: any) => {
    const assignee = task?.assigneeAgentInstanceId || task?.assignee_agent_instance_id || '';
    return assignee && assignee === agent?.id;
  }).map((task: any) => task.taskId).filter(Boolean);
  const chainIds = Array.from(new Set(taskIds.map((taskId) => tasksById?.[taskId]?.chainId).filter(Boolean)));
  const capabilities: WorkspaceCapabilities = {
    canChat: true,
    canNudge: true,
    canInterrupt: true,
    canUploadArtifact: true,
    canChangeRuntime: true,
    canShowTasks: true,
    canShowTaskChains: true,
    canShowChainAgents: false,
    canShowArtifacts: true,
    canShowVcs: false,
    canShowProject: true,
    canShowMemory: true,
    canShowRuntime: true,
  };
  return {
    routeKind: 'agent',
    surfaceKind: 'generic_agent',
    ids: {
      agentInstanceId: agent?.id || '',
      durableAgentId: durableAgentId(agent),
      projectId: agent?.projectId || '',
    },
    title: agent?.label || agent?.id || 'Agent',
    subtitle: agent?.id || 'agent@s-…',
    projectName: agent?.projectName || agent?.projectId || '',
    statusLabel: live ? 'Live' : runtimeLabel,
    capabilities,
    visibleInspectorTabs: visibleInspectorTabs(capabilities),
    genericAgent: {
      agentPageKind: 'direct_agent',
      agentInstanceId: agent?.id || '',
      durableAgentId: durableAgentId(agent),
      displayName: agent?.label || agent?.id || 'Agent',
      title: agent?.label || agent?.id || 'Agent',
      subtitle: agent?.id || 'agent@s-…',
      projectId: agent?.projectId || '',
      projectName: agent?.projectName || agent?.projectId || '',
      runtime: {
        status: live ? 'active' : 'stopped',
        statusLabel: live ? 'Live' : runtimeLabel,
        provider: provider || 'pi',
        modelTier: modelTier || 'normal',
        projectId: agent?.projectId || '',
        canStart: true,
        canStop: true,
        canRestart: true,
      },
      chat: {
        conversationKey: agent?.id || 'agent-detail',
        emptyText: 'No direct messages loaded for this agent.',
        sendMode: 'nudge',
        supportsNudge: true,
        supportsInterrupt: true,
        supportsExactResumeCopy: false,
      },
      related: {
        taskIds,
        chainIds: chainIds.filter((chainId) => Boolean(chainsById?.[chainId])),
        artifactProjectId: agent?.projectId || '',
      },
      capabilities,
      debug: debugPlan(agentDetailChatDebug),
    },
  };
}

export function adaptChainCoordinatorWorkspaceContext({
  chain,
  coordinatorAgent,
  coordinatorAgentId,
  taskIds,
  projectName,
  provider,
  modelTier,
  hasWorkspace,
  statusLabel,
}: {
  chain: any;
  coordinatorAgent: any;
  coordinatorAgentId: string;
  taskIds: string[];
  projectName: string;
  provider: string;
  modelTier: string;
  hasWorkspace: boolean;
  statusLabel: string;
}): WorkspaceContext {
  const capabilities: WorkspaceCapabilities = {
    canChat: true,
    canNudge: false,
    canInterrupt: false,
    canUploadArtifact: true,
    canChangeRuntime: false,
    canShowTasks: true,
    canShowTaskChains: false,
    canShowChainAgents: true,
    canShowArtifacts: true,
    canShowVcs: hasWorkspace,
    canShowProject: true,
    canShowMemory: false,
    canShowRuntime: Boolean(coordinatorAgentId),
  };
  return {
    routeKind: 'chain_coordinator',
    surfaceKind: 'generic_agent',
    ids: {
      agentInstanceId: coordinatorAgentId,
      durableAgentId: durableAgentId(coordinatorAgent) || 'coordinator',
      chainId: chain?.chainId || '',
      projectId: chain?.projectId || chain?.project_id || '',
    },
    title: chain?.title || chain?.chainId || 'Task chain',
    subtitle: coordinatorAgentId || 'unassigned coordinator',
    projectName,
    statusLabel: statusLabel || coordinatorAgent?.status || 'offline',
    capabilities,
    visibleInspectorTabs: visibleInspectorTabs(capabilities),
    genericAgent: {
      agentPageKind: 'chain_coordinator',
      agentInstanceId: coordinatorAgentId,
      durableAgentId: durableAgentId(coordinatorAgent) || 'coordinator',
      displayName: coordinatorAgent?.label || coordinatorAgentId || 'Coordinator',
      title: chain?.title || chain?.chainId || 'Task chain',
      subtitle: coordinatorAgentId || 'unassigned coordinator',
      projectId: chain?.projectId || chain?.project_id || '',
      projectName,
      chainId: chain?.chainId || '',
      chainTitle: chain?.title || chain?.chainId || '',
      runtime: {
        status: coordinatorAgent?.status || 'offline',
        statusLabel: statusLabel || coordinatorAgent?.status || 'offline',
        provider: provider || 'pi',
        modelTier: modelTier || 'normal',
        projectId: chain?.projectId || chain?.project_id || '',
        canStart: true,
        canStop: false,
        canRestart: false,
      },
      chat: {
        conversationKey: chain?.chainId || 'chain',
        emptyText: 'No coordinator messages yet.',
        sendMode: 'coordinator_message',
        supportsNudge: false,
        supportsInterrupt: false,
        supportsExactResumeCopy: false,
      },
      related: {
        taskIds,
        chainIds: chain?.chainId ? [chain.chainId] : [],
        artifactProjectId: chain?.projectId || chain?.project_id || '',
      },
      capabilities,
      debug: debugPlan(chainCoordinatorChatDebug),
    },
  };
}
