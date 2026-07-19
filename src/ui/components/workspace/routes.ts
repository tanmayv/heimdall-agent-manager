import type { WorkspaceRouteKind } from './types';

export type WorkspaceRoute =
  | { kind: 'workspace_home' }
  | { kind: 'conversation'; agentInstanceId: string }
  | { kind: 'agent'; agentInstanceId: string }
  | { kind: 'chain_coordinator'; chainId: string }
  | { kind: 'task'; chainId: string; taskId: string }
  | { kind: 'project'; projectId: string }
  | { kind: 'artifact'; artifactId: string };

export type WorkspaceUrlState = {
  view?: string;
  agentId?: string;
  taskId?: string;
  chainId?: string;
  memoryId?: string;
  projectId?: string;
};

function decodePathPart(value: string) {
  try {
    return decodeURIComponent(value);
  } catch (_err) {
    return value;
  }
}

function encodePathPart(value: string) {
  return encodeURIComponent(value);
}

export function parseWorkspaceRoute(pathname: string): WorkspaceRoute | null {
  const parts = String(pathname || '').split('/').filter(Boolean).map(decodePathPart);
  if (parts[0] !== 'workspace') return null;
  if (parts.length === 1) return { kind: 'workspace_home' };
  if (parts[1] === 'conversations' && parts[2]) return { kind: 'conversation', agentInstanceId: parts[2] };
  if (parts[1] === 'agents' && parts[2]) return { kind: 'agent', agentInstanceId: parts[2] };
  if (parts[1] === 'chains' && parts[2] && parts[3] === 'coordinator') return { kind: 'chain_coordinator', chainId: parts[2] };
  if (parts[1] === 'chains' && parts[2] && parts[3] === 'tasks' && parts[4]) return { kind: 'task', chainId: parts[2], taskId: parts[4] };
  if (parts[1] === 'projects' && parts[2]) return { kind: 'project', projectId: parts[2] };
  if (parts[1] === 'artifacts' && parts[2]) return { kind: 'artifact', artifactId: parts[2] };
  return null;
}

export function buildWorkspacePath(route: WorkspaceRoute): string {
  switch (route.kind) {
    case 'workspace_home':
      return '/workspace';
    case 'conversation':
      return `/workspace/conversations/${encodePathPart(route.agentInstanceId)}`;
    case 'agent':
      return `/workspace/agents/${encodePathPart(route.agentInstanceId)}`;
    case 'chain_coordinator':
      return `/workspace/chains/${encodePathPart(route.chainId)}/coordinator`;
    case 'task':
      return `/workspace/chains/${encodePathPart(route.chainId)}/tasks/${encodePathPart(route.taskId)}`;
    case 'project':
      return `/workspace/projects/${encodePathPart(route.projectId)}`;
    case 'artifact':
      return `/workspace/artifacts/${encodePathPart(route.artifactId)}`;
  }
}

export function workspaceRouteToUrlState(route: WorkspaceRoute): WorkspaceUrlState {
  switch (route.kind) {
    case 'workspace_home':
      return { view: 'home' };
    case 'conversation':
      return { view: 'conversation', agentId: route.agentInstanceId, chainId: '', taskId: '', memoryId: '' };
    case 'agent':
      return { view: 'agent', agentId: route.agentInstanceId, chainId: '', taskId: '', memoryId: '' };
    case 'chain_coordinator':
      return { view: 'chain', chainId: route.chainId, agentId: '', taskId: '', memoryId: '' };
    case 'task':
      return { view: 'chain', chainId: route.chainId, taskId: route.taskId, agentId: '', memoryId: '' };
    case 'project':
      return { view: 'home', projectId: route.projectId };
    case 'artifact':
      return { view: 'home' };
  }
}

export function workspaceRouteKindForUrlState(state: WorkspaceUrlState): WorkspaceRouteKind | null {
  const view = String(state.view || '');
  if (view === 'home') return 'workspace_home';
  if (view === 'conversation' && state.agentId) return 'conversation';
  if (view === 'agent' && state.agentId) return 'agent';
  if (view === 'chain' && state.chainId && state.taskId) return 'task';
  if (view === 'chain' && state.chainId) return 'chain_coordinator';
  return null;
}

export function urlStateToWorkspaceRoute(state: WorkspaceUrlState): WorkspaceRoute | null {
  const kind = workspaceRouteKindForUrlState(state);
  switch (kind) {
    case 'workspace_home':
      return { kind };
    case 'conversation':
      return state.agentId ? { kind, agentInstanceId: state.agentId } : null;
    case 'agent':
      return state.agentId ? { kind, agentInstanceId: state.agentId } : null;
    case 'chain_coordinator':
      return state.chainId ? { kind, chainId: state.chainId } : null;
    case 'task':
      return state.chainId && state.taskId ? { kind, chainId: state.chainId, taskId: state.taskId } : null;
    default:
      return null;
  }
}
