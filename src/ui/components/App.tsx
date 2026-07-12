import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import SettingsPage from './SettingsPage';
import {
  addDaemonProfile,
  agentLifecycleEventReceived,
  agentRuntimeEventReceived,
  appendMessage,
  GUIDE_AGENT_ID,
  chatEventReceived,
  closeGuidePanel,
  fetchGuideChat,
  fetchPreferences,
  fetchSelectedChat,
  refreshAgents,
  registerSession,
  removeDaemonProfile,
  renameDaemonProfile,
  sendGuideMessage,
  toggleGuidePanel,
  updateSessionConfig,
  userWsConnected,
  userWsConnecting,
  userWsDisconnected,
  userWsError,
} from '../store/chatSlice';
import { addCommentToSelectedTask, fetchSelectedTaskLog, fetchTasksForChain, nudgeSelectedTask, refreshTaskBoard, taskEventReceived, updateChainStateDirectly, updateSelectedTaskStatus, updateTaskStateDirectly, voteOnAttentionTask, voteOnSelectedTask } from '../store/taskSlice';
import { clearProjectError, createProjectFromUi, refreshProjects } from '../store/projectSlice';
import {
  closeNewChainModal,
  httpLoadCompleted,
  openNewChainModal,
  selectChain,
  selectProject,
  selectSurface,
  submitNewChain,
  wsRefreshRequested,
} from '../store/homeSlice';
import {
  closeAgentSideSheet,
  focusChainView,
  fetchWorkspaceForChain,
  loadAgentSideSheet,
  optimisticCoordinatorMessage,
  openAgentSideSheet,
  previewWorkspaceMerge,
  revalidateChainView,
  sendCoordinatorMessage,
  toggleWorkspaceDiff,
  wsChainViewRefreshRequested,
} from '../store/chainViewSlice';
import { answerChatApproval, chatApprovalEventReceived, dismissChatApproval, refreshChatApprovals, tickChatApprovalExpiry } from '../store/attentionSlice';
import { refreshMemory, decideMemoryProposal } from '../store/memorySlice';
import { dismissToast, showToast } from '../store/toastSlice';
import Markdown from './Markdown';
import { updateUrlParams } from './useUrlParams';

type Chain = {
  chainId: string;
  title: string;
  status: string;
  projectId?: string;
  coordinatorAgentInstanceId?: string;
  teamId?: string;
};

type Project = {
  projectId: string;
  name: string;
  description?: string;
};

const EMPTY: any[] = [];
const PERIODIC_REVALIDATE_MS = 30000;

function statusTone(status: string) {
  if (status === 'completed' || status === 'approved') return 'bg-emerald-500/15 text-emerald-200 border-emerald-500/30';
  if (status === 'blocked' || status === 'paused') return 'bg-amber-500/15 text-amber-200 border-amber-500/30';
  if (status === 'reviewing' || status === 'review_ready') return 'bg-sky-500/15 text-sky-200 border-sky-500/30';
  if (status === 'planning') return 'bg-violet-500/15 text-violet-200 border-violet-500/30';
  if (status === 'in_progress' || status === 'active') return 'bg-teal-500/15 text-teal-200 border-teal-500/30';
  if (status === 'archived' || status === 'cancelled' || status === 'abandoned') return 'bg-zinc-700/40 text-zinc-400 border-zinc-600/40';
  return 'bg-zinc-500/15 text-zinc-200 border-zinc-500/30';
}

const COMPLETED_CHAIN_STATUSES = new Set(['completed', 'approved', 'archived', 'cancelled', 'abandoned']);

function isChainCompleted(chain: any): boolean {
  if (!chain) return false;
  if (chain.archived) return true;
  return COMPLETED_CHAIN_STATUSES.has(String(chain.status || ''));
}

type AgentAssignment = {
  role: 'assigned' | 'reviewing';
  taskId: string;
  taskTitle: string;
  taskStatus: string;
  chainId: string;
  chainTitle: string;
  chainStatus: string;
  chainDescription: string;
  updatedAtUnixMs: number;
  blockedOnTaskIds: string[];
};

function parseDependsOn(value: any): string[] {
  if (!value) return [];
  return String(value).split(',').map((id) => id.trim()).filter(Boolean);
}

function unmetDependencyIds(task: any, tasksById: Record<string, any>): string[] {
  const deps = parseDependsOn(task?.dependsOn);
  if (deps.length === 0) return [];
  return deps.filter((id) => {
    const dep = tasksById?.[id];
    if (!dep) return true; // unknown dep is treated as blocking
    return dep.status !== 'approved' && dep.status !== 'done' && dep.status !== 'completed';
  });
}

function assignmentPriority(status: string, role: 'assigned' | 'reviewing'): number {
  if (role === 'reviewing') {
    if (status === 'review_ready') return 0;
    return 2;
  }
  if (status === 'in_progress') return 0;
  if (status === 'blocked') return 1;
  if (status === 'queued' || status === 'ready' || status === 'planning') return 3;
  return 4;
}

function collectAgentAssignments(agent: any, tasksById: Record<string, any>, chainsById: Record<string, any>): AgentAssignment[] {
  if (!agent || !agent.id) return [];
  const agentId = String(agent.id);
  const results: AgentAssignment[] = [];
  for (const raw of Object.values(tasksById || {})) {
    const task = raw as any;
    if (!task || !task.status) continue;
    if (task.status === 'approved' || task.status === 'cancelled' || task.status === 'archived') continue;
    let role: 'assigned' | 'reviewing' | null = null;
    if (task.assigneeAgentInstanceId === agentId) role = 'assigned';
    if (!role && task.status === 'review_ready') {
      const reviewers = task.participants || [];
      const isReviewer = reviewers.some((p: any) => p.role === 'lgtm_required' && p.agentInstanceId === agentId) || task.reviewerAgentInstanceId === agentId;
      if (isReviewer) role = 'reviewing';
    }
    if (!role) continue;
    const chain = chainsById?.[task.chainId] || {};
    results.push({
      role,
      taskId: task.taskId,
      taskTitle: task.title || task.taskId,
      taskStatus: task.status,
      chainId: task.chainId || '',
      chainTitle: chain.title || task.chainId || '',
      chainStatus: chain.status || '',
      chainDescription: (chain.description || '').trim(),
      updatedAtUnixMs: Number(task.updatedAtUnixMs || task.createdAtUnixMs || 0),
      blockedOnTaskIds: unmetDependencyIds(task, tasksById || {}),
    });
  }
  results.sort((a, b) => {
    const ap = assignmentPriority(a.taskStatus, a.role);
    const bp = assignmentPriority(b.taskStatus, b.role);
    if (ap !== bp) return ap - bp;
    return (b.updatedAtUnixMs || 0) - (a.updatedAtUnixMs || 0);
  });
  return results.slice(0, 1);
}

export function agentRuntimeDot(agent: any): { color: string; label: string } {
  if (!agent) return { color: 'bg-zinc-500', label: 'unknown' };
  const startup = String(agent.startupStatus || '').toLowerCase();
  const state = String(agent.state || agent.status || '').toLowerCase();
  const activity = String(agent.activityStatus || agent.activity_status || '').toLowerCase();
  const blocked = agent.blockedReason || state === 'blocked' || startup === 'startup_blocked' || startup === 'blocked';
  const live = Boolean(agent.connected || startup === 'ready' || state === 'ready' || state === 'live' || state === 'connected' || state === 'idle');
  if (blocked) return { color: 'bg-red-400', label: 'blocked' };
  if (startup === 'startup_failed' || startup === 'startup_unknown') return { color: startup === 'startup_failed' ? 'bg-red-400' : 'bg-violet-400', label: startup.replace('startup_', '') };
  if (state === 'missing' || state === 'archived') return { color: 'bg-zinc-500', label: state };
  if (state === 'disconnected' || state === 'offline' || state === 'stopped') return { color: 'bg-zinc-500', label: state };
  if (startup === 'starting' || state === 'starting' || state === 'warming' || state === 'restarting') return { color: 'bg-amber-400 animate-pulse', label: startup || state || 'starting' };
  if (live && activity === 'active') return { color: 'bg-emerald-400', label: 'active' };
  if (live && activity === 'idle') return { color: 'bg-amber-300', label: 'idle' };
  if (live && agent.currentTaskId) return { color: 'bg-teal-400', label: 'working' };
  if (live) return { color: 'bg-emerald-400', label: state || 'connected' };
  return { color: 'bg-zinc-500', label: state || startup || 'unknown' };
}

function chainStatusAccent(status: string) {
  if (status === 'completed' || status === 'approved') return { dot: 'bg-emerald-400', ring: 'ring-emerald-400/40', border: 'border-l-emerald-400/70' };
  if (status === 'blocked' || status === 'paused') return { dot: 'bg-amber-400', ring: 'ring-amber-400/40', border: 'border-l-amber-400/70' };
  if (status === 'reviewing' || status === 'review_ready') return { dot: 'bg-sky-400', ring: 'ring-sky-400/40', border: 'border-l-sky-400/70' };
  if (status === 'planning') return { dot: 'bg-violet-400', ring: 'ring-violet-400/40', border: 'border-l-violet-400/70' };
  if (status === 'in_progress' || status === 'active') return { dot: 'bg-teal-400', ring: 'ring-teal-400/40', border: 'border-l-teal-400/70' };
  if (status === 'archived' || status === 'cancelled' || status === 'abandoned') return { dot: 'bg-zinc-500', ring: 'ring-zinc-500/40', border: 'border-l-zinc-600/70' };
  return { dot: 'bg-zinc-400', ring: 'ring-zinc-400/40', border: 'border-l-zinc-500/70' };
}

function shortenPath(path: string, max = 42): string {
  if (!path) return '';
  const homeReplaced = path.startsWith('/Users/') || path.startsWith('/home/')
    ? path.replace(/^\/(?:Users|home)\/[^/]+/, '~')
    : path;
  if (homeReplaced.length <= max) return homeReplaced;
  const tail = homeReplaced.slice(-Math.max(8, max - 5));
  return `…${tail}`;
}

function vcsIconForKind(kind: string): { icon: string; label: string; tone: string } {
  const value = (kind || '').toLowerCase();
  // Treat empty and "auto" as an unresolved detection hint. The daemon resolves
  // the concrete backend at chain time; the sidebar assumes Git for display
  // since it is the default and only currently-supported concrete backend.
  if (value === '' || value === 'auto') return { icon: 'git', label: 'Git (auto-detected)', tone: 'text-orange-300 border-orange-400/40' };
  if (value === 'git') return { icon: 'git', label: 'Git', tone: 'text-orange-300 border-orange-400/40' };
  if (value === 'jj' || value === 'jujutsu') return { icon: 'jj', label: 'Jujutsu', tone: 'text-fuchsia-300 border-fuchsia-400/40' };
  if (value === 'hg' || value === 'mercurial') return { icon: 'hg', label: 'Mercurial', tone: 'text-emerald-300 border-emerald-400/40' };
  if (value === 'sapling' || value === 'sl') return { icon: 'sl', label: 'Sapling', tone: 'text-lime-300 border-lime-400/40' };
  if (value === 'svn') return { icon: 'svn', label: 'Subversion', tone: 'text-sky-300 border-sky-400/40' };
  if (value === 'none') return { icon: 'dir', label: 'No VCS', tone: 'text-zinc-400 border-zinc-500/40' };
  return { icon: kind.slice(0, 3) || 'vcs', label: kind, tone: 'text-zinc-300 border-zinc-500/40' };
}

function chainProjectId(chain: Chain) {
  return chain.projectId || 'default';
}

function chainMeta(chainId: string, chainTaskIds: Record<string, string[]>, tasksById: Record<string, any>) {
  const ids = chainTaskIds[chainId] || [];
  const tasks = ids.map((id) => tasksById[id]).filter(Boolean);
  const done = tasks.filter((t) => ['approved', 'done', 'completed'].includes(t.status)).length;
  const blocked = tasks.filter((t) => t.status === 'blocked').length;
  const reviewReady = tasks.filter((t) => t.status === 'review_ready').length;
  return `${done} / ${tasks.length} done · ${blocked} blocked · ${reviewReady} review-ready`;
}

function isUserActionableTask(task: any): boolean {
  if (!task) return false;
  if (task.status === 'review_ready') {
    return (task.participants || []).some((p: any) => p.agentInstanceId === 'user_proxy' && p.role === 'lgtm_required');
  }
  if (task.status === 'blocked') {
    const reason = String(task.notActionableReason || '');
    if (reason.startsWith('awaiting_user')) return true;
    if (reason.startsWith('manual_block:') && /operator|user/i.test(reason)) return true;
    return false;
  }
  return false;
}

function attentionCount(tasksById: Record<string, any>, attention: any, pendingMemoryIds: number, mergeReviewingChains: number) {
  const tasks = Object.values(tasksById).filter(isUserActionableTask).length;
  const chatApprovals = (attention?.chatApprovalIds || []).filter((id: string) => attention.chatApprovalsById?.[id]?.kind !== 'multi_question').length;
  return tasks + chatApprovals + pendingMemoryIds + mergeReviewingChains;
}

