import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import SettingsPage from './SettingsPage';
import {
  agentLifecycleEventReceived,
  agentRuntimeEventReceived,
  fetchPreferences,
  fetchSelectedChat,
  refreshAgents,
  registerSession,
  updateSessionConfig,
  userWsConnected,
  userWsConnecting,
  userWsDisconnected,
  userWsError,
} from '../store/chatSlice';
import { addCommentToSelectedTask, fetchSelectedTaskLog, fetchTasksForChain, nudgeSelectedTask, refreshTaskBoard, taskEventReceived, updateChainStateDirectly, updateSelectedTaskStatus, updateTaskStateDirectly, voteOnAttentionTask, voteOnSelectedTask } from '../store/taskSlice';
import { refreshProjects } from '../store/projectSlice';
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
import './useUrlParams';

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
  return 'bg-zinc-500/15 text-zinc-200 border-zinc-500/30';
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

function attentionCount(tasksById: Record<string, any>) {
  return Object.values(tasksById).filter((t: any) => t.status === 'blocked' || t.status === 'review_ready').length;
}

export default function App() {
  const dispatch = useDispatch<any>();
  const { agents, session, daemonProfiles, selectedAgentId } = useSelector((state: any) => state.chat);
  const { projectsById, projectIds } = useSelector((state: any) => state.projects);
  const { chainsById, tasksById, chainTaskIds, taskLogsByTaskId, loading } = useSelector((state: any) => state.tasks);
  const home = useSelector((state: any) => state.home);
  const chainView = useSelector((state: any) => state.chainView);
  const sessionRef = useRef(session);
  const chainViewRef = useRef(chainView);
  const chainsByIdRef = useRef(chainsById);
  const selectedAgentIdRef = useRef(selectedAgentId);
  useEffect(() => { sessionRef.current = session; }, [session]);
  useEffect(() => { chainViewRef.current = chainView; }, [chainView]);
  useEffect(() => { chainsByIdRef.current = chainsById; }, [chainsById]);
  useEffect(() => { selectedAgentIdRef.current = selectedAgentId; }, [selectedAgentId]);

  const projects: Project[] = useMemo(() => {
    const known = projectIds.map((id: string) => projectsById[id]).filter(Boolean);
    if (known.length > 0) return known;
    return [{ projectId: 'default', name: 'Default project', description: 'Chains without an explicit project.' }];
  }, [projectIds, projectsById]);

  const chains: Chain[] = useMemo(() => Object.values(chainsById || {}) as Chain[], [chainsById]);
  const selectedProjectId = home.selectedProjectId || projects[0]?.projectId || 'default';
  const selectedChain = home.selectedChainId ? chainsById[home.selectedChainId] : null;
  const badgeCount = attentionCount(tasksById || {});

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
    dispatch(registerSession())
      .unwrap()
      .then(() => loadHomeData(false, attempt ? `startup-retry-${attempt}` : 'startup'))
      .catch(() => {
        if (attempt < 5) window.setTimeout(() => connectSession(attempt + 1), 750);
      });
  }, [dispatch, loadHomeData]);

  useEffect(() => { connectSession(); }, [connectSession]);

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
          const focused = chainViewRef.current.focusedChainId;
          const chain = focused ? chainsByIdRef.current[focused] : null;
          if (focused && chain?.coordinatorAgentInstanceId === payload.agent_instance_id) {
            dispatch(wsChainViewRefreshRequested(`chat_event:${payload.message_id || ''}`));
            dispatch(revalidateChainView(focused));
          }
          const selectedDirectAgent = selectedAgentIdRef.current;
          if (selectedDirectAgent && selectedDirectAgent === payload.agent_instance_id) {
            dispatch(fetchSelectedChat({ agentId: selectedDirectAgent }));
          }
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

  const openProject = useCallback((projectId: string) => {
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

  return (
    <div className="h-screen overflow-hidden bg-[#08090b] text-zinc-100">
      <div className="flex h-full">
        <aside className="w-64 shrink-0 border-r border-white/10 bg-[#0d0f14] flex flex-col">
          <div className="px-3 py-3 border-b border-white/10">
            <div className="text-[10px] uppercase tracking-[0.18em] text-zinc-500">Heimdall Teams</div>
            <div className="mt-0.5 text-base font-semibold">Chains</div>
            <div className="mt-1 text-[10px] text-zinc-500 truncate">{session.daemonUrl}</div>
          </div>
          <nav className="px-2 py-2 border-b border-white/10 flex gap-1">
            <button data-debug-id="nav-home-btn" onClick={() => dispatch(selectSurface('home'))} className={`rounded-full px-2 py-1.5 text-xs ${home.surface === 'home' ? 'bg-white text-black' : 'bg-white/5 hover:bg-white/10'}`}>Home</button>
            <button data-debug-id="nav-attention-btn" onClick={() => dispatch(selectSurface('attention'))} className={`rounded-full px-2 py-1.5 text-xs ${home.surface === 'attention' ? 'bg-white text-black' : 'bg-white/5 hover:bg-white/10'}`}>Attention <span className="ml-1 rounded-full bg-amber-400 px-1 text-black">{badgeCount}</span></button>
            <button data-debug-id="nav-settings-btn" onClick={() => dispatch(selectSurface('settings'))} className={`rounded-full px-2 py-1.5 text-xs ${home.surface === 'settings' ? 'bg-white text-black' : 'bg-white/5 hover:bg-white/10'}`}>Settings</button>
          </nav>
          <div className="min-h-0 flex-1 overflow-y-auto p-2 space-y-2">
            {projects.map((project) => {
              const projectChains = chains.filter((chain) => chainProjectId(chain) === project.projectId || (project.projectId === 'default' && !chain.projectId));
              return (
                <section key={project.projectId} className="rounded-xl border border-white/10 bg-white/[0.03] p-2">
                  <button data-debug-id={`sidebar-project-${project.projectId}`} onClick={() => openProject(project.projectId)} className="w-full truncate text-left text-xs font-medium hover:text-white text-zinc-200">{project.name || project.projectId}</button>
                  <div className="mt-1 space-y-0.5">
                    {projectChains.map((chain) => (
                      <button key={chain.chainId} data-debug-id={`sidebar-chain-${chain.chainId}`} onClick={() => openChain(chain.chainId)} className={`w-full rounded-lg px-2 py-1.5 text-left text-[11px] transition ${home.selectedChainId === chain.chainId ? 'bg-sky-500/20 text-sky-100' : 'hover:bg-white/5 text-zinc-400'}`}>
                        <div className="truncate font-medium">{chain.title || chain.chainId}</div>
                        <span className={`mt-0.5 inline-flex rounded-full border px-1.5 py-0 text-[9px] ${statusTone(chain.status)}`}>{chain.status}</span>
                      </button>
                    ))}
                  </div>
                  <button data-debug-id={`sidebar-new-chain-btn-${project.projectId}`} onClick={() => dispatch(openNewChainModal({ projectId: project.projectId }))} className="mt-2 w-full rounded-lg border border-dashed border-white/20 py-1.5 text-[11px] text-zinc-300 hover:border-sky-400 hover:text-sky-200">+ New chain</button>
                </section>
              );
            })}
          </div>
          <div className="p-2 border-t border-white/10">
            <button data-debug-id="home-new-project-btn" onClick={() => dispatch(selectSurface('settings'))} className="w-full rounded-lg bg-white/5 py-1.5 text-xs hover:bg-white/10">+ New Project</button>
          </div>
        </aside>

        <main className="min-w-0 flex-1 overflow-y-auto">
          {home.surface === 'settings' ? (
            <SettingsPage session={session} onBack={() => dispatch(selectSurface('home'))} onReconnect={(config: any) => { dispatch(updateSessionConfig(config)); window.setTimeout(connectSession, 0); }} />
          ) : home.surface === 'chain' && selectedChain ? (
            <ChainView
              chain={selectedChain}
              tasks={(chainTaskIds[selectedChain.chainId] || []).map((id: string) => tasksById[id]).filter(Boolean)}
              agents={agents}
              chainView={chainView}
              taskLogsByTaskId={taskLogsByTaskId}
              onBack={() => dispatch(selectSurface('home'))}
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
              onAddComment={async (task: any, body: string) => { await dispatch(addCommentToSelectedTask({ taskId: task.taskId, chainId: task.chainId, body })); dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId)); }}
              onSetTaskStatus={async (task: any, status: string, body: string) => { await dispatch(updateSelectedTaskStatus({ taskId: task.taskId, chainId: task.chainId, status, body })); dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId)); }}
              onVoteTask={async (task: any, approved: boolean) => { await dispatch(voteOnSelectedTask({ taskId: task.taskId, chainId: task.chainId, approved, comment: approved ? 'LGTM from ChainView.' : 'Changes requested from ChainView.' })); dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId)); }}
              onNudgeTask={async (task: any, body: string) => { await dispatch(nudgeSelectedTask({ taskId: task.taskId, chainId: task.chainId, body, interrupt: false })); dispatch(fetchTasksForChain(task.chainId)); dispatch(fetchSelectedTaskLog(task.taskId)); }}
            />
          ) : home.surface === 'attention' ? (
            <AttentionPlaceholder
              tasksById={tasksById}
              chainsById={chainsById}
              openChain={openChain}
              onVote={(task: any, approved: boolean) => dispatch(voteOnAttentionTask({ taskId: task.taskId, chainId: task.chainId, approved }))}
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
      </div>
      {home.newChainModalOpen && (
        <NewChainModal
          projectId={home.selectedProjectId || selectedProjectId}
          projects={projects}
          agents={agents}
          creating={home.newChainCreating}
          error={home.newChainError}
          onClose={() => dispatch(closeNewChainModal())}
          onSubmit={(payload: any) => dispatch(submitNewChain(payload))}
        />
      )}
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

function AttentionPlaceholder({ tasksById, chainsById, openChain, onVote }: any) {
  const waiting = Object.values(tasksById || {}).filter((task: any) => task.status === 'blocked' || task.status === 'review_ready') as any[];
  const isUserProxyApproval = (task: any) => task.status === 'review_ready' && (task.participants || []).some((participant: any) => participant.agentInstanceId === 'user_proxy' && participant.role === 'lgtm_required');
  return (
    <div className="mx-auto max-w-5xl px-8 py-8">
      <div className="text-xs uppercase tracking-[0.25em] text-zinc-500">Needs attention</div>
      <h1 className="mt-2 text-4xl font-semibold">Approvals and blocked work</h1>
      <div className="mt-8 space-y-3">
        {waiting.length === 0 ? <div className="rounded-2xl border border-white/10 p-5 text-zinc-400">No attention items loaded.</div> : waiting.map((task: any) => {
          const approval = isUserProxyApproval(task);
          return (
            <div key={task.taskId} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <div className="font-semibold">{chainsById[task.chainId]?.title || task.chainId || 'Standalone'} · {task.title}</div>
              <div className="mt-1 text-sm text-zinc-400">{task.status} · {approval ? 'waiting for user approval' : (task.notActionableReason || 'waiting')}</div>
              <div className="mt-3 flex flex-wrap gap-2">
                {approval && <>
                  <button data-debug-id={`attention-approval-${task.taskId}-approve-btn`} onClick={() => onVote(task, true)} className="rounded-xl bg-emerald-400 px-3 py-2 text-sm font-semibold text-black hover:bg-emerald-300">Approve</button>
                  <button data-debug-id={`attention-approval-${task.taskId}-reject-btn`} onClick={() => onVote(task, false)} className="rounded-xl bg-red-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-red-300">Reject</button>
                </>}
                {task.chainId && <button data-debug-id={`attention-blocked-${task.taskId}-open-btn`} onClick={() => openChain(task.chainId)} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Open chain</button>}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ChainView({ chain, tasks, agents, chainView, taskLogsByTaskId, onBack, onSend, onToggleDiff, onRescan, onPreviewMerge, onOpenAgent, onOpenTask, onAddComment, onSetTaskStatus, onVoteTask, onNudgeTask }: any) {
  const [draft, setDraft] = useState('');
  const [selectedTaskId, setSelectedTaskId] = useState('');
  const [commentDraft, setCommentDraft] = useState('');
  const [nudgeDraft, setNudgeDraft] = useState('Please take a look at this task when you are available.');
  const team = chainView.teamByChainId[chain.chainId];
  const members = team?.members || [];
  const agentsByRecordId = new Map<string, any>(agents.map((agent: any) => [agent.agentRecordId, agent]));
  const roster = members.map((member: any) => {
    const agent = member.agent_record_id ? agentsByRecordId.get(member.agent_record_id) : null;
    const memberId = agent?.id || member.agent_instance_id || member.agentInstanceId || member.route_to || `${member.role_key}-${member.role_index}`;
    return agent || {
      id: memberId,
      label: member.route_to || member.agent_instance_id || member.agentInstanceId || `${member.role_key} ${member.role_index + 1}`,
      state: member.lifecycle_status || 'missing',
      status: member.lifecycle_status || 'missing',
      roleKey: member.role_key,
      roleIndex: member.role_index,
      isUserProxy: Boolean(member.is_user_proxy),
    };
  });
  const workspace = chainView.workspaceByChainId[chain.chainId];
  const chat = chainView.chatByChainId[chain.chainId] || [];
  const optimistic = (chainView.optimisticMessagesByChainId[chain.chainId] || []).filter((msg: any) => msg.sending);
  const messages = [...chat, ...optimistic];
  const diffOpen = Boolean(chainView.diffOpenByChainId[chain.chainId]);
  const preview = chainView.mergePreviewByChainId[chain.chainId];
  const selectedTask = tasks.find((task: any) => task.taskId === selectedTaskId) || null;
  const taskLog = selectedTask ? (taskLogsByTaskId?.[selectedTask.taskId] || []) : [];
  const comments = taskLog.filter((event: any) => event.kind === 'Task_Comment');
  const reviewEvents = taskLog.filter((event: any) => event.kind === 'Task_Review_Vote');
  const votes = selectedTask?.votes || [];
  const taskGroups = [
    { key: 'planning', title: 'Planning', statuses: ['planning'] },
    { key: 'ready', title: 'Queued / ready', statuses: ['queued', 'ready'] },
    { key: 'in_progress', title: 'In progress', statuses: ['in_progress'] },
    { key: 'review_ready', title: 'Review', statuses: ['review_ready'] },
    { key: 'blocked', title: 'Blocked', statuses: ['blocked'] },
    { key: 'done', title: 'Approved / done', statuses: ['approved', 'done', 'completed'] },
  ];
  const openTask = (task: any) => {
    setSelectedTaskId(task.taskId);
    setCommentDraft('');
    onOpenTask?.(task.taskId);
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
            <span data-debug-id="chain-http-load-evidence" className="rounded-full bg-white/5 px-3 py-1 text-xs text-zinc-500">HTTP load {chainView.lastHttpLoadByChainId[chain.chainId] ? new Date(chainView.lastHttpLoadByChainId[chain.chainId]).toLocaleTimeString() : 'pending'}</span>
            <span data-debug-id="chain-ws-evidence" className="rounded-full bg-white/5 px-3 py-1 text-xs text-zinc-500">WS {chainView.lastWsRefreshReason || 'none yet'}</span>
            <span data-debug-id="chain-local-action-evidence" className="rounded-full bg-white/5 px-3 py-1 text-xs text-zinc-500">Local {chainView.lastLocalAction || 'none yet'}</span>
          </div>
        </div>
        <div className="flex gap-2">
          <button data-debug-id="chain-pause-btn" className="rounded-xl bg-white/5 px-4 py-2 text-sm text-zinc-400" disabled>Pause chain</button>
          <button data-debug-id="chain-complete-btn" className="rounded-xl bg-white/5 px-4 py-2 text-sm text-zinc-400" disabled>Complete chain</button>
          <button data-debug-id="chain-attention-link" className="rounded-xl bg-amber-400/15 px-4 py-2 text-sm text-amber-100">Needs attention</button>
        </div>
      </div>

      <div className="mt-8 grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
        <section className="flex min-h-[calc(100vh-15rem)] flex-col rounded-2xl border border-white/10 bg-white/[0.035] p-4">
          <h2 className="font-semibold">Coordinator chat</h2>
          <div className="mt-4 min-h-0 flex-1 space-y-3 overflow-y-auto rounded-xl bg-black/20 p-4">
            {messages.length === 0 ? <div className="text-sm text-zinc-500">No coordinator chat loaded for this chain.</div> : messages.map((msg: any, index: number) => (
              <div key={msg.message_id || msg.id || index} className={`rounded-2xl px-4 py-3 text-sm ${msg.author === 'user' || msg.direction === 'user_to_agent' ? 'ml-8 bg-sky-500/15 text-sky-100' : 'mr-8 bg-white/5 text-zinc-200'}`}>
                <div>{msg.body}</div>
                {msg.sending && <div className="mt-1 text-[10px] uppercase tracking-wider text-sky-300">sending…</div>}
              </div>
            ))}
          </div>
          <div className="mt-4 flex gap-2">
            <input
              data-debug-id="chain-coordinator-composer-input"
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => { if (event.key === 'Enter') submit(); }}
              placeholder="Message coordinator only…"
              className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
            />
            <button data-debug-id="chain-coordinator-send-btn" onClick={submit} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300">Send</button>
          </div>
          <p className="mt-2 text-xs text-zinc-500">Sending routes to the chain coordinator. Opening this view records focus and warms the chain team when needed.</p>
        </section>

        <aside className="space-y-4">
          {hasWorkspace && (
            <WorkspaceBox
              chainId={chain.chainId}
              workspace={workspace}
              preview={preview}
              diffOpen={diffOpen}
              onToggleDiff={onToggleDiff}
              onRescan={onRescan}
              onPreviewMerge={onPreviewMerge}
            />
          )}
          <section className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
            <h2 className="font-semibold">Team roster</h2>
            <div className="mt-3 space-y-2">
              {roster.length === 0 ? <div className="text-sm text-zinc-500">No team members loaded for this chain.</div> : roster.map((agent: any) => {
                const blocked = agent.state === 'blocked' || agent.status === 'startup_blocked' || agent.blockedReason;
                return (
                  <button key={agent.id} data-debug-id={`chain-roster-row-${agent.id}`} onClick={() => onOpenAgent(agent.id)} className={`w-full rounded-xl px-3 py-2 text-left text-sm ${blocked ? 'bg-red-500/10 text-red-100 border border-red-500/20' : 'bg-white/5 text-zinc-200'}`}>
                    <div className="font-medium">{agent.label || agent.id}</div>
                    <div className="text-xs text-zinc-500">{agent.roleKey ? `${agent.roleKey} · ` : ''}{agent.currentTaskId ? `current task ${agent.currentTaskId}` : 'idle'} · {agent.state || agent.status || 'known'}</div>
                    {blocked && <div className="mt-1 text-xs text-red-300">{agent.blockedReason || 'blocked'}</div>}
                  </button>
                );
              })}
            </div>
            <div className="mt-4 rounded-xl bg-black/20 p-3 text-sm text-zinc-400">{tasks.length} task(s) loaded for this chain.</div>
          </section>
        </aside>
      </div>

      <section data-debug-id="chain-task-surface" className="mt-8 rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h2 className="font-semibold">Chain tasks</h2>
            <p className="text-xs text-zinc-500">Tasks are scoped to this chain and its team members.</p>
          </div>
          <span data-debug-id="chain-task-count" className="rounded-full bg-white/5 px-3 py-1 text-xs text-zinc-400">{tasks.length} tasks</span>
        </div>
        <div className="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {taskGroups.map((group) => {
            const groupTasks = tasks.filter((task: any) => group.statuses.includes(task.status));
            return (
              <div key={group.key} data-debug-id={`chain-task-column-${group.key}`} className="rounded-xl bg-black/20 p-3">
                <div className="mb-2 flex items-center justify-between text-xs uppercase tracking-wide text-zinc-500"><span>{group.title}</span><span>{groupTasks.length}</span></div>
                <div className="space-y-2">
                  {groupTasks.length === 0 ? <div className="rounded-lg border border-dashed border-white/10 p-3 text-xs text-zinc-600">No tasks</div> : groupTasks.map((task: any) => (
                    <button key={task.taskId} data-debug-id={`chain-task-card-${task.taskId}`} onClick={() => openTask(task)} className="w-full rounded-lg bg-white/[0.055] p-3 text-left text-sm hover:bg-white/[0.09]">
                      <div className="font-medium text-zinc-100">{task.title || task.taskId}</div>
                      <div className="mt-1 flex flex-wrap gap-1 text-[11px] text-zinc-500">
                        <span>{task.status}</span><span>·</span><span>{task.assigneeAgentInstanceId || 'unassigned'}</span>
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {selectedTask && (
        <div data-debug-id="task-detail-drawer" className="fixed inset-0 z-50 flex justify-end bg-black/50">
          <aside className="h-full w-[32rem] max-w-full overflow-y-auto border-l border-white/10 bg-[#0d0f14] p-5 shadow-2xl">
            <div className="flex items-start justify-between gap-3">
              <div>
                <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Task detail</div>
                <h2 data-debug-id="task-detail-title" className="mt-2 text-2xl font-semibold">{selectedTask.title || selectedTask.taskId}</h2>
              </div>
              <button data-debug-id="task-detail-close-btn" onClick={() => setSelectedTaskId('')} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Close</button>
            </div>
            <div className="mt-4 flex flex-wrap gap-2 text-xs">
              <span data-debug-id="task-detail-status" className={`rounded-full border px-3 py-1 ${statusTone(selectedTask.status)}`}>{selectedTask.status}</span>
              <span className="rounded-full bg-white/5 px-3 py-1 text-zinc-400">Assignee {selectedTask.assigneeAgentInstanceId || '—'}</span>
              <span className="rounded-full bg-white/5 px-3 py-1 text-zinc-400">Reviewer {selectedTask.reviewerAgentInstanceId || '—'}</span>
            </div>
            <div data-debug-id="task-detail-description" className="mt-5 whitespace-pre-wrap rounded-xl bg-white/[0.04] p-3 text-sm text-zinc-300">{selectedTask.description || 'No description.'}</div>
            {selectedTask.dependsOn && <InfoRow label="Depends on" value={selectedTask.dependsOn} />}
            <div data-debug-id="task-detail-votes" className="mt-5 rounded-xl bg-white/[0.04] p-3">
              <div className="text-xs uppercase tracking-wider text-zinc-500">Votes / review history</div>
              <div className="mt-3 space-y-2">
                {votes.length === 0 && reviewEvents.length === 0 ? <div className="text-sm text-zinc-500">No votes recorded.</div> : <>
                  {votes.map((vote: any, index: number) => (
                    <div key={`vote-${index}`} data-debug-id={`task-detail-vote-${index}`} className="rounded-lg bg-black/20 p-2 text-sm text-zinc-300">
                      <div className="text-[10px] uppercase tracking-wider text-zinc-500">{vote.reviewerAgentInstanceId || 'reviewer'} · {vote.approved ? 'LGTM' : 'NGTM'}</div>
                      {vote.comment && <div className="mt-1 whitespace-pre-wrap">{vote.comment}</div>}
                    </div>
                  ))}
                  {reviewEvents.map((event: any, index: number) => (
                    <div key={event.eventId || `review-${index}`} data-debug-id={`task-detail-review-event-${index}`} className="rounded-lg bg-black/20 p-2 text-sm text-zinc-300">
                      <div className="text-[10px] uppercase tracking-wider text-zinc-500">{event.authorAgentInstanceId || 'review'} · review event</div>
                      <div className="mt-1 whitespace-pre-wrap">{event.body || event.status || 'vote recorded'}</div>
                    </div>
                  ))}
                </>}
              </div>
            </div>
            <div className="mt-5 grid grid-cols-2 gap-2">
              <button data-debug-id="task-detail-status-done-btn" onClick={() => onSetTaskStatus(selectedTask, 'review_ready', 'Submitted for review from ChainView.')} className="rounded-xl bg-emerald-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-emerald-300">Done / review</button>
              <button data-debug-id="task-detail-status-block-btn" onClick={() => onSetTaskStatus(selectedTask, 'blocked', 'Blocked from ChainView.')} className="rounded-xl bg-amber-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-amber-300">Block</button>
              <button data-debug-id="task-detail-status-later-btn" onClick={() => onSetTaskStatus(selectedTask, 'queued', 'Moved later from ChainView.')} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Later</button>
              <button data-debug-id="task-detail-status-start-btn" onClick={() => onSetTaskStatus(selectedTask, 'in_progress', 'Started from ChainView.')} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Start</button>
              <button data-debug-id="task-detail-vote-lgtm-btn" onClick={() => onVoteTask(selectedTask, true)} className="rounded-xl bg-sky-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-sky-300">LGTM</button>
              <button data-debug-id="task-detail-vote-ngtm-btn" onClick={() => onVoteTask(selectedTask, false)} className="rounded-xl bg-red-400/90 px-3 py-2 text-sm font-semibold text-black hover:bg-red-300">NGTM</button>
            </div>
            <div className="mt-5 rounded-xl bg-white/[0.04] p-3">
              <div className="text-xs uppercase tracking-wider text-zinc-500">Nudge</div>
              <textarea data-debug-id="task-detail-nudge-textarea" value={nudgeDraft} onChange={(event) => setNudgeDraft(event.target.value)} rows={2} className="mt-2 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              <button data-debug-id="task-detail-nudge-btn" onClick={() => onNudgeTask(selectedTask, nudgeDraft)} className="mt-2 rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Send nudge</button>
            </div>
            <div className="mt-5 rounded-xl bg-white/[0.04] p-3">
              <div className="text-xs uppercase tracking-wider text-zinc-500">Comments</div>
              <div data-debug-id="task-detail-comments" className="mt-3 space-y-2">
                {comments.length === 0 ? <div className="text-sm text-zinc-500">No comments loaded.</div> : comments.map((comment: any, index: number) => (
                  <div key={comment.commentId || index} data-debug-id={`task-detail-comment-${index}`} className="rounded-lg bg-black/20 p-2 text-sm text-zinc-300">
                    <div className="text-[10px] uppercase tracking-wider text-zinc-500">{comment.authorAgentInstanceId || 'comment'}</div>
                    <div className="mt-1 whitespace-pre-wrap">{comment.body}</div>
                  </div>
                ))}
              </div>
              <textarea data-debug-id="task-detail-comment-textarea" value={commentDraft} onChange={(event) => setCommentDraft(event.target.value)} rows={3} placeholder="Add a task comment…" className="mt-3 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
              <button data-debug-id="task-detail-comment-submit-btn" onClick={() => { const body = commentDraft.trim(); if (!body) return; onAddComment(selectedTask, body); setCommentDraft(''); }} className="mt-2 rounded-xl bg-sky-400 px-3 py-2 text-sm font-semibold text-black hover:bg-sky-300">Add comment</button>
            </div>
          </aside>
        </div>
      )}
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
  { key: 'coding', label: 'Coding', scaffolds: ['feature', 'bugfix', 'refactor'], wantsVcs: true },
  { key: 'research', label: 'Research', scaffolds: ['report', 'spike'], wantsVcs: false },
  { key: 'debugging', label: 'Debugging', scaffolds: ['bug', 'incident'], wantsVcs: true },
  { key: 'data-analysis', label: 'Data analysis', scaffolds: ['analysis'], wantsVcs: true },
  { key: 'writing', label: 'Writing', scaffolds: ['article'], wantsVcs: true },
  { key: 'ops', label: 'Ops', scaffolds: ['chore'], wantsVcs: true },
  { key: 'solo', label: 'Solo', scaffolds: ['solo'], wantsVcs: false },
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

function NewChainModal({ projectId, projects, agents, creating, error, onClose, onSubmit }: any) {
  const [selectedProjectId, setSelectedProjectId] = useState(projectId || projects[0]?.projectId || '');
  const [title, setTitle] = useState('');
  const [goal, setGoal] = useState('');
  const [kind, setKind] = useState('coding');
  const kindDef = TEAM_KIND_OPTIONS.find((item) => item.key === kind) || TEAM_KIND_OPTIONS[0];
  const [scaffold, setScaffold] = useState(kindDef.scaffolds[0] || 'none');
  const [wantsVcs, setWantsVcs] = useState(kindDef.wantsVcs);
  const coordinatorAgentInstanceId = defaultCoordinator(agents, selectedProjectId);

  useEffect(() => {
    const next = TEAM_KIND_OPTIONS.find((item) => item.key === kind) || TEAM_KIND_OPTIONS[0];
    setScaffold(next.scaffolds[0] || 'none');
    setWantsVcs(next.wantsVcs);
  }, [kind]);

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
      wantsVcs,
      coordinatorAgentInstanceId,
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-6">
      <form onSubmit={submit} className="w-full max-w-2xl rounded-3xl border border-white/10 bg-[#11141a] p-6 shadow-2xl">
        <div className="text-xs uppercase tracking-[0.2em] text-zinc-500">Create chain</div>
        <h2 className="mt-2 text-2xl font-semibold">+ New chain</h2>
        <p className="mt-2 text-sm text-zinc-400">Create a chain and refresh Home/Sidebar automatically after the daemon persists it.</p>

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

        <label className="mt-4 block text-sm text-zinc-300">
          Title
          <input data-debug-id="new-chain-title-input" value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Short action-oriented chain title" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" autoFocus />
        </label>

        <label className="mt-4 block text-sm text-zinc-300">
          Goal
          <textarea data-debug-id="new-chain-goal-textarea" value={goal} onChange={(event) => setGoal(event.target.value)} placeholder="What should this chain accomplish?" rows={4} className="mt-1 w-full resize-none rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
        </label>

        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <label className="text-sm text-zinc-300">
            Scaffold
            <select data-debug-id="new-chain-scaffold-select" value={scaffold} onChange={(event) => setScaffold(event.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
              {kindDef.scaffolds.map((item) => <option key={item} value={item}>{item}</option>)}
              <option value="none">none</option>
            </select>
          </label>
          <label className="flex items-center gap-3 rounded-xl border border-white/10 bg-black/20 px-3 py-3 text-sm text-zinc-300">
            <input data-debug-id="new-chain-vcs-checkbox" type="checkbox" checked={wantsVcs} onChange={(event) => setWantsVcs(event.target.checked)} className="h-4 w-4" />
            Use VCS workspace if project supports it
          </label>
        </div>

        <div className="mt-4 rounded-xl bg-white/[0.04] p-3 text-xs text-zinc-500">Coordinator: {coordinatorAgentInstanceId || 'No eligible coordinator agent found'}</div>
        {error && <div className="mt-4 rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-sm text-red-200">{error}</div>}

        <div className="mt-6 flex justify-end gap-2">
          <button data-debug-id="new-chain-cancel-btn" type="button" onClick={onClose} disabled={creating} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15 disabled:opacity-50">Cancel</button>
          <button data-debug-id="new-chain-submit-btn" type="submit" disabled={creating || !title.trim() || !coordinatorAgentInstanceId} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{creating ? 'Creating…' : 'Create chain'}</button>
        </div>
      </form>
    </div>
  );
}