export default function App() {
  const dispatch = useDispatch<any>();
  const { agents, session, daemonProfiles, selectedAgentId, chats, guidePanelOpen, guideSending, fetchingChatsByAgentId } = useSelector((state: any) => state.chat);
  const { projectsById, projectIds, mutating: projectMutating, error: projectError } = useSelector((state: any) => state.projects);
  const { chainsById, tasksById, chainTaskIds, taskLogsByTaskId, loading } = useSelector((state: any) => state.tasks);
  const home = useSelector((state: any) => state.home);
  const chainView = useSelector((state: any) => state.chainView);
  const sessionRef = useRef(session);
  const chainViewRef = useRef(chainView);
  const chainsByIdRef = useRef(chainsById);
  const selectedAgentRef = useRef(selectedAgentId);
  const [newProjectModalOpen, setNewProjectModalOpen] = useState(false);
  const [chainCreationProgress, setChainCreationProgress] = useState<any>(null);
  const [daemonPickerOpen, setDaemonPickerOpen] = useState(false);
  const [daemonModalMode, setDaemonModalMode] = useState<null | 'add' | 'rename' | 'connect_failed'>(null);
  const [daemonModalContext, setDaemonModalContext] = useState<{ url?: string; label?: string }>({});
  const connectAttemptsRef = useRef(0);
  const firstRunPromptedRef = useRef(false);
  const [collapsedProjectIds, setCollapsedProjectIds] = useState<Record<string, boolean>>(() => {
    try {
      const raw = window.localStorage.getItem('heimdall.sidebar.collapsedProjects');
      return raw ? JSON.parse(raw) : {};
    } catch (_err) { return {}; }
  });
  const toggleProjectCollapsed = useCallback((projectId: string) => {
    setCollapsedProjectIds((prev) => {
      const next = { ...prev, [projectId]: !prev[projectId] };
      try { window.localStorage.setItem('heimdall.sidebar.collapsedProjects', JSON.stringify(next)); } catch (_err) { /* ignore */ }
      return next;
    });
  }, []);
  useEffect(() => { sessionRef.current = session; }, [session]);
  useEffect(() => { chainViewRef.current = chainView; }, [chainView]);
  useEffect(() => { chainsByIdRef.current = chainsById; }, [chainsById]);
  useEffect(() => { selectedAgentRef.current = selectedAgentId; }, [selectedAgentId]);

  const projects: Project[] = useMemo(() => {
    const known = projectIds.map((id: string) => projectsById[id]).filter(Boolean);
    if (known.length > 0) return known;
    return [{ projectId: 'default', name: 'Default project', description: 'Chains without an explicit project.' }];
  }, [projectIds, projectsById]);

  const chains: Chain[] = useMemo(() => Object.values(chainsById || {}) as Chain[], [chainsById]);
  const selectedProjectId = home.selectedProjectId || projects[0]?.projectId || 'default';
  const selectedChain = home.selectedChainId ? chainsById[home.selectedChainId] : null;
  const unreadByAgentId = useMemo(() => {
    const byId: Record<string, number> = {};
    for (const agent of agents || []) {
      if (!agent?.id) continue;
      byId[agent.id] = Number(agent.unreadCount || 0);
    }
    return byId;
  }, [agents]);
  const guideAgent = useMemo(() => (agents || []).find((agent: any) => agent.id === GUIDE_AGENT_ID) || null, [agents]);
  const guideUnread = Number(guideAgent?.unreadCount || unreadByAgentId[GUIDE_AGENT_ID] || 0);
  const guideMessages = useMemo(() => normalizeCoordinatorMessages((chats?.[GUIDE_AGENT_ID] || []).map((msg: any) => ({
    message_id: msg.id,
    id: msg.id,
    direction: msg.author === 'user' ? 'user_to_agent' : 'agent_to_user',
    body: msg.body,
    createdUnixMs: msg.createdUnixMs || 0,
    deliveredUnixMs: msg.deliveredUnixMs || 0,
    readUnixMs: msg.readUnixMs || 0,
    deliveryFailedUnixMs: msg.deliveryFailedUnixMs || 0,
    deliveryError: msg.deliveryError || (msg.error ? 'delivery failed' : ''),
    sending: Boolean(msg.sending),
    agentInstanceId: GUIDE_AGENT_ID,
  }))), [chats]);
  const guideLoading = Boolean(fetchingChatsByAgentId?.[GUIDE_AGENT_ID]);
  const attention = useSelector((state: any) => state.attention);
  const memory = useSelector((state: any) => state.memory);
  const toasts = useSelector((state: any) => state.toasts?.toasts || []);
  const pendingMemoryIds = useMemo(() => (memory?.recordIds || []).filter((id: string) => memory.recordsById?.[id]?.status === 'pending').length, [memory?.recordIds, memory?.recordsById]);
  const mergeReviewingChains = useMemo(() => (Object.values(chainsById || {}) as any[]).filter((chain) => chain?.status === 'reviewing').length, [chainsById]);
  const badgeCount = attentionCount(tasksById || {}, attention, pendingMemoryIds, mergeReviewingChains);

  const loadHomeData = useCallback(async (periodic = false, reason = 'startup') => {
    const result = await dispatch(refreshTaskBoard()).unwrap().catch(() => null);
    await Promise.all([
      dispatch(refreshProjects()).catch(() => undefined),
      dispatch(refreshAgents()).catch(() => undefined),
      dispatch(fetchPreferences()).catch(() => undefined),
    ]);
    const chainIds = (result?.chains || []).map((chain: any) => chain.chainId).filter(Boolean);
    await Promise.all(chainIds.slice(0, 20).map((chainId: string) => dispatch(fetchTasksForChain(chainId)).catch(() => undefined)));
    dispatch(httpLoadCompleted({ at: Date.now(), periodic, reason }));
  }, [dispatch]);

  const connectSession = useCallback((attempt = 0) => {
    connectAttemptsRef.current = attempt;
    dispatch(registerSession())
      .unwrap()
      .then(() => {
        connectAttemptsRef.current = 0;
        setDaemonModalMode((current) => (current === 'connect_failed' ? null : current));
        loadHomeData(false, attempt ? `startup-retry-${attempt}` : 'startup');
      })
      .catch(() => {
        if (attempt < 5) {
          window.setTimeout(() => connectSession(attempt + 1), 750);
        } else {
          setDaemonModalMode('connect_failed');
          setDaemonModalContext({ url: sessionRef.current?.daemonUrl || '' });
        }
      });
  }, [dispatch, loadHomeData]);

  useEffect(() => { connectSession(); }, [connectSession]);
  useEffect(() => {
    if (!guidePanelOpen || !session.connected) return undefined;
    dispatch(fetchGuideChat()).catch(() => undefined);
    dispatch(refreshAgents()).catch(() => undefined);
    const interval = window.setInterval(() => {
      dispatch(fetchGuideChat()).catch(() => undefined);
      dispatch(refreshAgents()).catch(() => undefined);
    }, 10000);
    return () => window.clearInterval(interval);
  }, [dispatch, guidePanelOpen, session.connected]);
  useEffect(() => {
    if (firstRunPromptedRef.current) return;
    let hasStoredProfiles = false;
    try {
      const raw = window.localStorage.getItem('odin.daemonProfiles');
      hasStoredProfiles = Boolean(raw && raw !== '[]');
    } catch (_err) {
      hasStoredProfiles = false;
    }
    if (!hasStoredProfiles) {
      firstRunPromptedRef.current = true;
      setDaemonModalMode('add');
      setDaemonModalContext({ url: sessionRef.current?.daemonUrl || '', label: 'Local daemon' });
    }
  }, []);

  const openAddDaemonModal = useCallback((prefill?: { url?: string; label?: string }) => {
    setDaemonModalMode('add');
    setDaemonModalContext(prefill || {});
    setDaemonPickerOpen(false);
  }, []);
  const openRenameDaemonModal = useCallback((profile: any) => {
    setDaemonModalMode('rename');
    setDaemonModalContext({ url: profile?.url || '', label: profile?.label || '' });
    setDaemonPickerOpen(false);
  }, []);
  const closeDaemonModal = useCallback(() => {
    setDaemonModalMode(null);
    setDaemonModalContext({});
  }, []);
  const switchDaemonProfile = useCallback((profile: any) => {
    setDaemonPickerOpen(false);
    if (!profile?.url) return;
    if (profile.url === session.daemonUrl) return;
    dispatch(updateSessionConfig({ daemonUrl: profile.url, userId: session.userId }));
    window.setTimeout(() => connectSession(0), 0);
  }, [dispatch, connectSession, session.daemonUrl, session.userId]);

  useEffect(() => {
    if (!session.connected) return undefined;
    const periodic = window.setInterval(() => loadHomeData(true, 'periodic'), PERIODIC_REVALIDATE_MS);
    const onFocus = () => loadHomeData(false, 'focus');
    const onVisibility = () => { if (document.visibilityState === 'visible') loadHomeData(false, 'visibility'); };
    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      window.clearInterval(periodic);
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [loadHomeData, session.connected]);

  useEffect(() => {
    if (!session.connected || !session.clientToken || !session.clientInstanceId) return undefined;
    let socket: WebSocket | null = null;
    let reconnectTimer: number | undefined;
    let stopped = false;
    const connect = () => {
      if (stopped) return;
      const current = sessionRef.current;
      if (!current.clientToken || !current.clientInstanceId) return;
      dispatch(userWsConnecting());
      const wsBaseUrl = current.daemonUrl.replace(/^http/i, 'ws').replace(/\/$/, '');
      socket = new WebSocket(`${wsBaseUrl}/user-ws/${encodeURIComponent(current.clientInstanceId)}?client_token=${encodeURIComponent(current.clientToken)}`);
      socket.onopen = () => {
        dispatch(userWsConnected());
        dispatch(wsRefreshRequested('user_ws_connected'));
        dispatch(refreshAgents());
        const selected = selectedAgentRef.current;
        if (selected) {
          dispatch(fetchSelectedChat({ agentId: selected }));
        }
        loadHomeData(false, 'user_ws_connected').catch(() => undefined);
      };
      socket.onmessage = (event) => {
        let payload: any;
        try { payload = JSON.parse(event.data); } catch { return; }
        if (payload?.type === 'task_event') {
          dispatch(taskEventReceived(payload));
          if (payload.task) dispatch(updateTaskStateDirectly(payload.task));
          if (payload.chain) dispatch(updateChainStateDirectly(payload.chain));
          const chainId = payload.chain_id || payload.chain?.chain_id || payload.task?.chain_id;
          dispatch(wsRefreshRequested(`task_event:${chainId || 'all'}`));
          const focused = chainViewRef.current.focusedChainId;
          if (chainId) {
            dispatch(fetchTasksForChain(chainId));
            if (focused === chainId) {
              dispatch(wsChainViewRefreshRequested(`task_event:${chainId}`));
              dispatch(revalidateChainView(chainId));
            }
          }
          else dispatch(refreshTaskBoard());
          return;
        }
        if (payload?.type === 'chat_event') {
          dispatch(chatEventReceived(payload));
          const agentId = payload.agent_instance_id || '';
          const focused = chainViewRef.current.focusedChainId;
          const focusedChain = focused ? chainsByIdRef.current[focused] : null;
          const eventChainId = payload.chain_id || '';
          if (focused && eventChainId && focused === eventChainId) {
            dispatch(wsChainViewRefreshRequested(`chat_event:${eventChainId}:${payload.message_id || ''}`));
            dispatch(revalidateChainView(focused));
          } else if (focused && !eventChainId && focusedChain?.coordinatorAgentInstanceId === agentId) {
            dispatch(wsChainViewRefreshRequested(`chat_event:${payload.message_id || ''}`));
            dispatch(revalidateChainView(focused));
          }
          const selectedDirectAgent = selectedAgentRef.current;
          if (selectedDirectAgent && selectedDirectAgent === agentId) {
            if (payload.message) {
              dispatch(appendMessage({ agentId, message: payload.message }));
            } else {
              dispatch(fetchSelectedChat({ agentId: selectedDirectAgent }));
            }
          }
          return;
        }
        if (payload?.type === 'chat_approval') {
          dispatch(chatApprovalEventReceived(payload));
          return;
        }
        if (payload?.type === 'merge_decision_pending') {
          const focused = chainViewRef.current.focusedChainId;
          const chainId = payload.chain_id || '';
          if (focused && focused === chainId) {
            dispatch(wsChainViewRefreshRequested(`merge_decision_pending:${chainId}`));
            dispatch(fetchWorkspaceForChain(chainId));
          }
          return;
        }
        if (payload?.type === 'agent_update' || payload?.type === 'agent_lifecycle_changed' || payload?.type === 'agent_runtime_changed') {
          if (payload?.type === 'agent_lifecycle_changed') dispatch(agentLifecycleEventReceived(payload));
          if (payload?.type === 'agent_runtime_changed') dispatch(agentRuntimeEventReceived(payload));
          dispatch(wsRefreshRequested(`${payload.type}:${payload.agent_instance_id || ''}`));
          dispatch(refreshAgents());
          const focused = chainViewRef.current.focusedChainId;
          if (focused) {
            dispatch(wsChainViewRefreshRequested(`${payload.type}:${payload.agent_instance_id || ''}`));
            dispatch(revalidateChainView(focused));
          }
        }
      };
      socket.onerror = () => dispatch(userWsError('User WebSocket connection error'));
      socket.onclose = () => {
        if (stopped) return;
        dispatch(userWsDisconnected());
        reconnectTimer = window.setTimeout(connect, 1500);
      };
    };
    connect();
    return () => {
      stopped = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, [dispatch, loadHomeData, session.connected, session.clientInstanceId, session.clientToken, session.daemonUrl]);

  const openChain = useCallback((chainId: string) => {
    updateUrlParams({ chainId, view: 'chain' });
    dispatch(selectChain(chainId));
    dispatch(fetchTasksForChain(chainId));
    dispatch(focusChainView(chainId));
  }, [dispatch]);

  useEffect(() => {
    if (home.surface !== 'chain' || !home.selectedChainId || !session.connected) return undefined;
    dispatch(focusChainView(home.selectedChainId));
    const interval = window.setInterval(() => dispatch(revalidateChainView(home.selectedChainId)), PERIODIC_REVALIDATE_MS);
    return () => window.clearInterval(interval);
  }, [dispatch, home.surface, home.selectedChainId, session.connected]);

  useEffect(() => {
    if (home.surface !== 'attention' || !session.connected) return undefined;
    dispatch(refreshChatApprovals());
    dispatch(refreshMemory());
    const refresh = window.setInterval(() => { dispatch(refreshChatApprovals()); }, 30_000);
    const expiry = window.setInterval(() => dispatch(tickChatApprovalExpiry()), 15_000);
    return () => { window.clearInterval(refresh); window.clearInterval(expiry); };
  }, [dispatch, home.surface, session.connected]);

  const openProject = useCallback((projectId: string) => {
    updateUrlParams({ chainId: null, taskId: null, view: 'home' });
    dispatch(selectProject(projectId));
    dispatch(selectSurface('home'));
  }, [dispatch]);

  const chainGroups = projects.map((project) => ({
    project,
    chains: chains.filter((chain) => chainProjectId(chain) === project.projectId || (project.projectId === 'default' && !chain.projectId)),
  }));
  const orphanChains = chains.filter((chain) => !projectsById[chainProjectId(chain)] && chainProjectId(chain) !== 'default');
  if (orphanChains.length > 0) chainGroups.push({ project: { projectId: 'unknown', name: 'Other chains' }, chains: orphanChains });

  const activeProject = projectsById[selectedProjectId] || projects[0];
  const shownGroups = selectedProjectId ? chainGroups.filter((group) => group.project.projectId === selectedProjectId || selectedProjectId === 'all') : chainGroups;
  const closeNewProjectModal = useCallback(() => {
    setNewProjectModalOpen(false);
    dispatch(clearProjectError());
  }, [dispatch]);
  const submitNewProject = useCallback(async (payload: { name: string; description?: string }) => {
    const result = await dispatch(createProjectFromUi(payload)).unwrap();
    if (result?.project_id) {
      dispatch(selectProject(result.project_id));
    }
    setNewProjectModalOpen(false);
  }, [dispatch]);
  const sideSheetAgent = useMemo(() => {
    if (!chainView.sideSheetAgentId) return null;
    const live = agents.find((agent: any) => agent.id === chainView.sideSheetAgentId);
    if (live) return live;
    const team = selectedChain ? chainView.teamByChainId[selectedChain.chainId] : null;
    const member = (team?.members || []).find((item: any) => (item.agent_instance_id || item.agentInstanceId || item.route_to || `${item.role_key}-${item.role_index}`) === chainView.sideSheetAgentId);
    if (!member) return { id: chainView.sideSheetAgentId, label: chainView.sideSheetAgentId, status: 'missing' };
    const memberId = member.agent_instance_id || member.agentInstanceId || member.route_to || chainView.sideSheetAgentId;
    return {
      id: memberId,
      label: member.route_to || member.agent_instance_id || member.agentInstanceId || memberId,
      status: member.lifecycle_status || 'missing',
      state: member.lifecycle_status || 'missing',
      roleKey: member.role_key,
      roleIndex: member.role_index,
      isUserProxy: Boolean(member.is_user_proxy),
    };
  }, [agents, chainView.sideSheetAgentId, chainView.teamByChainId, selectedChain]);
  const sideSheetDetails = chainView.sideSheetByAgentId[chainView.sideSheetAgentId] || null;
  const creationProgressState = useMemo(() => chainCreationProgress ? buildChainCreationProgress(chainCreationProgress, chainsById, chainTaskIds, tasksById, agents, chainView) : null, [chainCreationProgress, chainsById, chainTaskIds, tasksById, agents, chainView]);
  useEffect(() => {
    if (!chainCreationProgress?.active || !chainCreationProgress.chainId) return undefined;
    const tick = () => {
      dispatch(refreshAgents()).catch(() => undefined);
      dispatch(refreshTaskBoard()).catch(() => undefined);
      dispatch(fetchTasksForChain(chainCreationProgress.chainId)).catch(() => undefined);
      dispatch(revalidateChainView(chainCreationProgress.chainId)).catch(() => undefined);
    };
    tick();
    const interval = window.setInterval(tick, 2000);
    return () => window.clearInterval(interval);
  }, [dispatch, chainCreationProgress?.active, chainCreationProgress?.chainId]);
  useEffect(() => {
    if (!chainCreationProgress?.active || !creationProgressState?.coordinatorReady || !chainCreationProgress.chainId) return;
    openChain(chainCreationProgress.chainId);
    setChainCreationProgress((current: any) => current?.chainId === chainCreationProgress.chainId ? { ...current, active: false, completed: true } : current);
  }, [chainCreationProgress, creationProgressState?.coordinatorReady, openChain]);

  return (
    <div className="h-screen overflow-hidden bg-[#08090b] text-zinc-100">
      <div className="flex h-full">
        <SurfaceRail
          surface={home.surface}
          badgeCount={badgeCount}
          onSelect={(next: string) => dispatch(selectSurface(next))}
        />
        <aside className="w-64 shrink-0 border-r border-white/10 bg-gradient-to-b from-[#0d0f14] to-[#0a0c11] flex flex-col">
          <div className="px-4 pt-4 pb-3 border-b border-white/5">
            <div className="flex items-center gap-2">
              <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-sky-500/15 text-sky-300">
                <span className="text-sm font-semibold">✦</span>
              </div>
              <div className="min-w-0">
                <div className="text-[10px] uppercase tracking-[0.22em] text-zinc-500">Heimdall</div>
                <div className="truncate text-sm font-semibold text-zinc-100">Chains</div>
              </div>
            </div>
            <DaemonSwitcher
              open={daemonPickerOpen}
              profiles={daemonProfiles}
              activeUrl={session.daemonUrl}
              connected={session.connected}
              onToggle={() => setDaemonPickerOpen((current) => !current)}
              onSelect={switchDaemonProfile}
              onAdd={() => openAddDaemonModal()}
              onRename={(profile: any) => openRenameDaemonModal(profile)}
              onRemove={(profile: any) => dispatch(removeDaemonProfile(profile.url))}
            />
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto px-2 py-3">
            {projects.map((project) => {
              const projectChains = chains.filter((chain) => (chainProjectId(chain) === project.projectId || (project.projectId === 'default' && !chain.projectId)) && !isChainCompleted(chain));
              const isProjectSelected = selectedProjectId === project.projectId;
              const collapsed = Boolean(collapsedProjectIds[project.projectId]);
              return (
                <div key={project.projectId} className="mb-3">
                  <div className={`group flex w-full items-center gap-1.5 rounded-md px-1 py-1 ${isProjectSelected ? 'text-zinc-100' : 'text-zinc-400'}`}>
                    <button
                      data-debug-id={`sidebar-project-toggle-${project.projectId}`}
                      aria-label={collapsed ? `Expand ${project.name || project.projectId}` : `Collapse ${project.name || project.projectId}`}
                      aria-expanded={!collapsed}
                      onClick={() => toggleProjectCollapsed(project.projectId)}
                      className="flex h-5 w-5 shrink-0 items-center justify-center rounded text-zinc-500 transition hover:bg-white/[0.05] hover:text-zinc-200"
                    >
                      <span className={`inline-block text-[10px] transition-transform ${collapsed ? '' : 'rotate-90'}`}>▶</span>
                    </button>
                    <button
                      data-debug-id={`sidebar-project-${project.projectId}`}
                      onClick={() => openProject(project.projectId)}
                      className="flex min-w-0 flex-1 items-center justify-between gap-2 text-left"
                    >
                      <span className="truncate text-[10px] font-semibold uppercase tracking-[0.18em]">{project.name || project.projectId}</span>
                      <span className="shrink-0 text-[10px] text-zinc-500">{projectChains.length}</span>
                    </button>
                  </div>
                  {(() => {
                    const directory = projectAnchorValue(project, 'directory');
                    if (!directory) return null;
                    const vcsKind = projectAnchorValue(project, 'vcs_kind');
                    const vcs = vcsIconForKind(vcsKind);
                    return (
                      <div
                        data-debug-id={`sidebar-project-directory-${project.projectId}`}
                        title={`${directory}${vcsKind ? ` · ${vcs.label}` : ''}`}
                        className="mt-0.5 flex items-center gap-1.5 pl-6 pr-1 text-[10px] text-zinc-500"
                      >
                        <span data-debug-id={`sidebar-project-vcs-${project.projectId}`} aria-label={vcs.label} className={`shrink-0 rounded border px-1 py-0 font-mono text-[9px] uppercase tracking-wide ${vcs.tone}`}>{vcs.icon}</span>
                        <span className="truncate">{shortenPath(directory)}</span>
                      </div>
                    );
                  })()}
                  {!collapsed && (
                    <>
                      <div className="mt-1">
                        {projectChains.length === 0 && (
                          <div className="px-1.5 py-1 text-[10px] text-zinc-600">No active chains</div>
                        )}
                        {projectChains.map((chain) => {
                          const active = home.selectedChainId === chain.chainId;
                          const accent = chainStatusAccent(chain.status);
                          const coordinatorId = chain.coordinatorAgentInstanceId || '';
                          const unread = coordinatorId && !active ? (unreadByAgentId[coordinatorId] || 0) : 0;
                          return (
                            <button
                              key={chain.chainId}
                              data-debug-id={`sidebar-chain-${chain.chainId}`}
                              data-status={chain.status}
                              data-unread={unread > 0 ? unread : undefined}
                              onClick={() => openChain(chain.chainId)}
                              title={`${chain.title || chain.chainId} · ${chain.status}${unread ? ` · ${unread} unread` : ''}`}
                              className={`group flex w-full items-center gap-2 border-l-2 px-2 py-1 text-left text-[12px] transition ${accent.border} ${active ? 'bg-white/[0.06] text-zinc-50' : 'text-zinc-400 hover:bg-white/[0.03] hover:text-zinc-100'}`}
                            >
                              <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${accent.dot}`}></span>
                              <span className="min-w-0 flex-1 truncate">{chain.title || chain.chainId}</span>
                              {unread > 0 && (
                                <span
                                  data-debug-id={`sidebar-chain-unread-${chain.chainId}`}
                                  className="shrink-0 rounded-full bg-sky-400 px-1.5 py-0.5 text-[9px] font-semibold text-black"
                                >{unread > 99 ? '99+' : unread}</span>
                              )}
                            </button>
                          );
                        })}
                      </div>
                      <button
                        data-debug-id={`sidebar-new-chain-btn-${project.projectId}`}
                        onClick={() => dispatch(openNewChainModal({ projectId: project.projectId }))}
                        className="mt-1 flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-[11px] text-zinc-500 transition hover:bg-white/[0.03] hover:text-sky-200"
                      >
                        <span className="text-sm leading-none">+</span> New chain
                      </button>
                    </>
                  )}
                </div>
              );
            })}
          </div>
          <div className="border-t border-white/5 p-2">
            <button
              data-debug-id="home-new-project-btn"
              onClick={() => { dispatch(clearProjectError()); setNewProjectModalOpen(true); }}
              className="flex w-full items-center justify-center gap-1 rounded-lg bg-white/[0.04] px-2 py-2 text-[11px] font-medium text-zinc-200 transition hover:bg-white/[0.09]"
            >
              <span className="text-sm leading-none">+</span> New project
            </button>
          </div>
        </aside>

        <main className="min-w-0 flex-1 overflow-y-auto">
          {home.surface === 'settings' ? (
            <SettingsPage session={session} onBack={() => dispatch(selectSurface('home'))} onReconnect={(config: any) => { dispatch(updateSessionConfig(config)); window.setTimeout(connectSession, 0); }} />
          ) : home.surface === 'chain' && selectedChain ? (
            <ChainView
              chain={selectedChain}
              tasks={(chainTaskIds[selectedChain.chainId] || []).map((id: string) => tasksById[id]).filter(Boolean)}
              tasksById={tasksById}
              chainsById={chainsById}
              agents={agents}
              chainView={chainView}
              taskLogsByTaskId={taskLogsByTaskId}
              onOpenChain={openChain}
              onBack={() => { updateUrlParams({ chainId: null, taskId: null, view: 'home' }); dispatch(selectSurface('home')); }}
              onSend={(body: string) => {
                const localId = `local_${Date.now()}_${Math.random().toString(36).slice(2)}`;
                dispatch(optimisticCoordinatorMessage({ chainId: selectedChain.chainId, body, localId }));
                dispatch(sendCoordinatorMessage({ chainId: selectedChain.chainId, body, localId }));
              }}
              onToggleDiff={() => dispatch(toggleWorkspaceDiff(selectedChain.chainId))}
              onRescan={() => dispatch(fetchWorkspaceForChain(selectedChain.chainId))}
              onPreviewMerge={() => dispatch(previewWorkspaceMerge(selectedChain.chainId))}
              onOpenAgent={(agentId: string) => { dispatch(openAgentSideSheet(agentId)); dispatch(loadAgentSideSheet(agentId)); }}
              onOpenTask={(taskId: string) => dispatch(fetchSelectedTaskLog(taskId))}
              onAddComment={async (task: any, body: string) => {
                try {
                  await dispatch(addCommentToSelectedTask({ taskId: task.taskId, chainId: task.chainId, body })).unwrap();
                  dispatch(showToast({ kind: 'success', title: 'Comment added', message: task.title || task.taskId }));
                  dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId));
                } catch (err: any) {
                  dispatch(showToast({ kind: 'error', title: 'Comment failed', message: err?.message || 'Unable to add task comment' }));
                  throw err;
                }
              }}
              onSetTaskStatus={async (task: any, status: string, body: string) => {
                try {
                  await dispatch(updateSelectedTaskStatus({ taskId: task.taskId, chainId: task.chainId, status, body })).unwrap();
                  dispatch(showToast({ kind: 'success', title: 'Task updated', message: `${task.title || task.taskId} → ${status}` }));
                  dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId));
                } catch (err: any) {
                  dispatch(showToast({ kind: 'error', title: 'Task update failed', message: err?.message || `Unable to set ${status}` }));
                  throw err;
                }
              }}
              onVoteTask={async (task: any, approved: boolean) => {
                try {
                  await dispatch(voteOnSelectedTask({ taskId: task.taskId, chainId: task.chainId, approved, comment: approved ? 'LGTM from ChainView.' : 'Changes requested from ChainView.' })).unwrap();
                  dispatch(showToast({ kind: 'success', title: approved ? 'LGTM recorded' : 'Changes requested', message: task.title || task.taskId }));
                  dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId));
                } catch (err: any) {
                  dispatch(showToast({ kind: 'error', title: 'Review vote failed', message: err?.message || 'Unable to vote on task' }));
                  throw err;
                }
              }}
              onNudgeTask={async (task: any, body: string) => {
                try {
                  await dispatch(nudgeSelectedTask({ taskId: task.taskId, chainId: task.chainId, body, interrupt: false })).unwrap();
                  dispatch(showToast({ kind: 'success', title: 'Nudge sent', message: task.title || task.taskId }));
                  dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId));
                } catch (err: any) {
                  dispatch(showToast({ kind: 'error', title: 'Nudge failed', message: err?.message || 'Unable to nudge task' }));
                  throw err;
                }
              }}
            />
          ) : home.surface === 'attention' ? (
            <AttentionSurface
              tasksById={tasksById}
              chainsById={chainsById}
              openChain={openChain}
              attention={attention}
              memory={memory}
              pendingMemoryIds={pendingMemoryIds}
              onVoteTask={(task: any, approved: boolean) => dispatch(voteOnAttentionTask({ taskId: task.taskId, chainId: task.chainId, approved }))}
              onAnswerApproval={(approvalId: string, reply: string) => dispatch(answerChatApproval({ approvalId, reply }))}
              onDismissApproval={(approvalId: string, reason?: string, notify?: boolean) => dispatch(dismissChatApproval({ approvalId, reason, notify }))}
              onDecideMemory={(proposalId: string, decision: 'approve' | 'reject') => dispatch(decideMemoryProposal({ proposalId, decision }))}
              onOpenMerge={(chainId: string) => { openChain(chainId); dispatch(previewWorkspaceMerge(chainId)); }}
            />
          ) : (
            <HomePage
              groups={shownGroups}
              activeProject={activeProject}
              loading={loading}
              chainTaskIds={chainTaskIds}
              tasksById={tasksById}
              home={home}
              openChain={openChain}
              newChain={(projectId?: string) => dispatch(openNewChainModal({ projectId: projectId || selectedProjectId }))}
            />
          )}
        </main>
        <div
          data-debug-id="guide-side-panel-slot"
          className={`h-full shrink-0 overflow-hidden transition-[width] duration-300 ease-out ${guidePanelOpen ? 'w-[400px]' : 'w-0'}`}
          aria-hidden={!guidePanelOpen}
        >
          {guidePanelOpen && (
            <GuideSidePanel
              agent={guideAgent}
              messages={guideMessages}
              loading={guideLoading}
              sending={guideSending}
              onClose={() => dispatch(closeGuidePanel())}
              onSend={(body: string) => {
                const tempId = `local_temp_guide_${Date.now()}_${Math.random().toString(36).slice(2)}`;
                dispatch(sendGuideMessage({ body, tempId }));
              }}
            />
          )}
        </div>
      </div>
      {!guidePanelOpen && (
        <button
          data-debug-id="guide-floating-btn"
          onClick={() => dispatch(toggleGuidePanel())}
          title="Open Heimdall Guide"
          aria-label="Open Heimdall Guide"
          className="fixed bottom-6 right-6 z-40 flex h-14 w-14 items-center justify-center rounded-full border border-amber-200/30 bg-amber-300 text-2xl text-black shadow-2xl shadow-black/40 transition hover:scale-105 hover:bg-amber-200"
        >
          <span aria-hidden="true">🪖</span>
          {guideUnread > 0 && (
            <span data-debug-id="guide-floating-unread" className="absolute -right-1 -top-1 rounded-full bg-sky-400 px-1.5 py-0.5 text-[10px] font-bold text-black">{guideUnread > 99 ? '99+' : guideUnread}</span>
          )}
        </button>
      )}
      {home.newChainModalOpen && (
        <NewChainModal
          projectId={home.selectedProjectId || selectedProjectId}
          projects={projects}
          agents={agents}
          creating={home.newChainCreating}
          error={home.newChainError}
          onClose={() => dispatch(closeNewChainModal())}
          onSubmit={async (payload: any) => {
            const result = await dispatch(submitNewChain(payload)).unwrap();
            const chainId = result?.chainId || result?.chain_id || '';
            if (chainId) {
              setChainCreationProgress({
                active: true,
                chainId,
                teamId: result?.team_id || result?.teamId || '',
                coordinatorAgentInstanceId: result?.coordinator_agent_instance_id || result?.coordinatorAgentInstanceId || payload.coordinatorAgentInstanceId || '',
                workspaceSetupTaskId: result?.workspace_setup_task_id || result?.workspaceSetupTaskId || '',
                discoveryTaskId: result?.discovery_task_id || result?.discoveryTaskId || '',
                coordinatorBootRequested: Boolean(result?.coordinator_boot_requested || result?.coordinatorBootRequested),
                workspaceId: result?.vcs_workspace_id || result?.vcsWorkspaceId || '',
                wantsVcs: Boolean(payload.wantsVcs),
                startedAt: Date.now(),
              });
              dispatch(focusChainView(chainId));
            }
          }}
        />
      )}
      {creationProgressState && chainCreationProgress?.active && (
        <ChainCreationProgressModal
          progress={creationProgressState}
          onOpen={() => { openChain(chainCreationProgress.chainId); setChainCreationProgress(null); }}
          onCancel={() => setChainCreationProgress(null)}
        />
      )}
      {newProjectModalOpen && (
        <NewProjectModal
          creating={projectMutating}
          error={projectError}
          onClose={closeNewProjectModal}
          onSubmit={submitNewProject}
        />
      )}
      {daemonModalMode && (
        <DaemonProfileModal
          mode={daemonModalMode}
          initialUrl={daemonModalContext.url || session.daemonUrl || ''}
          initialLabel={daemonModalContext.label || ''}
          activeUrl={session.daemonUrl}
          onClose={closeDaemonModal}
          onSubmit={(payload: any) => {
            if (daemonModalMode === 'rename') {
              dispatch(renameDaemonProfile(payload));
              closeDaemonModal();
              return;
            }
            dispatch(addDaemonProfile(payload));
            dispatch(updateSessionConfig({ daemonUrl: payload.daemonUrl || payload.url, userId: session.userId }));
            closeDaemonModal();
            window.setTimeout(() => connectSession(0), 0);
          }}
        />
      )}
      <ToastStack toasts={toasts} onDismiss={(id: string) => dispatch(dismissToast(id))} />
      {chainView.sideSheetAgentId && (
        <AgentSideSheet
          agent={sideSheetAgent}
          details={sideSheetDetails}
          onClose={() => dispatch(closeAgentSideSheet())}
        />
      )}
    </div>
  );
}

function ToastStack({ toasts, onDismiss }: { toasts: any[]; onDismiss: (id: string) => void }) {
  useEffect(() => {
    if (!toasts?.length) return undefined;
    const timers = toasts
      .filter((toast) => toast.autoDismissMs !== 0)
      .map((toast) => window.setTimeout(() => onDismiss(toast.id), toast.autoDismissMs || 3200));
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [toasts, onDismiss]);
  if (!toasts?.length) return null;
  return (
    <div data-debug-id="toast-stack" className="fixed bottom-6 left-1/2 z-[70] flex w-[min(92vw,520px)] -translate-x-1/2 flex-col gap-2">
      {toasts.map((toast) => {
        const tone = toast.kind === 'error' ? 'border-red-400/30 bg-red-500/15 text-red-100' : toast.kind === 'success' ? 'border-emerald-400/30 bg-emerald-500/15 text-emerald-100' : toast.kind === 'progress' ? 'border-sky-400/30 bg-sky-500/15 text-sky-100' : 'border-white/10 bg-zinc-900/95 text-zinc-100';
        return (
          <div key={toast.id} data-debug-id={`toast-${toast.kind}`} className={`rounded-2xl border px-4 py-3 shadow-2xl backdrop-blur ${tone}`}>
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className="text-sm font-semibold">{toast.title}</div>
                {toast.message && <div className="mt-0.5 break-words text-xs opacity-85">{toast.message}</div>}
              </div>
              <button data-debug-id={`toast-${toast.kind}-dismiss`} onClick={() => onDismiss(toast.id)} className="rounded-lg px-2 py-1 text-xs opacity-70 hover:bg-white/10 hover:opacity-100">×</button>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function buildChainCreationProgress(progress: any, chainsById: Record<string, any>, chainTaskIds: Record<string, string[]>, tasksById: Record<string, any>, agents: any[], chainView: any) {
  const chainId = progress.chainId || '';
  const chain = chainsById?.[chainId] || null;
  const team = chainView.teamByChainId?.[chainId]?.team || chainView.teamByChainId?.[chainId] || null;
  const taskIds = chainTaskIds?.[chainId] || [];
  const tasks = taskIds.map((id: string) => tasksById?.[id]).filter(Boolean);
  const workspaceSetupTask = (progress.workspaceSetupTaskId && tasksById?.[progress.workspaceSetupTaskId]) || tasks.find((task: any) => String(task.title || '').toLowerCase().includes('prepare chain workspace')) || null;
  const discoveryTask = (progress.discoveryTaskId && tasksById?.[progress.discoveryTaskId]) || tasks.find((task: any) => String(task.title || '').toLowerCase().includes('discover goal')) || null;
  const coordinatorId = progress.coordinatorAgentInstanceId || chain?.coordinatorAgentInstanceId || chain?.coordinator_agent_instance_id || '';
  const coordinator = agents.find((agent: any) => agent.id === coordinatorId || agent.agentInstanceId === coordinatorId || agent.agent_instance_id === coordinatorId) || null;
  const status = coordinator?.status || coordinator?.startupStatus || '';
  const coordinatorReady = Boolean(coordinator && (coordinator.connected || ['connected', 'idle', 'ready'].includes(status)));
  const elapsedMs = Date.now() - Number(progress.startedAt || Date.now());
  const timedOut = !coordinatorReady && elapsedMs >= 20_000;
  const workspaceReady = !progress.wantsVcs || Boolean(workspaceSetupTask || progress.workspaceId || chain?.vcsWorkspaceId || chain?.vcs_workspace_id || chainView.workspaceByChainId?.[chainId]);
  const steps = [
    { key: 'chain', label: 'Task chain created', done: Boolean(chainId), detail: chainId || 'waiting for chain id' },
    { key: 'team', label: 'Team allocated', done: Boolean(progress.teamId || chain?.teamId || chain?.team_id || team?.team_id), detail: progress.teamId || chain?.teamId || chain?.team_id || team?.team_id || 'waiting for team' },
    { key: 'workspace', label: progress.wantsVcs ? 'Workspace setup task created' : 'Workspace skipped', done: workspaceReady, detail: progress.wantsVcs ? (workspaceSetupTask?.taskId || progress.workspaceSetupTaskId || 'creating setup task') : 'VCS not requested' },
    { key: 'task', label: 'Coordinator discovery task created', done: Boolean(discoveryTask), detail: discoveryTask?.taskId || progress.discoveryTaskId || 'waiting for task' },
    { key: 'boot', label: 'Coordinator start requested', done: Boolean(progress.coordinatorBootRequested || coordinator), detail: progress.coordinatorBootRequested ? `${coordinatorId || 'coordinator'} launch requested by chain create` : (coordinatorId || 'waiting for coordinator') },
    { key: 'running', label: 'Coordinator running / start-success', done: coordinatorReady, detail: coordinator ? `${coordinator.label || coordinator.id} · ${status || (coordinator.connected ? 'connected' : 'starting')}` : (timedOut ? 'not ready after 10s' : 'starting') },
    { key: 'claimed', label: 'Initial task claimed', done: Boolean(discoveryTask?.status === 'in_progress' || coordinator?.currentTaskId === discoveryTask?.taskId), detail: discoveryTask?.status || 'optional after startup' },
  ];
  return { ...progress, chain, team, tasks, workspaceSetupTask, discoveryTask, coordinator, coordinatorId, coordinatorReady, elapsedMs, timedOut, steps };
}

function ChainCreationProgressModal({ progress, onOpen, onCancel }: any) {
  const completed = progress.steps.filter((step: any) => step.done).length;
  const pct = Math.round((completed / progress.steps.length) * 100);
  return (
    <div data-debug-id="chain-creation-progress-modal" className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4">
      <div className="w-full max-w-lg rounded-2xl border border-white/10 bg-[#0d0f14] p-5 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Creating task chain</div>
            <h2 className="mt-2 text-xl font-semibold text-white">Starting coordinator</h2>
            <p className="mt-1 text-sm text-zinc-400">Chat opens once the coordinator is running. Timeout: 20 seconds.</p>
          </div>
          <button data-debug-id="chain-creation-dismiss-btn" onClick={onCancel} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Dismiss</button>
        </div>
        <div className="mt-4 h-2 overflow-hidden rounded-full bg-white/10">
          <div data-debug-id="chain-creation-progress-bar" className={`h-full ${progress.timedOut ? 'bg-amber-400' : 'bg-sky-400'}`} style={{ width: `${pct}%` }} />
        </div>
        <div className="mt-4 space-y-2">
          {progress.steps.map((step: any) => (
            <div key={step.key} data-debug-id={`chain-creation-step-${step.key}`} className="flex items-start gap-3 rounded-xl bg-white/[0.04] px-3 py-2">
              <div className={`mt-0.5 flex h-5 w-5 items-center justify-center rounded-full text-xs ${step.done ? 'bg-emerald-400 text-black' : progress.timedOut && step.key === 'running' ? 'bg-amber-400 text-black' : 'bg-white/10 text-zinc-400'}`}>{step.done ? '✓' : progress.timedOut && step.key === 'running' ? '!' : '…'}</div>
              <div className="min-w-0 flex-1">
                <div className="text-sm font-medium text-zinc-100">{step.label}</div>
                <div className="truncate text-xs text-zinc-500">{step.detail}</div>
              </div>
            </div>
          ))}
        </div>
        {progress.timedOut ? (
          <div data-debug-id="chain-creation-timeout" className="mt-4 rounded-xl border border-amber-400/30 bg-amber-400/10 p-3 text-sm text-amber-100">Coordinator was not ready within 20 seconds. You can open the chain now; chat may still be starting.</div>
        ) : (
          <div className="mt-4 text-sm text-zinc-400">Waiting for coordinator start-success / connected state…</div>
        )}
        <div className="mt-5 flex justify-end gap-2">
          <button data-debug-id="chain-creation-open-btn" onClick={onOpen} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Open chain</button>
          <button data-debug-id="chain-creation-wait-btn" disabled={!progress.timedOut && !progress.coordinatorReady} onClick={onOpen} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500">{progress.coordinatorReady ? 'Open chat' : 'Still starting'}</button>
        </div>
      </div>
    </div>
  );
}

function HomePage({ groups, activeProject, loading, chainTaskIds, tasksById, home, openChain, newChain }: any) {
  return (
    <div className="mx-auto max-w-6xl px-8 py-8">
      <div className="flex items-start justify-between gap-4">
        <div>
          <div className="text-xs uppercase tracking-[0.25em] text-zinc-500">Home</div>
          <h1 className="mt-2 text-4xl font-semibold">Task chains</h1>
          <p className="mt-2 max-w-2xl text-sm text-zinc-400">Live Redux-backed chain list grouped by project. Startup HTTP load, focus/periodic revalidation, and WebSocket-triggered refetches keep this view fresh automatically.</p>
        </div>
        <button data-debug-id="home-new-chain-btn" onClick={() => newChain(activeProject?.projectId)} className="rounded-2xl bg-sky-400 px-5 py-3 font-semibold text-black hover:bg-sky-300">+ New chain</button>
      </div>
      <div className="mt-4 flex flex-wrap gap-2 text-[11px] text-zinc-500">
        <span data-debug-id="home-http-load-evidence" className="rounded-full bg-white/5 px-3 py-1">HTTP load: {home.lastHttpLoadUnixMs ? new Date(home.lastHttpLoadUnixMs).toLocaleTimeString() : 'pending'}</span>
        <span data-debug-id="home-periodic-evidence" className="rounded-full bg-white/5 px-3 py-1">Periodic revalidation: every {PERIODIC_REVALIDATE_MS / 1000}s</span>
        <span data-debug-id="home-ws-evidence" className="rounded-full bg-white/5 px-3 py-1">Last WS refetch: {home.lastWsRefreshReason || 'none yet'}</span>
        <span data-debug-id="home-local-action-evidence" className="rounded-full bg-white/5 px-3 py-1">Local action: {home.lastLocalAction || 'none yet'}</span>
      </div>
      <div className="mt-8 space-y-8">
        {loading && <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-sm text-zinc-400">Loading chains…</div>}
        {groups.map((group: any) => (
          <section key={group.project.projectId}>
            <div className="mb-3 flex items-center justify-between">
              <h2 className="text-lg font-semibold">{group.project.name || group.project.projectId}</h2>
              <button data-debug-id={`home-project-new-chain-btn-${group.project.projectId}`} onClick={() => newChain(group.project.projectId)} className="text-sm text-sky-300 hover:text-sky-100">+ New chain</button>
            </div>
            <div className="grid gap-3">
              {group.chains.length === 0 ? (
                <div className="rounded-2xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">No chains yet for this project.</div>
              ) : group.chains.map((chain: Chain) => (
                <div key={chain.chainId} data-debug-id={`home-chain-row-${chain.chainId}`} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4 shadow-2xl shadow-black/10">
                  <div className="flex items-center justify-between gap-4">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <h3 className="truncate text-lg font-semibold">{chain.title || chain.chainId}</h3>
                        <span className={`rounded-full border px-2 py-0.5 text-[11px] ${statusTone(chain.status)}`}>{chain.status}</span>
                      </div>
                      <div className="mt-1 text-xs text-zinc-500">Project: {group.project.name || group.project.projectId} · Coordinator: {chain.coordinatorAgentInstanceId || '—'}</div>
                      <div className="mt-2 text-sm text-zinc-400">{chainMeta(chain.chainId, chainTaskIds, tasksById)}</div>
                    </div>
                    <button data-debug-id={`home-chain-open-btn-${chain.chainId}`} onClick={() => openChain(chain.chainId)} className="rounded-xl bg-white px-4 py-2 text-sm font-medium text-black hover:bg-zinc-200">Open</button>
                  </div>
                </div>
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}

function AttentionSurface({ tasksById, chainsById, openChain, attention, memory, pendingMemoryIds, onVoteTask, onAnswerApproval, onDismissApproval, onDecideMemory, onOpenMerge }: any) {
  const [filter, setFilter] = useState<'all' | 'chat' | 'tasks' | 'merge' | 'memory'>('all');
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 15_000);
    return () => window.clearInterval(timer);
  }, []);
  const chatApprovals = (attention?.chatApprovalIds || [])
    .map((id: string) => attention.chatApprovalsById?.[id])
    .filter((approval: any) => approval && approval.state === 'open' && approval.expiresAtUnixMs > now && approval.kind !== 'multi_question');
  const taskApprovals = Object.values(tasksById || {}).filter(isUserActionableTask) as any[];
  const mergeChains = (Object.values(chainsById || {}) as any[]).filter((chain: any) => chain?.status === 'reviewing');
  const memoryProposals = (memory?.recordIds || [])
    .map((id: string) => memory.recordsById?.[id])
    .filter((rec: any) => rec && rec.status === 'pending');

  const kinds: { key: typeof filter; label: string; count: number }[] = [
    { key: 'all', label: 'All', count: chatApprovals.length + taskApprovals.length + mergeChains.length + memoryProposals.length },
    { key: 'chat', label: 'Chat approvals', count: chatApprovals.length },
    { key: 'tasks', label: 'Task approvals', count: taskApprovals.length },
    { key: 'merge', label: 'Merge review', count: mergeChains.length },
    { key: 'memory', label: 'Memory proposals', count: memoryProposals.length },
  ];
  const showChat = filter === 'all' || filter === 'chat';
  const showTasks = filter === 'all' || filter === 'tasks';
  const showMerge = filter === 'all' || filter === 'merge';
  const showMemory = filter === 'all' || filter === 'memory';
  const totalVisible = (showChat ? chatApprovals.length : 0) + (showTasks ? taskApprovals.length : 0) + (showMerge ? mergeChains.length : 0) + (showMemory ? memoryProposals.length : 0);
  return (
    <div data-debug-id="attention-surface" className="mx-auto max-w-5xl px-8 py-8">
      <div className="text-xs uppercase tracking-[0.25em] text-zinc-500">Needs attention</div>
      <h1 className="mt-2 text-4xl font-semibold">Actionable inbox</h1>
      <p className="mt-2 text-sm text-zinc-500">Chat approvals ({pendingMemoryIds >= 0 ? '' : ''}from agents), pending memory proposals, task approvals, and chain merges pending your review. Chat approvals expire automatically.</p>
      <div className="mt-6 flex flex-wrap gap-2">
        {kinds.map((k) => (
          <button
            key={k.key}
            data-debug-id={`attention-filter-${k.key}-btn`}
            onClick={() => setFilter(k.key)}
            className={`rounded-full px-3 py-1.5 text-xs ${filter === k.key ? 'bg-white text-black' : 'bg-white/5 hover:bg-white/10'}`}
          >{k.label} <span className="ml-1 rounded-full bg-amber-400/90 px-1 text-black">{k.count}</span></button>
        ))}
      </div>
      <div className="mt-6 space-y-3">
        {totalVisible === 0 && (
          <div data-debug-id="attention-empty" className="rounded-2xl border border-white/10 p-5 text-zinc-400">Nothing needs your attention right now.</div>
        )}
        {showChat && chatApprovals.map((approval: any) => (
          <ChatApprovalCard
            key={approval.approvalId}
            approval={approval}
            chain={chainsById?.[approval.chainId]}
            now={now}
            onAnswer={(reply: string) => onAnswerApproval(approval.approvalId, reply)}
            onDismiss={(reason?: string, notify?: boolean) => onDismissApproval(approval.approvalId, reason, notify)}
            onOpen={() => openChain(approval.chainId)}
          />
        ))}
        {showTasks && taskApprovals.map((task: any) => (
          <div key={`task-${task.taskId}`} data-debug-id={`attention-card-task_approval-${task.taskId}`} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
            <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Task approval</div>
            <div className="mt-1 font-semibold">{chainsById?.[task.chainId]?.title || task.chainId || 'Standalone'} · {task.title}</div>
            <div className="mt-1 text-sm text-zinc-400">{task.status} · {task.notActionableReason || 'awaiting your review'}</div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button data-debug-id={`attention-card-task_approval-${task.taskId}-action-approve`} onClick={() => onVoteTask(task, true)} className="rounded-xl bg-emerald-400 px-3 py-2 text-sm font-semibold text-black hover:bg-emerald-300">Approve</button>
              <button data-debug-id={`attention-card-task_approval-${task.taskId}-action-reject`} onClick={() => onVoteTask(task, false)} className="rounded-xl bg-red-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-red-300">Request changes</button>
              {task.chainId && <button data-debug-id={`attention-card-task_approval-${task.taskId}-action-open`} onClick={() => openChain(task.chainId)} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Open chain</button>}
            </div>
          </div>
        ))}
        {showMerge && mergeChains.map((chain: any) => (
          <div key={`merge-${chain.chainId}`} data-debug-id={`attention-card-chain_merge-${chain.chainId}`} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
            <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Merge review</div>
            <div className="mt-1 font-semibold">{chain.title || chain.chainId}</div>
            <div className="mt-1 text-sm text-zinc-400">Chain is reviewing. Coordinator: {chain.coordinatorAgentInstanceId || '—'}</div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button data-debug-id={`attention-card-chain_merge-${chain.chainId}-action-preview`} onClick={() => onOpenMerge(chain.chainId)} className="rounded-xl bg-sky-400 px-3 py-2 text-sm font-semibold text-black hover:bg-sky-300">Preview merge</button>
              <button data-debug-id={`attention-card-chain_merge-${chain.chainId}-action-open`} onClick={() => openChain(chain.chainId)} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Open chain</button>
            </div>
          </div>
        ))}
        {showMemory && memoryProposals.map((rec: any) => (
          <div key={`memory-${rec.memoryId}`} data-debug-id={`attention-card-memory-${rec.memoryId}`} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
            <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Memory proposal</div>
            <div className="mt-1 font-semibold">{rec.title || rec.subjectAgent} · {rec.type}</div>
            <div className="mt-1 text-sm text-zinc-400">Subject: {rec.subjectAgent} · Scope: {rec.scope}</div>
            {rec.body && (
              <div className="mt-2 rounded-xl bg-black/20 p-3">
                <Markdown source={rec.body} compact className="text-sm text-zinc-200" />
              </div>
            )}
            <div className="mt-3 flex flex-wrap gap-2">
              <button data-debug-id={`attention-card-memory-${rec.memoryId}-action-approve`} onClick={() => onDecideMemory(rec.proposalId, 'approve')} className="rounded-xl bg-emerald-400 px-3 py-2 text-sm font-semibold text-black hover:bg-emerald-300">Approve</button>
              <button data-debug-id={`attention-card-memory-${rec.memoryId}-action-reject`} onClick={() => onDecideMemory(rec.proposalId, 'reject')} className="rounded-xl bg-red-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-red-300">Reject</button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function humanTimeLeft(expiresAtUnixMs: number, now: number): string {
  const ms = Math.max(0, expiresAtUnixMs - now);
  if (ms < 60_000) return `${Math.max(1, Math.round(ms / 1000))}s`;
  const min = Math.floor(ms / 60_000);
  if (min < 60) return `${min}m`;
  const h = Math.floor(min / 60);
  const rem = min % 60;
  return rem === 0 ? `${h}h` : `${h}h ${rem}m`;
}

function ChatApprovalCard({ approval, chain, now, onAnswer, onDismiss, onOpen }: any) {
  const [freeReply, setFreeReply] = useState('');
  const [dismissReasonOpen, setDismissReasonOpen] = useState(false);
  const [dismissReason, setDismissReason] = useState('');
  const [answeredReply, setAnsweredReply] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [multiAnswers, setMultiAnswers] = useState<Record<number, string>>({});
  const timeLeft = humanTimeLeft(approval.expiresAtUnixMs, now);
  const urgent = approval.expiresAtUnixMs - now < 60_000;
  const description = approval.body || approval.title || 'Agent is requesting approval.';
  const used = Boolean(answeredReply) || approval.state !== 'open';
  const disabled = used || submitting;
  const isMultiQuestion = approval.kind === 'multi_question' && (approval.multiQuestions || []).length > 0;
  const handleAnswer = async (reply: string) => {
    const trimmed = String(reply || '').trim();
    if (!trimmed || disabled) return;
    setSubmitting(true);
    try {
      await Promise.resolve(onAnswer(trimmed));
      setAnsweredReply(trimmed);
    } finally {
      setSubmitting(false);
    }
  };
  const multiComplete = isMultiQuestion && approval.multiQuestions.every((_: any, index: number) => String(multiAnswers[index] || '').trim());
  const sendMultiAnswers = () => {
    const reply = JSON.stringify({
      type: 'multi_question_answer',
      answers: (approval.multiQuestions || []).map((question: any, index: number) => ({ question: question.prompt, answer: multiAnswers[index] || '' })),
    });
    handleAnswer(reply);
  };
  return (
    <div data-debug-id={`attention-card-chat_approval-${approval.approvalId}`} className={`rounded-2xl border p-4 ${used ? 'border-emerald-400/25 bg-emerald-400/[0.04]' : 'border-white/10 bg-white/[0.035]'}`}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Chat approval · {approval.kind}</div>
          <div className="mt-1 truncate font-semibold">{chain?.title || approval.chainId || 'Chain'}</div>
          <div className="mt-1 text-xs text-zinc-500">From {approval.agentInstanceId || 'agent'}</div>
        </div>
        <span data-debug-id={`attention-card-chat_approval-${approval.approvalId}-expiry`} className={`shrink-0 rounded-full px-2 py-1 text-[11px] ${used ? 'bg-emerald-400/20 text-emerald-100' : urgent ? 'bg-red-400/20 text-red-100' : 'bg-white/10 text-zinc-300'}`}>{used ? 'answered' : `expires in ${timeLeft}`}</span>
      </div>
      <div className="mt-3 rounded-xl bg-black/20 p-3">
        <Markdown source={description} compact className="text-sm text-zinc-200" />
      </div>
      {isMultiQuestion ? (
        <div data-debug-id={`attention-card-chat_approval-${approval.approvalId}-multi-question`} className="mt-3 space-y-3">
          {approval.multiQuestions.map((question: any, index: number) => (
            <div key={`${approval.approvalId}-question-${index}`} className="rounded-xl bg-black/20 p-3">
              <div className="text-sm font-medium text-zinc-100">{question.prompt}</div>
              {question.options.length > 0 && (
                <div className="mt-2 flex flex-wrap gap-2">
                  {question.options.map((option: string) => (
                    <button
                      key={option}
                      data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-question-${index}-${option.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}
                      onClick={() => setMultiAnswers((prev) => ({ ...prev, [index]: option }))}
                      disabled={disabled}
                      className={`rounded-full border px-3 py-1 text-xs ${multiAnswers[index] === option ? 'border-sky-300/50 bg-sky-300/20 text-sky-100' : 'border-white/10 bg-white/5 text-zinc-200 hover:bg-white/10'} disabled:cursor-not-allowed disabled:opacity-60`}
                    >{option}</button>
                  ))}
                </div>
              )}
              {question.freeForm && (
                <input
                  data-debug-id={`attention-card-chat_approval-${approval.approvalId}-question-${index}-input`}
                  value={multiAnswers[index] || ''}
                  onChange={(event) => setMultiAnswers((prev) => ({ ...prev, [index]: event.target.value }))}
                  disabled={disabled}
                  placeholder="Type an answer…"
                  className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:cursor-not-allowed disabled:text-zinc-500"
                />
              )}
            </div>
          ))}
          <button data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-multi-question-send`} disabled={disabled || !multiComplete} onClick={sendMultiAnswers} className="rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500">Send answers</button>
        </div>
      ) : (
        <div className="mt-3 flex flex-wrap gap-2">
          {approval.suggestedReplies.map((reply: string, index: number) => (
            <button
              key={`${approval.approvalId}-reply-${index}`}
              data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-reply-${index}`}
              onClick={() => handleAnswer(reply)}
              disabled={disabled}
              className="rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500"
            >{prettifyReply(reply)}</button>
          ))}
          {approval.freeForm && (
            <div className="flex min-w-[220px] flex-1 gap-2">
              <input
                data-debug-id={`attention-card-chat_approval-${approval.approvalId}-freeform-input`}
                value={freeReply}
                onChange={(event) => setFreeReply(event.target.value)}
                onKeyDown={(event) => { if (event.key === 'Enter' && freeReply.trim()) { handleAnswer(freeReply.trim()); setFreeReply(''); } }}
                disabled={disabled}
                placeholder="Type a reply…"
                className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:cursor-not-allowed disabled:text-zinc-500"
              />
              <button data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-freeform-send`} disabled={disabled || !freeReply.trim()} onClick={() => { handleAnswer(freeReply.trim()); setFreeReply(''); }} className="rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500">Send</button>
            </div>
          )}
        </div>
      )}
      {used && <div data-debug-id={`attention-card-chat_approval-${approval.approvalId}-answered`} className="mt-2 text-xs text-emerald-200">Reply sent. This card is disabled.</div>}
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-dismiss`} disabled={disabled} onClick={() => setDismissReasonOpen((open) => !open)} className="rounded-xl bg-white/10 px-3 py-2 text-xs hover:bg-white/15 disabled:cursor-not-allowed disabled:text-zinc-500">Dismiss</button>
        {approval.chainId && <button data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-open`} onClick={onOpen} className="rounded-xl bg-white/10 px-3 py-2 text-xs hover:bg-white/15">Open chain</button>}
      </div>
      {dismissReasonOpen && !used && (
        <div data-debug-id={`attention-card-chat_approval-${approval.approvalId}-dismiss-panel`} className="mt-3 flex flex-wrap items-center gap-2 rounded-xl bg-black/30 p-3">
          <input
            data-debug-id={`attention-card-chat_approval-${approval.approvalId}-dismiss-reason-input`}
            value={dismissReason}
            onChange={(event) => setDismissReason(event.target.value)}
            placeholder="Optional reason (e.g. off_topic)"
            className="min-w-[200px] flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
          />
          <button data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-dismiss-confirm`} onClick={() => { onDismiss(dismissReason || 'user_dismissed', false); setDismissReasonOpen(false); }} className="rounded-xl bg-white/15 px-3 py-2 text-xs hover:bg-white/25">Dismiss silently</button>
          <button data-debug-id={`attention-card-chat_approval-${approval.approvalId}-action-dismiss-notify`} onClick={() => { onDismiss(dismissReason || 'user_dismissed', true); setDismissReasonOpen(false); }} className="rounded-xl bg-white/15 px-3 py-2 text-xs hover:bg-white/25">Dismiss and notify agent</button>
        </div>
      )}
    </div>
  );
}

function DaemonSwitcher({ open, profiles, activeUrl, connected, onToggle, onSelect, onAdd, onRename, onRemove }: any) {
  const active = (profiles || []).find((profile: any) => profile.url === activeUrl) || { url: activeUrl, label: activeUrl || 'Select daemon' };
  return (
    <div className="relative mt-3">
      <button
        data-debug-id="sidebar-daemon-picker"
        onClick={onToggle}
        className="flex w-full items-center justify-between gap-2 rounded-xl border border-white/8 bg-white/[0.04] px-3 py-2 text-left transition hover:bg-white/[0.07]"
      >
        <div className="min-w-0">
          <div className="flex items-center gap-1.5 text-[10px] uppercase tracking-[0.18em] text-zinc-500">
            <span className={`inline-block h-1.5 w-1.5 rounded-full ${connected ? 'bg-emerald-400' : 'bg-amber-400'}`}></span>
            <span>{connected ? 'Connected daemon' : 'Daemon offline'}</span>
          </div>
          <div className="truncate text-sm font-medium text-zinc-100">{active.label || active.url}</div>
          <div className="truncate text-[10px] text-zinc-500">{active.url || 'No daemon configured'}</div>
        </div>
        <span className={`text-[10px] text-zinc-500 transition-transform ${open ? 'rotate-180' : ''}`}>▼</span>
      </button>
      {open && (
        <div data-debug-id="sidebar-daemon-menu" className="absolute left-0 right-0 z-20 mt-2 rounded-2xl border border-white/10 bg-[#11141a] p-2 shadow-2xl shadow-black/40">
          <div className="max-h-72 overflow-y-auto">
            {(profiles || []).map((profile: any) => {
              const isActive = profile.url === activeUrl;
              return (
                <div key={profile.url} className={`mb-1 rounded-xl border ${isActive ? 'border-sky-400/30 bg-sky-400/10' : 'border-white/5 bg-white/[0.02]'}`}>
                  <button
                    data-debug-id={`sidebar-daemon-option-${profile.url}`}
                    onClick={() => onSelect(profile)}
                    className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left"
                  >
                    <div className="min-w-0">
                      <div className="truncate text-sm font-medium text-zinc-100">{profile.label || profile.url}</div>
                      <div className="truncate text-[10px] text-zinc-500">{profile.url}</div>
                    </div>
                    {isActive && <span className="rounded-full bg-sky-400 px-1.5 py-0.5 text-[9px] font-semibold text-black">Active</span>}
                  </button>
                  <div className="flex gap-1 px-2 pb-2">
                    <button onClick={() => onRename(profile)} className="rounded-lg bg-white/[0.05] px-2 py-1 text-[10px] text-zinc-300 hover:bg-white/[0.1]">Rename</button>
                    <button onClick={() => onSelect(profile)} className="rounded-lg bg-white/[0.05] px-2 py-1 text-[10px] text-zinc-300 hover:bg-white/[0.1]">Connect</button>
                    {!isActive && <button onClick={() => onRemove(profile)} className="rounded-lg bg-red-500/10 px-2 py-1 text-[10px] text-red-200 hover:bg-red-500/20">Remove</button>}
                  </div>
                </div>
              );
            })}
          </div>
          <button onClick={onAdd} className="mt-1 flex w-full items-center justify-center gap-1 rounded-xl border border-dashed border-white/10 px-3 py-2 text-[11px] text-zinc-300 transition hover:bg-white/[0.04]">
            <span className="text-sm leading-none">+</span> Add daemon
          </button>
        </div>
      )}
    </div>
  );
}

function DaemonProfileModal({ mode, initialUrl, initialLabel, activeUrl, onClose, onSubmit }: any) {
  const [label, setLabel] = useState(initialLabel || '');
  const [daemonUrl, setDaemonUrl] = useState(initialUrl || '');
  const title = mode === 'rename' ? 'Rename daemon' : mode === 'connect_failed' ? 'Unable to connect to daemon' : 'Add daemon';
  const subtitle = mode === 'rename'
    ? 'Update the saved name for this daemon profile.'
    : mode === 'connect_failed'
      ? 'Enter a daemon URL and name to retry. This will be saved in the UI sidebar.'
      : 'Enter a daemon URL and a friendly name. This will be saved in the UI sidebar.';
  const submit = () => {
    const nextUrl = daemonUrl.trim();
    const nextLabel = label.trim();
    if (!nextUrl) return;
    onSubmit({ url: nextUrl, daemonUrl: nextUrl, label: nextLabel || nextUrl, activeUrl });
  };
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/55 px-4">
      <div className="w-full max-w-md rounded-3xl border border-white/10 bg-[#101217] p-6 shadow-2xl shadow-black/50">
        <div className="text-lg font-semibold text-zinc-100">{title}</div>
        <p className="mt-1 text-sm text-zinc-400">{subtitle}</p>
        <div className="mt-4 space-y-3">
          <label className="block text-sm text-zinc-300">
            <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">Name</div>
            <input value={label} onChange={(event) => setLabel(event.target.value)} placeholder="Local daemon" className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 outline-none focus:border-sky-400" />
          </label>
          <label className="block text-sm text-zinc-300">
            <div className="mb-1 text-xs uppercase tracking-wide text-zinc-500">Daemon URL</div>
            <input value={daemonUrl} onChange={(event) => setDaemonUrl(event.target.value)} placeholder="http://127.0.0.1:49322" className="w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 outline-none focus:border-sky-400" />
          </label>
        </div>
        <div className="mt-5 flex justify-end gap-2">
          <button onClick={onClose} className="rounded-xl bg-white/[0.05] px-4 py-2 text-sm text-zinc-300 hover:bg-white/[0.09]">Cancel</button>
          <button onClick={submit} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">{mode === 'rename' ? 'Save' : 'Save & connect'}</button>
        </div>
      </div>
    </div>
  );
}

function SurfaceRail({ surface, badgeCount, onSelect }: { surface: string; badgeCount: number; onSelect: (next: string) => void }) {
  const items: { key: string; label: string; icon: string; badge?: number }[] = [
    { key: 'home', label: 'Home', icon: '⌂' },
    { key: 'attention', label: 'Needs attention', icon: '◎', badge: badgeCount },
    { key: 'settings', label: 'Settings', icon: '⚙' },
  ];
  return (
    <nav data-debug-id="surface-rail" className="flex w-14 shrink-0 flex-col items-center border-r border-white/5 bg-[#08090b] py-3">
      {items.map((item) => {
        const active = surface === item.key;
        return (
          <button
            key={item.key}
            data-debug-id={`nav-${item.key}-btn`}
            title={item.label}
            aria-label={item.label}
            aria-current={active ? 'page' : undefined}
            onClick={() => onSelect(item.key)}
            className={`group relative my-1 flex h-10 w-10 items-center justify-center rounded-xl transition ${active ? 'bg-white text-black shadow-lg shadow-black/40' : 'text-zinc-400 hover:bg-white/[0.06] hover:text-zinc-100'}`}
          >
            <span className="text-lg leading-none">{item.icon}</span>
            {item.key === 'attention' && (item.badge || 0) > 0 && (
              <span data-debug-id="nav-attention-badge" className={`absolute -right-0.5 -top-0.5 inline-flex min-w-[16px] items-center justify-center rounded-full bg-amber-400 px-1 text-[10px] font-semibold text-black ring-2 ring-[#08090b]`}>{item.badge}</span>
            )}
            <span className="pointer-events-none absolute left-full ml-2 whitespace-nowrap rounded-md bg-black/80 px-2 py-1 text-[11px] text-zinc-100 opacity-0 shadow-lg transition group-hover:opacity-100">{item.label}</span>
          </button>
        );
      })}
    </nav>
  );
}

function prettifyReply(reply: string): string {
  if (!reply) return 'Reply';
  const trimmed = reply.trim();
  if (trimmed.length > 40) return `${trimmed.slice(0, 37)}…`;
  try {
    const parsed = JSON.parse(trimmed);
    if (parsed && typeof parsed === 'object') {
      if (parsed.label && typeof parsed.label === 'string') return parsed.label;
      if (parsed.result && typeof parsed.result === 'string') return parsed.result.toUpperCase();
      if (parsed.action && typeof parsed.action === 'string') return parsed.action;
    }
  } catch (_err) {
    // not JSON, fall through
  }
  return trimmed;
}

type CoordinatorMessage = {
  key: string;
  messageId: string;
  body: string;
  isUser: boolean;
  createdUnixMs: number;
  deliveredUnixMs: number;
  readUnixMs: number;
  deliveryFailedUnixMs: number;
  deliveryError: string;
  sending: boolean;
  authorLabel: string;
};

function normalizeCoordinatorMessages(list: any[]): CoordinatorMessage[] {
  const deduped = new Map<string, CoordinatorMessage>();
  list.forEach((msg, index) => {
    const direction = String(msg?.direction || '').toLowerCase();
    const isUser = msg?.author === 'user' || direction === 'user_to_agent';
    const messageId = String(msg?.message_id || msg?.messageId || msg?.id || `local-${index}`);
    const next = {
      key: messageId,
      messageId,
      body: String(msg?.body || ''),
      isUser,
      createdUnixMs: Number(msg?.created_unix_ms ?? msg?.createdUnixMs ?? 0),
      deliveredUnixMs: Number(msg?.delivered_unix_ms ?? msg?.deliveredUnixMs ?? 0),
      readUnixMs: Number(msg?.read_unix_ms ?? msg?.readUnixMs ?? 0),
      deliveryFailedUnixMs: Number(msg?.delivery_failed_unix_ms ?? msg?.deliveryFailedUnixMs ?? 0),
      deliveryError: String(msg?.delivery_error || msg?.deliveryError || ''),
      sending: Boolean(msg?.sending),
      authorLabel: isUser ? 'You' : (msg?.agent_instance_id || msg?.agentInstanceId || 'Coordinator'),
    } as CoordinatorMessage;
    const current = deduped.get(messageId);
    if (!current) {
      deduped.set(messageId, next);
      return;
    }
    deduped.set(messageId, {
      ...current,
      ...next,
      body: next.body || current.body,
      createdUnixMs: Math.max(current.createdUnixMs || 0, next.createdUnixMs || 0),
      deliveredUnixMs: Math.max(current.deliveredUnixMs || 0, next.deliveredUnixMs || 0),
      readUnixMs: Math.max(current.readUnixMs || 0, next.readUnixMs || 0),
      deliveryFailedUnixMs: Math.max(current.deliveryFailedUnixMs || 0, next.deliveryFailedUnixMs || 0),
      deliveryError: next.deliveryError || current.deliveryError,
      sending: current.sending && next.sending,
      authorLabel: next.authorLabel || current.authorLabel,
    });
  });
  const normalized = Array.from(deduped.values());
  normalized.sort((a, b) => (a.createdUnixMs || 0) - (b.createdUnixMs || 0));
  return normalized;
}

function formatChatTimestamp(unixMs: number): { label: string; iso: string } {
  if (!unixMs) return { label: '', iso: '' };
  const date = new Date(unixMs);
  const iso = date.toISOString();
  const now = Date.now();
  const diff = Math.max(0, now - unixMs);
  const oneDay = 24 * 60 * 60 * 1000;
  const time = date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  if (diff < oneDay && date.getDate() === new Date(now).getDate()) return { label: time, iso };
  if (diff < oneDay * 7) return { label: `${date.toLocaleDateString([], { weekday: 'short' })} ${time}`, iso };
  return { label: `${date.toLocaleDateString()} ${time}`, iso };
}

type MultiQuestionPrompt = {
  prompt: string;
  options: string[];
  freeForm: boolean;
};

type CoordinatorActionPayload =
  | { type: 'smart_answer'; body: string; suggestedReplies: string[] }
  | { type: 'multi_question'; body: string; questions: MultiQuestionPrompt[] };

function optionText(item: any): string {
  if (typeof item === 'string') return item;
  if (item && typeof item === 'object') return String(item.label || item.value || item.text || item.title || JSON.stringify(item));
  return String(item ?? '');
}

function normalizeMultiQuestions(value: any): MultiQuestionPrompt[] {
  if (!Array.isArray(value)) return [];
  return value.map((item: any) => {
    if (typeof item === 'string') return { prompt: item, options: [], freeForm: true };
    const rawOptions = Array.isArray(item?.options) ? item.options : (Array.isArray(item?.suggested_replies) ? item.suggested_replies : []);
    return {
      prompt: String(item?.question || item?.prompt || item?.text || item?.body || item?.title || '').trim(),
      options: rawOptions.map(optionText).filter(Boolean),
      freeForm: Boolean(item?.free_form ?? item?.freeForm ?? rawOptions.length === 0),
    };
  }).filter((question) => question.prompt);
}

function parseCoordinatorActionPayload(body: string): null | CoordinatorActionPayload {
  const trimmed = String(body || '').trim();
  if (!trimmed.startsWith('{')) return null;
  try {
    const parsed = JSON.parse(trimmed);
    if (!parsed || typeof parsed !== 'object') return null;
    if (parsed.type === 'smart_answer') {
      const text = typeof parsed.body === 'string' ? parsed.body : '';
      const replies = Array.isArray(parsed.suggested_replies) ? parsed.suggested_replies.map(optionText).filter(Boolean) : [];
      if (!text || replies.length === 0) return null;
      return { type: 'smart_answer', body: text, suggestedReplies: replies };
    }
    if (parsed.type === 'multi_question') {
      const questions = normalizeMultiQuestions(parsed.questions);
      if (questions.length === 0) return null;
      const text = typeof parsed.body === 'string' ? parsed.body : (typeof parsed.title === 'string' ? parsed.title : 'Please answer the questions below.');
      return { type: 'multi_question', body: text, questions };
    }
    return null;
  } catch (_err) {
    return null;
  }
}

function parseCoordinatorSmartAnswer(body: string): null | { type: string; body: string; suggestedReplies: string[] } {
  const action = parseCoordinatorActionPayload(body);
  return action?.type === 'smart_answer' ? action : null;
}

function deliveryStatusFor(msg: CoordinatorMessage): { glyph: string; label: string; tone: string } {
  if (msg.sending) return { glyph: '○', label: 'sending', tone: 'text-sky-200/70' };
  if (msg.deliveryFailedUnixMs || msg.deliveryError) return { glyph: '⚠', label: msg.deliveryError || 'delivery failed', tone: 'text-red-300' };
  if (msg.readUnixMs) return { glyph: '✓✓', label: `read ${formatChatTimestamp(msg.readUnixMs).label}`, tone: 'text-sky-300' };
  if (msg.deliveredUnixMs) return { glyph: '✓✓', label: `delivered ${formatChatTimestamp(msg.deliveredUnixMs).label}`, tone: 'text-zinc-400' };
  if (msg.createdUnixMs) return { glyph: '✓', label: 'sent', tone: 'text-zinc-500' };
  return { glyph: '', label: '', tone: '' };
}

// Default smart-answer card debug ids render as chain-coordinator-smart-answer-<message_id>.
function CoordinatorActionCard({ action, messageId, debugPrefix, usedReply, onUse }: { action: CoordinatorActionPayload; messageId: string; debugPrefix: string; usedReply: string; onUse: (reply: string) => void }) {
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const used = Boolean(usedReply);
  const sendMultiQuestion = () => {
    if (action.type !== 'multi_question' || used) return;
    const payload = JSON.stringify({
      type: 'multi_question_answer',
      prompt_message_id: messageId,
      answers: action.questions.map((question, index) => ({ question: question.prompt, answer: answers[index] || '' })),
    });
    onUse(payload);
  };
  if (action.type === 'smart_answer') {
    return (
      <div data-debug-id={`${debugPrefix}-smart-answer-${messageId}`} className={`mt-2 rounded-xl border p-3 ${used ? 'border-emerald-400/25 bg-emerald-400/[0.06]' : 'border-amber-400/20 bg-amber-400/[0.06]'}`}>
        <div className="text-[10px] font-semibold uppercase tracking-[0.18em] text-amber-200">{used ? 'Reply selected' : 'Needs approval'}</div>
        <Markdown source={action.body} compact className="mt-2" />
        {used && <div data-debug-id={`${debugPrefix}-smart-answer-${messageId}-used`} className="mt-2 text-xs text-emerald-200">Sent: {prettifyReply(usedReply)}</div>}
        <div className="mt-3 flex flex-wrap gap-2">
          {action.suggestedReplies.map((reply) => (
            <button
              key={reply}
              data-debug-id={`${debugPrefix}-smart-answer-${messageId}-${reply.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}
              onClick={() => onUse(reply)}
              disabled={used}
              className="rounded-full border border-amber-300/20 bg-amber-300/10 px-3 py-1 text-xs font-medium text-amber-100 hover:bg-amber-300/20 disabled:cursor-not-allowed disabled:border-emerald-300/20 disabled:bg-emerald-300/10 disabled:text-emerald-100/70"
            >{reply}</button>
          ))}
        </div>
      </div>
    );
  }
  const complete = action.questions.every((_, index) => String(answers[index] || '').trim());
  return (
    <div data-debug-id={`${debugPrefix}-multi-question-${messageId}`} className={`mt-2 rounded-xl border p-3 ${used ? 'border-emerald-400/25 bg-emerald-400/[0.06]' : 'border-amber-400/20 bg-amber-400/[0.06]'}`}>
      <div className="text-[10px] font-semibold uppercase tracking-[0.18em] text-amber-200">{used ? 'Reply selected' : 'Needs answers'}</div>
      {action.body && <Markdown source={action.body} compact className="mt-2" />}
      <div className="mt-3 space-y-3">
        {action.questions.map((question, index) => (
          <div key={`${messageId}-question-${index}`} className="rounded-xl bg-black/20 p-3">
            <div className="text-sm font-medium text-zinc-100">{question.prompt}</div>
            {question.options.length > 0 && (
              <div className="mt-2 flex flex-wrap gap-2">
                {question.options.map((option) => (
                  <button
                    key={option}
                    data-debug-id={`${debugPrefix}-multi-question-${messageId}-q${index}-${option.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}
                    onClick={() => setAnswers((prev) => ({ ...prev, [index]: option }))}
                    disabled={used}
                    className={`rounded-full border px-3 py-1 text-xs ${answers[index] === option ? 'border-sky-300/50 bg-sky-300/20 text-sky-100' : 'border-white/10 bg-white/5 text-zinc-200 hover:bg-white/10'} disabled:cursor-not-allowed disabled:opacity-60`}
                  >{option}</button>
                ))}
              </div>
            )}
            {question.freeForm && (
              <input
                data-debug-id={`${debugPrefix}-multi-question-${messageId}-q${index}-input`}
                value={answers[index] || ''}
                onChange={(event) => setAnswers((prev) => ({ ...prev, [index]: event.target.value }))}
                disabled={used}
                placeholder="Type an answer…"
                className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:cursor-not-allowed disabled:text-zinc-500"
              />
            )}
          </div>
        ))}
      </div>
      {used && <MultiQuestionAnswerSummary reply={usedReply} debugId={`${debugPrefix}-multi-question-${messageId}-used`} />}
      <button data-debug-id={`${debugPrefix}-multi-question-${messageId}-send`} onClick={sendMultiQuestion} disabled={used || !complete} className="mt-3 rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500">Send answers</button>
    </div>
  );
}

function parseMultiQuestionAnswerReply(body: string): null | { promptMessageId: string; answers: { question: string; answer: string }[] } {
  try {
    const parsed = JSON.parse(String(body || '').trim());
    if (!parsed || parsed.type !== 'multi_question_answer' || !Array.isArray(parsed.answers)) return null;
    return {
      promptMessageId: String(parsed.prompt_message_id || parsed.promptMessageId || ''),
      answers: parsed.answers.map((item: any) => ({ question: String(item?.question || ''), answer: String(item?.answer || '') })).filter((item: any) => item.answer),
    };
  } catch (_err) {
    return null;
  }
}

function MultiQuestionAnswerSummary({ reply, debugId }: { reply: string; debugId: string }) {
  const parsed = parseMultiQuestionAnswerReply(reply);
  if (!parsed || parsed.answers.length === 0) {
    return <div data-debug-id={debugId} className="mt-2 text-xs text-emerald-200">Answers sent.</div>;
  }
  return (
    <div data-debug-id={debugId} className="mt-2 rounded-lg bg-emerald-400/10 p-2 text-xs text-emerald-100">
      <div className="font-semibold">Answers saved</div>
      <div className="mt-1 space-y-1">
        {parsed.answers.map((item, index) => (
          <div key={`${debugId}-${index}`}><span className="text-emerald-200/70">{item.question}</span> → {item.answer}</div>
        ))}
      </div>
    </div>
  );
}

function UserActionReplyBubble({ body }: { body: string }) {
  const multi = parseMultiQuestionAnswerReply(body);
  if (multi) return <MultiQuestionAnswerSummary reply={body} debugId="coordinator-user-multi-question-answer" />;
  return <Markdown source={body} compact className="mt-1" />;
}

function deriveCoordinatorActionReplies(messages: CoordinatorMessage[]): Record<string, string> {
  const replies: Record<string, string> = {};
  const pending: { messageId: string; action: CoordinatorActionPayload }[] = [];
  for (const msg of messages) {
    if (!msg.isUser) {
      const action = parseCoordinatorActionPayload(msg.body);
      if (action) pending.push({ messageId: msg.messageId, action });
      continue;
    }
    const multi = parseMultiQuestionAnswerReply(msg.body);
    if (multi) {
      if (multi.promptMessageId && pending.some((item) => item.messageId === multi.promptMessageId && item.action.type === 'multi_question')) {
        replies[multi.promptMessageId] = msg.body;
        continue;
      }
      const target = [...pending].reverse().find((item) => item.action.type === 'multi_question' && !replies[item.messageId]);
      if (target) replies[target.messageId] = msg.body;
      continue;
    }
    const text = String(msg.body || '').trim();
    if (!text) continue;
    const target = [...pending].reverse().find((item) => item.action.type === 'smart_answer' && !replies[item.messageId] && item.action.suggestedReplies.includes(text));
    if (target) replies[target.messageId] = text;
  }
  return replies;
}

function CoordinatorMessageList({ chainId, messages, onReply, debugPrefix = 'chain-coordinator', emptyText = 'No coordinator chat loaded for this chain.' }: { chainId: string; messages: CoordinatorMessage[]; onReply: (reply: string) => void; debugPrefix?: string; emptyText?: string }) {
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const stickyRef = useRef(true);
  const lastCountRef = useRef(0);
  const lastChainRef = useRef(chainId);
  const [showJump, setShowJump] = useState(false);
  const [usedActionCards, setUsedActionCards] = useState<Record<string, string>>({});
  const persistedActionReplies = useMemo(() => deriveCoordinatorActionReplies(messages), [messages]);

  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'auto') => {
    const node = scrollRef.current;
    if (!node) return;
    node.scrollTo({ top: node.scrollHeight, behavior });
    stickyRef.current = true;
    setShowJump(false);
  }, []);

  useEffect(() => {
    if (lastChainRef.current !== chainId) {
      lastChainRef.current = chainId;
      lastCountRef.current = 0;
      stickyRef.current = true;
      // Give the browser a paint before we jump so the new list is measured.
      requestAnimationFrame(() => scrollToBottom('auto'));
    }
  }, [chainId, scrollToBottom]);

  useEffect(() => {
    const count = messages.length;
    if (count === 0) { lastCountRef.current = 0; return; }
    if (count !== lastCountRef.current) {
      const grew = count > lastCountRef.current;
      lastCountRef.current = count;
      if (grew && stickyRef.current) {
        requestAnimationFrame(() => scrollToBottom('smooth'));
      }
    }
  }, [messages.length, scrollToBottom]);

  const onScroll = useCallback(() => {
    const node = scrollRef.current;
    if (!node) return;
    const distance = node.scrollHeight - node.scrollTop - node.clientHeight;
    const nearBottom = distance < 48;
    stickyRef.current = nearBottom;
    setShowJump(!nearBottom && messages.length > 0);
  }, [messages.length]);

  return (
    <div className="relative mt-4 min-h-0 flex-1">
      <div
        ref={scrollRef}
        data-debug-id={`${debugPrefix}-scroll`}
        onScroll={onScroll}
        className="h-full min-h-0 space-y-3 overflow-y-auto rounded-xl bg-black/20 p-4 scroll-smooth"
      >
        {messages.length === 0 ? (
          <div className="text-sm text-zinc-500">{emptyText}</div>
        ) : messages.map((msg) => {
          const timestamp = formatChatTimestamp(msg.createdUnixMs);
          const delivery = deliveryStatusFor(msg);
          return (
            <div
              key={msg.key}
              data-debug-id={`${debugPrefix}-message-${msg.messageId}`}
              className={`rounded-2xl px-4 py-3 text-sm ${msg.isUser ? 'ml-8 bg-sky-500/15 text-sky-100' : 'mr-8 bg-white/5 text-zinc-200'}`}
            >
              <div className="flex items-baseline justify-between gap-3 text-[10px] uppercase tracking-wider text-zinc-500">
                <span className="truncate">{msg.authorLabel}</span>
                {timestamp.label && (
                  <time data-debug-id={`${debugPrefix}-message-${msg.messageId}-time`} dateTime={timestamp.iso} title={timestamp.iso} className="shrink-0">{timestamp.label}</time>
                )}
              </div>
              {(() => {
                if (msg.isUser) return <UserActionReplyBubble body={msg.body} />;
                const action = parseCoordinatorActionPayload(msg.body);
                if (!action) return <Markdown source={msg.body} compact className="mt-1" />;
                return (
                  <CoordinatorActionCard
                    action={action}
                    messageId={msg.messageId}
                    debugPrefix={debugPrefix}
                    usedReply={usedActionCards[msg.messageId] || persistedActionReplies[msg.messageId] || ''}
                    onUse={(reply) => {
                      setUsedActionCards((prev) => ({ ...prev, [msg.messageId]: reply }));
                      onReply(reply);
                    }}
                  />
                );
              })()}
              {msg.isUser && delivery.glyph && (
                <div
                  data-debug-id={`${debugPrefix}-message-${msg.messageId}-status`}
                  title={delivery.label}
                  className={`mt-1 text-right text-[10px] ${delivery.tone}`}
                >{delivery.glyph} {delivery.label}</div>
              )}
            </div>
          );
        })}
      </div>
      {showJump && (
        <button
          data-debug-id={`${debugPrefix}-jump-latest-btn`}
          onClick={() => scrollToBottom('smooth')}
          className="absolute bottom-3 right-3 rounded-full border border-white/10 bg-black/70 px-3 py-1 text-[11px] text-zinc-100 shadow-lg hover:bg-black"
        >Jump to latest ↓</button>
      )}
    </div>
  );
}

function GuideSidePanel({ agent, messages, loading, sending, onClose, onSend }: any) {
  const [draft, setDraft] = useState('');
  const composerRef = useRef<HTMLInputElement | null>(null);
  const runtime = agentRuntimeDot(agent);
  useEffect(() => {
    const timer = window.setTimeout(() => composerRef.current?.focus({ preventScroll: true }), 120);
    return () => window.clearTimeout(timer);
  }, []);
  const submit = () => {
    const body = draft.trim();
    if (!body || sending) return;
    onSend(body);
    setDraft('');
  };
  return (
    <aside data-debug-id="guide-side-panel" className="flex h-full w-[400px] flex-col border-l border-white/10 bg-[#0d0f14] shadow-2xl shadow-black/30">
      <div className="flex items-start justify-between gap-3 border-b border-white/10 p-4">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-amber-300/15 text-xl" aria-hidden="true">🪖</span>
            <div className="min-w-0">
              <div className="text-xs uppercase tracking-[0.22em] text-amber-200/80">Heimdall Guide</div>
              <div data-debug-id="guide-side-panel-agent" className="truncate text-sm font-semibold text-zinc-100">{agent?.label || GUIDE_AGENT_ID}</div>
            </div>
          </div>
          <div className="mt-2 flex items-center gap-2 text-xs text-zinc-500">
            <span data-debug-id="guide-side-panel-status-dot" className={`h-2 w-2 rounded-full ${runtime.color}`}></span>
            <span data-debug-id="guide-side-panel-status">{runtime.label}</span>
            {loading && <span className="text-zinc-600">· loading</span>}
          </div>
        </div>
        <button data-debug-id="guide-side-panel-close-btn" onClick={onClose} className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15">Close</button>
      </div>
      <div className="flex min-h-0 flex-1 flex-col p-4">
        <CoordinatorMessageList
          chainId={GUIDE_AGENT_ID}
          messages={messages}
          onReply={onSend}
          debugPrefix="guide-chat"
          emptyText="No guide chat yet. Ask Heimdall Guide about daemon, UI, tasks, teams, agents, or troubleshooting."
        />
        <div className="mt-4 flex gap-2">
          <input
            data-debug-id="guide-chat-composer-input"
            ref={composerRef}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={(event) => { if (event.key === 'Enter') submit(); }}
            placeholder="Ask Heimdall Guide…"
            className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-amber-300"
          />
          <button data-debug-id="guide-chat-send-btn" disabled={sending || !draft.trim()} onClick={submit} className="rounded-xl bg-amber-300 px-4 py-2 text-sm font-semibold text-black hover:bg-amber-200 disabled:cursor-not-allowed disabled:bg-white/10 disabled:text-zinc-500">Send</button>
        </div>
        <p className="mt-2 text-xs text-zinc-500">Global guide chat is not chain-scoped. Mutating actions should remain explicit and auditable.</p>
      </div>
    </aside>
  );
}

const COMPLETED_TASK_STATUSES = new Set(['approved', 'done', 'completed', 'cancelled', 'archived']);

function isCompletedTask(task: any): boolean {
  return COMPLETED_TASK_STATUSES.has(String(task?.status || ''));
}

function perceivedTaskStatus(task: any, tasksById: Record<string, any>): { label: string; tone: string } {
  if (!task) return { label: 'unknown', tone: statusTone('unknown') };
  const blockers = unmetDependencyIds(task, tasksById || {});
  if (isCompletedTask(task)) return { label: task.status || 'done', tone: 'bg-zinc-700/40 text-zinc-400 border-zinc-600/40' };
  if (blockers.length > 0) return { label: 'blocked by deps', tone: 'bg-amber-500/15 text-amber-200 border-amber-500/30' };
  if (isUserActionableTask(task)) return { label: 'needs you', tone: 'bg-rose-500/15 text-rose-200 border-rose-500/30' };
  if (task.notActionableReason) return { label: 'waiting', tone: 'bg-zinc-500/15 text-zinc-300 border-zinc-500/30' };
  return { label: task.status || 'unknown', tone: statusTone(task.status || 'unknown') };
}

function dependencyOrderedTasks(tasks: any[], tasksById: Record<string, any>): any[] {
  const byId = new Map<string, any>();
  const originalIndex = new Map<string, number>();
  tasks.forEach((task, index) => { byId.set(task.taskId, task); originalIndex.set(task.taskId, index); });
  const visited = new Set<string>();
  const visiting = new Set<string>();
  const out: any[] = [];
  const visit = (task: any) => {
    if (!task?.taskId || visited.has(task.taskId)) return;
    if (visiting.has(task.taskId)) { out.push(task); visited.add(task.taskId); return; }
    visiting.add(task.taskId);
    parseDependsOn(task.dependsOn).forEach((depId) => {
      const dep = byId.get(depId) || tasksById?.[depId];
      if (dep && byId.has(dep.taskId)) visit(dep);
    });
    visiting.delete(task.taskId);
    if (!visited.has(task.taskId)) { visited.add(task.taskId); out.push(task); }
  };
  [...tasks].sort((a, b) => (originalIndex.get(a.taskId) || 0) - (originalIndex.get(b.taskId) || 0)).forEach(visit);
  return out;
}

function ChainView({ chain, tasks, tasksById, chainsById, agents, chainView, taskLogsByTaskId, onBack, onSend, onToggleDiff, onRescan, onPreviewMerge, onOpenAgent, onOpenChain, onOpenTask, onAddComment, onSetTaskStatus, onVoteTask, onNudgeTask }: any) {
  const [draft, setDraft] = useState('');
  const [selectedTaskId, setSelectedTaskId] = useState('');
  const [commentDraft, setCommentDraft] = useState('');
  const [nudgeDraft, setNudgeDraft] = useState('Please take a look at this task when you are available.');
  const composerRef = useRef<HTMLInputElement | null>(null);
  useEffect(() => {
    if (!chain?.chainId) return;
    const node = composerRef.current;
    if (!node) return;
    // Skip when the user is already typing somewhere else (e.g. task comment)
    const active = document.activeElement as HTMLElement | null;
    if (active && active !== node && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA' || active.isContentEditable)) return;
    const timer = window.setTimeout(() => {
      const stillNode = composerRef.current;
      if (stillNode) stillNode.focus({ preventScroll: true });
    }, 60);
    return () => window.clearTimeout(timer);
  }, [chain?.chainId]);
  const workspace = chainView.workspaceByChainId[chain.chainId];
  const chat = chainView.chatByChainId[chain.chainId] || [];
  const optimistic = chainView.optimisticMessagesByChainId[chain.chainId] || [];
  const messages = useMemo(() => normalizeCoordinatorMessages([...chat, ...optimistic]), [chat, optimistic]);
  const diffOpen = Boolean(chainView.diffOpenByChainId[chain.chainId]);
  const preview = chainView.mergePreviewByChainId[chain.chainId];
  const orderedTasks = useMemo(() => dependencyOrderedTasks(tasks, tasksById || {}), [tasks, tasksById]);
  const activeTasks = orderedTasks.filter((task: any) => !isCompletedTask(task));
  const completedTasks = orderedTasks.filter(isCompletedTask);
  const openTask = (task: any) => {
    setSelectedTaskId(task.taskId);
    setCommentDraft('');
    onOpenTask?.(task.taskId);
  };
  const openTaskById = (taskId: string) => {
    if (!taskId) return;
    const local = tasks.find((task: any) => task.taskId === taskId);
    if (local) { openTask(local); return; }
    const remote = tasksById?.[taskId];
    if (remote?.chainId && remote.chainId !== chain.chainId) {
      onOpenChain?.(remote.chainId);
      window.setTimeout(() => onOpenTask?.(taskId), 50);
      return;
    }
    onOpenTask?.(taskId);
  };
  const hasWorkspace = Boolean(chain.vcsWorkspaceId || workspace?.workspace_id);
  const submit = () => {
    const body = draft.trim();
    if (!body) return;
    onSend(body);
    setDraft('');
  };
  return (
    <div className="mx-auto max-w-6xl px-8 py-8">
      <button data-debug-id="chain-back-btn" onClick={onBack} className="rounded-xl bg-white/5 px-3 py-2 text-sm hover:bg-white/10">← Home</button>
      <div className="mt-6 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-4xl font-semibold">{chain.title || chain.chainId}</h1>
          <div className="mt-3 flex flex-wrap gap-2">
            <span className={`rounded-full border px-3 py-1 text-xs ${statusTone(chain.status)}`}>{chain.status}</span>
            <span className="rounded-full bg-white/5 px-3 py-1 text-xs text-zinc-400">Coordinator {chain.coordinatorAgentInstanceId || '—'}</span>
          </div>
        </div>
        <div />
      </div>

      <div className="mt-8 space-y-4">
        <section data-debug-id="chain-coordinator-panel" className="flex h-[70vh] max-h-[70vh] min-h-[420px] flex-col rounded-2xl border border-white/10 bg-white/[0.035] p-4">
          <h2 className="font-semibold">Coordinator chat</h2>
          <CoordinatorMessageList chainId={chain.chainId} messages={messages} onReply={(reply) => onSend(reply)} />
          <div className="mt-4 flex gap-2">
            <input
              data-debug-id="chain-coordinator-composer-input"
              ref={composerRef}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => { if (event.key === 'Enter') submit(); }}
              placeholder="Message coordinator only…"
              autoFocus
              className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
            />
            <button data-debug-id="chain-coordinator-send-btn" onClick={submit} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Send</button>
          </div>
          <p className="mt-2 text-xs text-zinc-500">Sending routes to the chain coordinator. Opening this view records focus and warms the chain team when needed.</p>
        </section>
      </div>

      {hasWorkspace && (
        <div data-debug-id="chain-workspace-row" className="mt-8">
          <WorkspaceBox
            chainId={chain.chainId}
            workspace={workspace}
            preview={preview}
            diffOpen={diffOpen}
            onToggleDiff={onToggleDiff}
            onRescan={onRescan}
            onPreviewMerge={onPreviewMerge}
          />
        </div>
      )}

      <section data-debug-id="chain-task-surface" className="mt-8 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h2 className="font-semibold">Task chain plan</h2>
            <p className="text-xs text-zinc-500">A dependency-ordered todo list. Click a task to expand its description, actions, and comments.</p>
          </div>
          <span data-debug-id="chain-task-count" className="rounded-full bg-white/5 px-3 py-1 text-xs text-zinc-400">{activeTasks.length} active · {completedTasks.length} completed</span>
        </div>
        <TaskTodoList
          title="Active tasks"
          emptyText="No active tasks."
          tasks={activeTasks}
          tasksById={tasksById}
          taskLogsByTaskId={taskLogsByTaskId}
          expandedTaskId={selectedTaskId}
          commentDraft={commentDraft}
          nudgeDraft={nudgeDraft}
          onCommentDraft={setCommentDraft}
          onNudgeDraft={setNudgeDraft}
          onOpenTask={openTask}
          onOpenTaskById={openTaskById}
          onCloseTask={() => setSelectedTaskId('')}
          onAddComment={onAddComment}
          onSetTaskStatus={onSetTaskStatus}
          onVoteTask={onVoteTask}
          onNudgeTask={onNudgeTask}
          agents={agents}
        />
        {completedTasks.length > 0 && (
          <div data-debug-id="chain-completed-task-section" className="mt-5 border-t border-white/10 pt-4">
            <TaskTodoList
              title="Completed tasks"
              emptyText="No completed tasks."
              tasks={completedTasks}
              tasksById={tasksById}
              taskLogsByTaskId={taskLogsByTaskId}
              expandedTaskId={selectedTaskId}
              commentDraft={commentDraft}
              nudgeDraft={nudgeDraft}
              onCommentDraft={setCommentDraft}
              onNudgeDraft={setNudgeDraft}
              onOpenTask={openTask}
              onOpenTaskById={openTaskById}
              onCloseTask={() => setSelectedTaskId('')}
              onAddComment={onAddComment}
              onSetTaskStatus={onSetTaskStatus}
              onVoteTask={onVoteTask}
              onNudgeTask={onNudgeTask}
              agents={agents}
              completed
            />
          </div>
        )}
      </section>
    </div>
  );
}

function taskReviewerIds(task: any): string[] {
  const ids = new Set<string>();
  if (task?.reviewerAgentInstanceId) ids.add(String(task.reviewerAgentInstanceId));
  (task?.participants || []).forEach((participant: any) => {
    if (participant?.role === 'lgtm_required' && participant.agentInstanceId) ids.add(String(participant.agentInstanceId));
  });
  return [...ids];
}

export function isAgentRunning(agent: any): boolean {
  if (!agent) return false;
  const startup = String(agent.startupStatus || '').toLowerCase();
  const state = String(agent.state || agent.status || '').toLowerCase();
  if (agent.blockedReason || state === 'blocked' || startup === 'blocked' || startup === 'startup_blocked') return false;
  if (agent.currentTaskId || agent.connected) return true;
  return ['ready', 'live', 'connected', 'idle', 'working', 'active'].includes(state) || ['ready', 'connected'].includes(startup);
}

function TaskAgentChip({ role, agentId, agent, active }: any) {
  const runtime = agentRuntimeDot(agent || { id: agentId, state: agentId ? 'missing' : 'unknown' });
  const running = isAgentRunning(agent);
  const activity = String(agent?.activityStatus || agent?.activity_status || '').toLowerCase();
  const working = Boolean(active && running && (activity === '' || activity === 'unknown' || activity === 'active'));
  const idle = Boolean(active && running && activity === 'idle');
  const workingLabel = activity === 'active' ? 'active' : 'working…';
  const tone = working
    ? 'border-emerald-400/35 bg-emerald-400/10 text-emerald-100'
    : idle
      ? 'border-amber-300/35 bg-amber-300/10 text-amber-100'
      : 'border-white/10 bg-black/20 text-zinc-400';
  return (
    <span data-debug-id={`chain-task-${role.toLowerCase()}-${agentId || 'none'}`} className={`inline-flex max-w-[220px] items-center gap-1.5 rounded-full border px-2 py-1 text-[11px] ${tone}`} title={`${role}: ${agentId || 'none'} · ${runtime.label}`}>
      <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${working ? 'animate-ping bg-emerald-300' : idle ? 'bg-amber-300' : runtime.color}`}></span>
      <span className="shrink-0 text-zinc-500">{role}</span>
      <span className="truncate">{agent?.label || agentId || '—'}</span>
      <span className="shrink-0 text-zinc-600">·</span>
      <span className="shrink-0">{working ? workingLabel : idle ? 'idle' : runtime.label}</span>
    </span>
  );
}

function TaskTodoList({ title, emptyText, tasks, tasksById, taskLogsByTaskId, expandedTaskId, commentDraft, nudgeDraft, onCommentDraft, onNudgeDraft, onOpenTask, onOpenTaskById, onCloseTask, onAddComment, onSetTaskStatus, onVoteTask, onNudgeTask, agents = [], completed = false }: any) {
  const [commentsOpenByTaskId, setCommentsOpenByTaskId] = useState<Record<string, boolean>>({});
  const [busyAction, setBusyAction] = useState('');
  const [localError, setLocalError] = useState('');
  const agentsById = useMemo(() => {
    const map = new Map<string, any>();
    (agents || []).forEach((agent: any) => { if (agent?.id) map.set(String(agent.id), agent); });
    return map;
  }, [agents]);
  const runAction = async (key: string, fn: () => Promise<void> | void) => {
    setBusyAction(key);
    setLocalError('');
    try {
      await Promise.resolve(fn());
    } catch (err: any) {
      setLocalError(err?.message || 'Action failed');
    } finally {
      setBusyAction('');
    }
  };
  return (
    <div data-debug-id={`chain-task-list-${completed ? 'completed' : 'active'}`} className="mt-4">
      <div className="mb-2 flex items-center justify-between text-xs uppercase tracking-wide text-zinc-500"><span>{title}</span><span>{tasks.length}</span></div>
      {localError && <div data-debug-id="task-list-action-error" className="mb-2 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{localError}</div>}
      <div className="space-y-2">
        {tasks.length === 0 ? <div className="rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">{emptyText}</div> : tasks.map((task: any, index: number) => {
          const expanded = expandedTaskId === task.taskId;
          const perceived = perceivedTaskStatus(task, tasksById || {});
          const commentsOpen = Boolean(commentsOpenByTaskId[task.taskId]);
          const taskLog = taskLogsByTaskId?.[task.taskId] || [];
          const comments = taskLog.filter((event: any) => event.kind === 'Task_Comment');
          const reviewEvents = taskLog.filter((event: any) => event.kind === 'Task_Review_Vote');
          const votes = task.votes || [];
          const blockers = unmetDependencyIds(task, tasksById || {});
          const startDisabledReason = blockers.length > 0 ? `Waiting on ${blockers.join(', ')}` : (task.notActionableReason?.startsWith('assignee_busy:') ? task.notActionableReason : '');
          const actionNeeded = isUserActionableTask(task);
          const assigneeId = task.assigneeAgentInstanceId || '';
          const assigneeAgent = assigneeId ? agentsById.get(String(assigneeId)) : null;
          const reviewerIds = taskReviewerIds(task);
          const reviewerId = reviewerIds[0] || '';
          const reviewerAgent = reviewerId ? agentsById.get(String(reviewerId)) : null;
          const assigneeWorking = task.status === 'in_progress' && blockers.length === 0 && !task.notActionableReason;
          const reviewerWorking = task.status === 'review_ready';
          const baseTone = completed ? 'border-white/5 bg-white/[0.025] text-zinc-500 opacity-70' : expanded ? 'border-sky-400/30 bg-sky-400/[0.06]' : 'border-white/8 bg-white/[0.04] hover:bg-white/[0.07]';
          return (
            <div key={task.taskId} data-debug-id={`chain-task-row-${task.taskId}`} className={`rounded-2xl border transition ${baseTone}`}>
              <div className="flex items-center gap-3 px-4 py-3">
                <button onClick={() => expanded ? onCloseTask() : onOpenTask(task)} className="min-w-0 flex-1 text-left">
                  <div className="flex min-w-0 items-center gap-2">
                    <span className="w-6 shrink-0 font-mono text-xs text-zinc-600">{index + 1}</span>
                    <span data-debug-id={`chain-task-row-${task.taskId}-title`} className={`truncate text-sm font-medium ${completed ? 'text-zinc-500 line-through decoration-zinc-600' : 'text-zinc-100'}`}>{task.title || task.taskId}</span>
                    <span data-debug-id={`chain-task-row-${task.taskId}-status`} className={`shrink-0 rounded-full border px-2 py-0.5 text-[11px] ${perceived.tone}`}>{perceived.label}</span>
                  </div>
                  <div data-debug-id={`chain-task-row-${task.taskId}-agents`} className="mt-2 ml-8 flex min-w-0 flex-wrap items-center gap-2">
                    <TaskAgentChip role="Assignee" agentId={assigneeId} agent={assigneeAgent} active={assigneeWorking} />
                    <TaskAgentChip role="Reviewer" agentId={reviewerId} agent={reviewerAgent} active={reviewerWorking} />
                  </div>
                </button>
                {actionNeeded && (
                  <button data-debug-id={`chain-task-row-${task.taskId}-action-needed-btn`} onClick={() => onOpenTask(task)} className="shrink-0 rounded-xl bg-rose-400 px-3 py-1.5 text-xs font-semibold text-black hover:bg-rose-300">Action needed</button>
                )}
                <button data-debug-id={`chain-task-row-${task.taskId}-expand-btn`} aria-label={expanded ? 'Collapse task details' : 'Expand task details'} title={expanded ? 'Collapse task details' : 'Expand task details'} onClick={() => expanded ? onCloseTask() : onOpenTask(task)} className="shrink-0 rounded-lg bg-white/10 px-2 py-1 text-xs hover:bg-white/15">{expanded ? '⌃' : '›'}</button>
              </div>
              {expanded && (
                <div data-debug-id={`chain-task-row-${task.taskId}-expanded`} className="border-t border-white/10 px-4 py-4">
                  <div className="flex flex-wrap gap-2 text-xs">
                    <span className={`rounded-full border px-2 py-1 ${statusTone(task.status)}`}>{task.status}</span>
                    <span className="rounded-full bg-black/20 px-2 py-1 text-zinc-400">Assignee {task.assigneeAgentInstanceId || '—'}</span>
                    <span className="rounded-full bg-black/20 px-2 py-1 text-zinc-400">Reviewer {task.reviewerAgentInstanceId || '—'}</span>
                  </div>
                  <div data-debug-id={`task-detail-description-${task.taskId}`} className="mt-3 rounded-xl bg-black/20 p-3">
                    {task.description ? <Markdown source={task.description} className="text-sm text-zinc-300" /> : <div className="text-sm text-zinc-500">No description.</div>}
                  </div>
                  {task.dependsOn && (
                    <div data-debug-id={`task-detail-depends-on-${task.taskId}`} className="mt-3 rounded-xl bg-black/20 p-3">
                      <div className="text-[10px] uppercase tracking-wider text-zinc-500">Depends on</div>
                      <div className="mt-1 flex flex-wrap gap-1.5">
                        {parseDependsOn(task.dependsOn).map((depId: string) => {
                          const dep = tasksById?.[depId];
                          const satisfied = dep && isCompletedTask(dep);
                          return <button key={`${task.taskId}-${depId}`} onClick={() => onOpenTaskById(depId)} className={`rounded border px-1.5 py-0.5 font-mono text-[10px] ${satisfied ? 'border-emerald-500/30 bg-emerald-500/10 text-emerald-100' : 'border-amber-500/30 bg-amber-500/10 text-amber-100'}`}>{depId}</button>;
                        })}
                      </div>
                    </div>
                  )}
                  {task.notActionableReason && <InfoRow label="Not actionable" value={task.notActionableReason} tone={task.notActionableReason.startsWith('deps_unmet:') ? 'text-amber-200' : 'text-zinc-300'} />}
                  <div data-debug-id={`task-detail-actions-${task.taskId}`} className="mt-3 flex flex-wrap gap-2">
                    <button data-debug-id={`task-detail-status-start-btn-${task.taskId}`} disabled={Boolean(startDisabledReason) || Boolean(busyAction)} title={startDisabledReason || 'Start task'} onClick={() => runAction(`start-${task.taskId}`, () => onSetTaskStatus(task, 'in_progress', 'Started from ChainView.'))} className="rounded-xl bg-white/10 px-3 py-2 text-xs hover:bg-white/15 disabled:cursor-not-allowed disabled:bg-white/5 disabled:text-zinc-500">Start</button>
                    <button data-debug-id={`task-detail-status-done-btn-${task.taskId}`} disabled={Boolean(busyAction)} onClick={() => runAction(`done-${task.taskId}`, () => onSetTaskStatus(task, 'review_ready', 'Submitted for review from ChainView.'))} className="rounded-xl bg-emerald-400/90 px-3 py-2 text-xs font-semibold text-black hover:bg-emerald-300 disabled:opacity-60">Done / review</button>
                    <button data-debug-id={`task-detail-status-block-btn-${task.taskId}`} disabled={Boolean(busyAction)} onClick={() => runAction(`block-${task.taskId}`, () => onSetTaskStatus(task, 'blocked', 'Blocked from ChainView.'))} className="rounded-xl bg-amber-400/90 px-3 py-2 text-xs font-semibold text-black hover:bg-amber-300 disabled:opacity-60">Block</button>
                    <button data-debug-id={`task-detail-status-later-btn-${task.taskId}`} disabled={Boolean(busyAction)} onClick={() => runAction(`later-${task.taskId}`, () => onSetTaskStatus(task, 'queued', 'Moved later from ChainView.'))} className="rounded-xl bg-white/10 px-3 py-2 text-xs hover:bg-white/15 disabled:opacity-60">Later</button>
                    <button data-debug-id={`task-detail-vote-lgtm-btn-${task.taskId}`} disabled={Boolean(busyAction)} onClick={() => runAction(`lgtm-${task.taskId}`, () => onVoteTask(task, true))} className="rounded-xl bg-sky-400/90 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-60">LGTM</button>
                    <button data-debug-id={`task-detail-vote-ngtm-btn-${task.taskId}`} disabled={Boolean(busyAction)} onClick={() => runAction(`ngtm-${task.taskId}`, () => onVoteTask(task, false))} className="rounded-xl bg-red-400/90 px-3 py-2 text-xs font-semibold text-black hover:bg-red-300 disabled:opacity-60">NGTM</button>
                    {busyAction.endsWith(task.taskId) && <span className="self-center text-xs text-sky-200">Working…</span>}
                  </div>
                  <div className="mt-3 rounded-xl bg-black/20 p-3">
                    <div className="text-xs uppercase tracking-wider text-zinc-500">Nudge</div>
                    <textarea data-debug-id={`task-detail-nudge-textarea-${task.taskId}`} value={nudgeDraft} onChange={(event) => onNudgeDraft(event.target.value)} rows={2} className="mt-2 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
                    <button data-debug-id={`task-detail-nudge-btn-${task.taskId}`} disabled={Boolean(busyAction) || !String(nudgeDraft || '').trim()} onClick={() => runAction(`nudge-${task.taskId}`, () => onNudgeTask(task, nudgeDraft))} className="mt-2 rounded-xl bg-white/10 px-3 py-2 text-xs hover:bg-white/15 disabled:opacity-60">Send nudge</button>
                  </div>
                  {(votes.length > 0 || reviewEvents.length > 0) && (
                    <div data-debug-id={`task-detail-votes-${task.taskId}`} className="mt-3 rounded-xl bg-black/20 p-3">
                      <div className="text-xs uppercase tracking-wider text-zinc-500">Votes / review history</div>
                      <div className="mt-2 space-y-2">
                        {votes.map((vote: any, voteIndex: number) => <div key={`vote-${voteIndex}`} className="rounded-lg bg-white/[0.04] p-2 text-sm text-zinc-300">{vote.reviewerAgentInstanceId || 'reviewer'} · {vote.approved ? 'LGTM' : 'NGTM'}{vote.comment ? ` · ${vote.comment}` : ''}</div>)}
                        {reviewEvents.map((event: any, eventIndex: number) => <div key={event.eventId || eventIndex} className="rounded-lg bg-white/[0.04] p-2 text-sm text-zinc-300"><Markdown source={event.body || event.status || 'vote recorded'} compact /></div>)}
                      </div>
                    </div>
                  )}
                  <div className="mt-3 rounded-xl bg-black/20 p-3">
                    <button data-debug-id={`task-detail-comments-toggle-${task.taskId}`} onClick={() => setCommentsOpenByTaskId((prev) => ({ ...prev, [task.taskId]: !prev[task.taskId] }))} className="flex w-full items-center justify-between text-left text-xs uppercase tracking-wider text-zinc-500"><span>Comments</span><span>{comments.length} · {commentsOpen ? 'hide' : 'show'}</span></button>
                    {commentsOpen && (
                      <div data-debug-id={`task-detail-comments-${task.taskId}`} className="mt-3 space-y-2">
                        {comments.length === 0 ? <div className="text-sm text-zinc-500">No comments loaded.</div> : comments.map((comment: any, commentIndex: number) => (
                          <div key={comment.commentId || commentIndex} data-debug-id={`task-detail-comment-${task.taskId}-${commentIndex}`} className="rounded-lg bg-white/[0.04] p-2 text-sm text-zinc-300">
                            <div className="text-[10px] uppercase tracking-wider text-zinc-500">{comment.authorAgentInstanceId || 'comment'}</div>
                            <Markdown source={comment.body || ''} compact className="mt-1 text-sm text-zinc-300" />
                          </div>
                        ))}
                      </div>
                    )}
                    <textarea data-debug-id={`task-detail-comment-textarea-${task.taskId}`} value={commentDraft} onChange={(event) => onCommentDraft(event.target.value)} rows={2} placeholder="Add a task comment…" className="mt-3 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
                    <button data-debug-id={`task-detail-comment-submit-btn-${task.taskId}`} disabled={Boolean(busyAction) || !String(commentDraft || '').trim()} onClick={() => runAction(`comment-${task.taskId}`, async () => { const body = String(commentDraft || '').trim(); if (!body) return; await onAddComment(task, body); onCommentDraft(''); setCommentsOpenByTaskId((prev) => ({ ...prev, [task.taskId]: true })); })} className="mt-2 rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-60">Add comment</button>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

function AgentSideSheet({ agent, details, onClose }: any) {
  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-black/50">
      <aside className="h-full w-96 border-l border-white/10 bg-[#0d0f14] p-5 shadow-2xl">
        <div className="flex items-start justify-between gap-3">
          <div>
            <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Team member</div>
            <h2 className="mt-2 text-2xl font-semibold">{agent?.label || agent?.id || 'Unknown member'}</h2>
          </div>
          <button data-debug-id="chain-agent-side-sheet-close-btn" onClick={onClose} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Close</button>
        </div>
        <div className="mt-6 space-y-3 text-sm">
          <InfoRow label="Agent" value={agent?.id || '—'} />
          {agent?.roleKey && <InfoRow label="Role" value={`${agent.roleKey} #${Number(agent.roleIndex || 0) + 1}`} />}
          <InfoRow label="State" value={agent?.state || agent?.status || '—'} />
          <div data-debug-id="chain-agent-current-task" className="rounded-xl bg-white/[0.04] p-3">
            <div className="text-xs uppercase tracking-wider text-zinc-500">Current task</div>
            <div className="mt-1 break-words text-zinc-300">{details?.task?.title || agent?.currentTaskId || details?.taskId || 'idle'}</div>
          </div>
          {details?.task && <InfoRow label="Task status" value={details.task.status || '—'} />}
          <InfoRow label="Project" value={agent?.projectName || agent?.projectId || '—'} />
          <InfoRow label="Run dir" value={agent?.runDir || '—'} />
          {agent?.blockedReason && <InfoRow label="Blocked" value={agent.blockedReason} tone="text-red-200" />}
        </div>
        <div data-debug-id="chain-agent-last-comments" className="mt-5 rounded-xl bg-white/[0.04] p-3">
          <div className="text-xs uppercase tracking-wider text-zinc-500">Last 3 task comments</div>
          <div className="mt-3 space-y-2">
            {!details?.taskId ? <div className="text-sm text-zinc-500">No current task.</div> : (details?.comments || []).length === 0 ? <div className="text-sm text-zinc-500">No comments loaded for current task.</div> : details.comments.map((comment: any, index: number) => (
              <div key={comment.comment_id} data-debug-id={`chain-agent-comment-${index}`} className="rounded-lg bg-black/20 p-2 text-sm text-zinc-300">
                <div className="text-[10px] uppercase tracking-wider text-zinc-500">{comment.author_agent_instance_id || 'comment'} · {comment.resolved ? 'resolved' : 'open'}</div>
                <div className="mt-1 line-clamp-4 whitespace-pre-wrap">{comment.body}</div>
              </div>
            ))}
          </div>
        </div>
        <p className="mt-6 text-xs text-zinc-500">Read-only roster detail. Messaging remains coordinator-only from ChainView.</p>
      </aside>
    </div>
  );
}

function InfoRow({ label, value, tone = 'text-zinc-300' }: any) {
  return (
    <div className="rounded-xl bg-white/[0.04] p-3">
      <div className="text-xs uppercase tracking-wider text-zinc-500">{label}</div>
      <div className={`mt-1 break-words ${tone}`}>{value}</div>
    </div>
  );
}

function WorkspaceBox({ chainId, workspace, preview, diffOpen, onToggleDiff, onRescan, onPreviewMerge }: any) {
  const files = workspace?.status?.files || workspace?.files || [];
  return (
    <section className="rounded-2xl border border-sky-400/20 bg-sky-400/[0.04] p-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="font-semibold">Workspace</h2>
          <div className="mt-2 text-sm text-zinc-300">{workspace?.branch_or_change || workspace?.branchOrChange || workspace?.workspace_id || chainId}</div>
          <div className="mt-1 text-xs text-zinc-500">base {workspace?.base_ref || workspace?.baseRef || 'main'} · {workspace?.path || 'workspace path pending'}</div>
          <div className="mt-2 text-sm text-zinc-400">{workspace?.status?.summary_line || workspace?.status || 'Workspace status loads on focus/re-scan.'}</div>
        </div>
        <div className="flex flex-wrap justify-end gap-2">
          <button data-debug-id="workspace-refresh-btn" onClick={onRescan} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Re-scan workspace</button>
          <button data-debug-id="workspace-pull-base-btn" disabled className="rounded-xl bg-white/5 px-3 py-2 text-sm text-zinc-500">Pull base</button>
          <button data-debug-id="workspace-preview-merge-btn" onClick={onPreviewMerge} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Preview merge</button>
          <button data-debug-id="workspace-show-diff-btn" onClick={onToggleDiff} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Show diff</button>
          <button data-debug-id="workspace-copy-diff-btn" disabled className="rounded-xl bg-white/5 px-3 py-2 text-sm text-zinc-500">Copy diff</button>
          <button data-debug-id="workspace-ask-coordinator-btn" disabled className="rounded-xl bg-white/5 px-3 py-2 text-sm text-zinc-500">Ask coordinator</button>
        </div>
      </div>
      <div className="mt-4 grid gap-2 md:grid-cols-2">
        {files.length === 0 ? <div className="text-sm text-zinc-500">No changed files reported.</div> : files.map((file: any, index: number) => {
          const path = file.path || `file-${index}`;
          const slug = String(path).replace(/[^a-zA-Z0-9_-]/g, '-');
          return <div key={path} data-debug-id={`workspace-file-${slug}`} className="rounded-xl bg-black/20 px-3 py-2 text-sm text-zinc-300">{file.status || '?'} {path} <span className="text-zinc-500">+{file.adds || 0} −{file.dels || 0}</span></div>;
        })}
      </div>
      <select data-debug-id="workspace-diff-file-select" className="mt-4 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-300" disabled={files.length === 0}>
        {files.length === 0 ? <option>No files</option> : files.map((file: any, index: number) => <option key={file.path || index}>{file.path || `file-${index}`}</option>)}
      </select>
      {preview && <pre className="mt-4 max-h-40 overflow-auto rounded-xl bg-black/30 p-3 text-xs text-zinc-300">{JSON.stringify(preview, null, 2)}</pre>}
      {diffOpen && <div className="mt-4 rounded-xl bg-black/30 p-4 text-sm text-zinc-400">Diff panel requested. File-specific diff loading lands in the workspace follow-up; VCS commands still require explicit clicks.</div>}
      <p className="mt-3 text-xs text-zinc-500">No VCS command runs without your click.</p>
    </section>
  );
}

const TEAM_KIND_OPTIONS = [
  { key: 'coding', label: 'Coding', description: 'The default kind for changes to code repositories.', scaffolds: ['feature', 'bugfix', 'refactor'], wantsVcs: true },
  { key: 'research', label: 'Research', description: 'Non-code investigative work: source review, market scan, spike write-ups.', scaffolds: ['report', 'spike'], wantsVcs: false },
  { key: 'debugging', label: 'Debugging', description: 'Diagnostic work with an expected fix at the end.', scaffolds: ['bug', 'incident'], wantsVcs: true },
  { key: 'data-analysis', label: 'Data analysis', description: 'Notebooks, dataset exploration, and model evaluation.', scaffolds: ['analysis'], wantsVcs: true },
  { key: 'writing', label: 'Writing', description: 'Docs, blog posts, and longer-form artifacts.', scaffolds: ['article'], wantsVcs: true },
  { key: 'ops', label: 'Ops', description: 'Repo/config maintenance, dependency bumps, and small automations.', scaffolds: ['chore'], wantsVcs: true },
  { key: 'solo', label: 'Solo', description: 'A team of one backed by a synthetic user_proxy reviewer.', scaffolds: ['solo'], wantsVcs: false },
];

function defaultCoordinator(agents: any[], projectId: string) {
  const pool = agents.filter((agent: any) => agent.id && (!projectId || !agent.projectId || agent.projectId === projectId));
  const ranked = [...pool].sort((left: any, right: any) => {
    const score = (agent: any) => {
      const text = `${agent.id} ${agent.label} ${agent.roleHint} ${agent.providerProfile}`.toLowerCase();
      if (text.includes('principal') || text.includes('coordinator') || text.includes('lead')) return 0;
      if (agent.projectId === projectId) return 1;
      return 2;
    };
    return score(left) - score(right);
  });
  return ranked[0]?.id || '';
}

function projectAnchorValue(project: any, type: string, fallback = '') {
  const anchor = (project?.anchors || []).find((item: any) => item.type === type);
  return anchor?.value || fallback;
}

function projectSupportsVcs(project: any) {
  return Boolean(projectAnchorValue(project, 'directory')) && projectAnchorValue(project, 'vcs_kind', 'auto') !== 'none';
}

function buildVcsAnchors(vcsEnabled: boolean, directory: string, vcsKind: string, baseRef: string, worktreeRoot: string) {
  if (!vcsEnabled) return [{ type: 'vcs_kind', value: 'none', note: 'Project VCS disabled from UI' }];
  const anchors = [
    { type: 'directory', value: directory.trim(), note: 'Local project directory used to detect and provision VCS workspaces' },
    { type: 'vcs_kind', value: vcsKind, note: 'VCS backend: auto, git, jj, or none' },
  ].filter((anchor) => anchor.value);
  if (baseRef.trim()) anchors.push({ type: 'base_ref', value: baseRef.trim(), note: 'Default base ref for new workspaces' });
  if (worktreeRoot.trim()) anchors.push({ type: 'worktree_root', value: worktreeRoot.trim(), note: 'Parent directory for provisioned worktrees' });
  return anchors;
}

function NewProjectModal({ creating, error, onClose, onSubmit }: any) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [vcsEnabled, setVcsEnabled] = useState(false);
  const [directory, setDirectory] = useState('');
  const [vcsKind, setVcsKind] = useState('auto');
  const [baseRef, setBaseRef] = useState('');
  const [worktreeRoot, setWorktreeRoot] = useState('');

  const submit = (event: any) => {
    event.preventDefault();
    const cleanName = name.trim();
    if (!cleanName || creating || (vcsEnabled && !directory.trim())) return;
    onSubmit({ name: cleanName, description: description.trim(), anchors: buildVcsAnchors(vcsEnabled, directory, vcsKind, baseRef, worktreeRoot) });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-6">
      <form onSubmit={submit} className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-3xl border border-white/10 bg-[#11141a] p-6 shadow-2xl">
        <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Create project</div>
        <h2 className="mt-2 text-2xl font-semibold">+ New Project</h2>
        <p className="mt-2 text-sm text-zinc-400">Create a project. VCS support is determined by project anchors such as directory, vcs_kind, base_ref, and worktree_root.</p>

        <label className="mt-5 block text-sm text-zinc-300">
          Name
          <input data-debug-id="new-project-name-input" value={name} onChange={(event) => setName(event.target.value)} placeholder="Short project name" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" autoFocus />
        </label>

        <label className="mt-4 block text-sm text-zinc-300">
          Description
          <textarea data-debug-id="new-project-description-textarea" value={description} onChange={(event) => setDescription(event.target.value)} placeholder="Optional project description" rows={3} className="mt-1 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
        </label>

        <div className="mt-4 rounded-2xl border border-white/10 bg-black/20 p-4">
          <label className="flex items-center gap-3 text-sm text-zinc-300">
            <input data-debug-id="new-project-vcs-enabled-checkbox" type="checkbox" checked={vcsEnabled} onChange={(event) => setVcsEnabled(event.target.checked)} className="h-4 w-4" />
            Enable VCS workspaces for chains in this project
          </label>
          <div className="mt-3 grid gap-3 md:grid-cols-2">
            <label className="text-sm text-zinc-300">Project directory / directory
              <input data-debug-id="new-project-directory-input" value={directory} onChange={(event) => setDirectory(event.target.value)} disabled={!vcsEnabled} placeholder="/path/to/project" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50" />
            </label>
            <label className="text-sm text-zinc-300">VCS kind / vcs_kind
              <select data-debug-id="new-project-vcs-kind-select" value={vcsKind} onChange={(event) => setVcsKind(event.target.value)} disabled={!vcsEnabled} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50">
                <option value="auto">auto</option>
                <option value="git">git</option>
                <option value="jj">jj</option>
              </select>
            </label>
            <label className="text-sm text-zinc-300">Base ref / base_ref
              <input data-debug-id="new-project-base-ref-input" value={baseRef} onChange={(event) => setBaseRef(event.target.value)} disabled={!vcsEnabled} placeholder="main" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50" />
            </label>
            <label className="text-sm text-zinc-300">Worktree root / worktree_root
              <input data-debug-id="new-project-worktree-root-input" value={worktreeRoot} onChange={(event) => setWorktreeRoot(event.target.value)} disabled={!vcsEnabled} placeholder="/tmp/heimdall-worktrees/my-project" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-50" />
            </label>
          </div>
          {vcsEnabled && !directory.trim() && <div className="mt-3 text-xs text-amber-200">Project directory is required to enable VCS support.</div>}
        </div>

        {error && <div className="mt-4 rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-200">{error}</div>}

        <div className="mt-6 flex justify-end gap-2">
          <button data-debug-id="new-project-cancel-btn" type="button" onClick={onClose} disabled={creating} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15 disabled:opacity-50">Cancel</button>
          <button data-debug-id="new-project-submit-btn" type="submit" disabled={creating || !name.trim() || (vcsEnabled && !directory.trim())} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{creating ? 'Creating…' : 'Create project'}</button>
        </div>
      </form>
    </div>
  );
}

function NewChainModal({ projectId, projects, agents, creating, error, onClose, onSubmit }: any) {
  const [selectedProjectId, setSelectedProjectId] = useState(projectId || projects[0]?.projectId || '');
  const [title, setTitle] = useState('');
  const [goal, setGoal] = useState('');
  const [kind, setKind] = useState('coding');
  const kindDef = TEAM_KIND_OPTIONS.find((item) => item.key === kind) || TEAM_KIND_OPTIONS[0];
  const [scaffold, setScaffold] = useState('none');
  const [wantsVcs, setWantsVcs] = useState(kindDef.wantsVcs);
  const selectedProject = projects.find((project: any) => project.projectId === selectedProjectId) || null;
  const selectedProjectSupportsVcs = projectSupportsVcs(selectedProject);
  const coordinatorAgentInstanceId = '';

  useEffect(() => {
    const next = TEAM_KIND_OPTIONS.find((item) => item.key === kind) || TEAM_KIND_OPTIONS[0];
    setScaffold('none');
    setWantsVcs(next.wantsVcs && selectedProjectSupportsVcs);
  }, [kind, selectedProjectSupportsVcs]);

  const submit = (event: any) => {
    event.preventDefault();
    const cleanTitle = title.trim();
    if (!cleanTitle || creating) return;
    onSubmit({
      projectId: selectedProjectId,
      title: cleanTitle,
      goal: goal.trim(),
      kind,
      scaffold,
      wantsVcs: wantsVcs && selectedProjectSupportsVcs,
      coordinatorAgentInstanceId,
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-6">
      <form onSubmit={submit} className="w-full max-w-2xl rounded-3xl border border-white/10 bg-[#11141a] p-6 shadow-2xl">
        <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Create chain</div>
        <h2 className="mt-2 text-2xl font-semibold">+ New chain</h2>
        <p className="mt-2 text-sm text-zinc-400">Create a chain. By default this creates only a coordinator task to update the chain from the user requirement; optional scaffolds add draft tasks after coordinator validation.</p>

        <div className="mt-5 grid gap-4 md:grid-cols-2">
          <label className="text-sm text-zinc-300">
            Project
            <select data-debug-id="new-chain-project-select" value={selectedProjectId} onChange={(event) => setSelectedProjectId(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
              {projects.map((project: any) => <option key={project.projectId} value={project.projectId}>{project.name || project.projectId}</option>)}
            </select>
          </label>
          <label className="text-sm text-zinc-300">
            Kind
            <select data-debug-id="new-chain-kind-select" value={kind} onChange={(event) => setKind(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
              {TEAM_KIND_OPTIONS.map((item) => <option key={item.key} value={item.key}>{item.label}</option>)}
            </select>
          </label>
        </div>
        <div data-debug-id="new-chain-kind-description" className="mt-3 rounded-xl bg-white/[0.04] p-3 text-xs text-zinc-400">
          <span className="font-semibold text-zinc-300">{kindDef.label} team:</span> {kindDef.description}
        </div>

        <label className="mt-4 block text-sm text-zinc-300">
          Title
          <input data-debug-id="new-chain-title-input" value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Short action-oriented chain title" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" autoFocus />
        </label>

        {scaffold !== 'none' && (
          <label className="mt-4 block text-sm text-zinc-300">
            Goal
            <textarea data-debug-id="new-chain-goal-textarea" value={goal} onChange={(event) => setGoal(event.target.value)} placeholder="What should this chain accomplish?" rows={4} className="mt-1 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          </label>
        )}

        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <label className="text-sm text-zinc-300">
            Optional task scaffold
            <select data-debug-id="new-chain-scaffold-select" value={scaffold} onChange={(event) => setScaffold(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
              <option value="none">none</option>
              {kindDef.scaffolds.map((item) => <option key={item} value={item}>{item}</option>)}
            </select>
            <div className="mt-1 text-xs text-zinc-500">Non-none scaffolds create draft tasks that depend on coordinator validation.</div>
          </label>
          <label className="flex items-center gap-3 rounded-xl border border-white/10 bg-black/20 px-3 py-3 text-sm text-zinc-300">
            <input data-debug-id="new-chain-vcs-checkbox" type="checkbox" checked={wantsVcs && selectedProjectSupportsVcs} disabled={!selectedProjectSupportsVcs} onChange={(event) => setWantsVcs(event.target.checked)} className="h-4 w-4" />
            Use VCS workspace if project supports it
          </label>
        </div>
        <div data-debug-id="new-chain-project-vcs-status" className="mt-3 rounded-xl bg-white/[0.04] p-3 text-xs text-zinc-500">
          Project VCS: {selectedProjectSupportsVcs ? `enabled via ${projectAnchorValue(selectedProject, 'vcs_kind', 'auto')} repo ${projectAnchorValue(selectedProject, 'directory')}` : 'disabled — add directory/vcs_kind anchors in project settings'}
        </div>

        <div data-debug-id="new-chain-coordinator-preview" className="mt-4 rounded-xl bg-white/[0.04] p-3 text-xs text-zinc-500">Coordinator: generated on create as coordinator@project-chain</div>
        {error && <div className="mt-4 rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-200">{error}</div>}

        <div className="mt-6 flex justify-end gap-2">
          <button data-debug-id="new-chain-cancel-btn" type="button" onClick={onClose} disabled={creating} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15 disabled:opacity-50">Cancel</button>
          <button data-debug-id="new-chain-submit-btn" type="submit" disabled={creating || !title.trim()} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{creating ? 'Creating…' : 'Create chain'}</button>
        </div>
      </form>
    </div>
  );
}
