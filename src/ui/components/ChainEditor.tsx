import { useEffect, useMemo, useRef, useState, type PointerEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { VimEditButton } from './VimSidebar';
import AgentPicker from './AgentPicker';
import { showToast } from '../store/toastSlice';
import { tasksApi } from '../api/endpoints/tasks';
import { agentsApi } from '../api/endpoints/agents';
import { workspaceApi } from '../api/endpoints/workspace';
import { useListConversationSummariesQuery } from '../api/endpoints/chats';

const NODE_W = 180;
const NODE_H = 92;
const H_GAP = 285;
const V_GAP = 128;
const STORAGE_PREFIX = 'heimdall.chainEditor.layout.v1:';
const PARTICIPANT_ROLES = ['lgtm_required', 'lgtm_optional', 'subscriber'];

type Point = { x: number; y: number };
type TaskLike = {
  taskId?: string;
  id?: string;
  title?: string;
  status?: string;
  description?: string;
  acceptanceCriteria?: string;
  acceptance_criteria?: string;
  assigneeAgentInstanceId?: string;
  assignee_agent_instance_id?: string;
  reviewerAgentInstanceId?: string;
  reviewer_agent_instance_id?: string;
  dependsOn?: string;
  depends_on?: string;
  notActionableReason?: string;
  not_actionable_reason?: string;
  participants?: Array<{ agentInstanceId?: string; agent_instance_id?: string; role?: string }>;
};

type ChainEditorProps = {
  chain: any;
  tasks: TaskLike[];
  tasksById?: Record<string, TaskLike>;
  team?: any;
  agents?: any[];
  identities?: any[];
  providers?: any[];
  initialTaskId?: string;
  onBack: () => void;
  onReturnToChain: () => void;
  onSelectTask?: (taskId: string) => void;
};

function taskId(task: TaskLike): string { return task.taskId || task.id || ''; }
function taskDependsOn(task: TaskLike): string[] {
  const raw = task.dependsOn ?? task.depends_on ?? '';
  return String(raw || '').split(',').map((id) => id.trim()).filter(Boolean);
}
function taskAssignee(task: TaskLike): string { return task.assigneeAgentInstanceId || task.assignee_agent_instance_id || ''; }
function taskReviewer(task: TaskLike): string {
  const participant = (task.participants || []).find((p) => p.role === 'lgtm_required');
  return task.reviewerAgentInstanceId || task.reviewer_agent_instance_id || participant?.agentInstanceId || participant?.agent_instance_id || '';
}
function taskReviewers(task: TaskLike): string[] {
  const reviewers = (task.participants || []).filter((p) => p.role === 'lgtm_required').map((p) => p.agentInstanceId || p.agent_instance_id || '').filter(Boolean);
  const primary = task.reviewerAgentInstanceId || task.reviewer_agent_instance_id || '';
  return Array.from(new Set([primary, ...reviewers].filter(Boolean)));
}
function taskAcceptance(task: TaskLike): string { return task.acceptanceCriteria ?? task.acceptance_criteria ?? ''; }
function participantAgentId(participant: { agentInstanceId?: string; agent_instance_id?: string }): string { return participant.agentInstanceId || participant.agent_instance_id || ''; }
function participantRole(participant: { role?: string }): string { return participant.role || ''; }
function participantRoleLabel(role: string): string {
  if (role === 'lgtm_required') return 'Required reviewer';
  if (role === 'lgtm_optional') return 'Optional reviewer';
  if (role === 'subscriber') return 'Subscriber';
  return role || 'Participant';
}
function taskBlockedReason(task: TaskLike): string { return task.notActionableReason || task.not_actionable_reason || ''; }
function shortId(id: string): string { return id.length > 14 ? `${id.slice(0, 10)}…` : id; }
function initials(agentId: string): string {
  if (!agentId) return '—';
  const local = agentId.split('@')[0] || agentId;
  const parts = local.split(/[-_.]/).filter(Boolean);
  const letters = (parts.length > 1 ? parts.slice(0, 2).map((p) => p[0]) : local.slice(0, 2).split('')).join('');
  return letters.toUpperCase();
}
function statusTone(status = ''): string {
  if (status === 'approved' || status === 'completed') return 'border-emerald-400/30 bg-emerald-400/10 text-emerald-100';
  if (status === 'in_progress') return 'border-teal-400/30 bg-teal-400/10 text-teal-100';
  if (status === 'review_ready') return 'border-sky-400/30 bg-sky-400/10 text-sky-100';
  if (status === 'blocked') return 'border-amber-400/30 bg-amber-400/10 text-amber-100';
  if (status === 'planning') return 'border-violet-400/30 bg-violet-400/10 text-violet-100';
  if (status === 'cancelled') return 'border-zinc-600/40 bg-zinc-700/30 text-zinc-400';
  return 'border-zinc-500/30 bg-zinc-500/10 text-zinc-200';
}
function dotTone(status = ''): string {
  if (status === 'approved' || status === 'completed') return 'bg-emerald-300';
  if (status === 'in_progress') return 'bg-teal-300';
  if (status === 'review_ready') return 'bg-sky-300';
  if (status === 'blocked') return 'bg-amber-300';
  if (status === 'planning') return 'bg-violet-300';
  return 'bg-zinc-400';
}
function chainMemberAgentId(member: any): string { return member.agent_instance_id || member.agentInstanceId || member.route_to || ''; }
function runtimeStatus(agent: any): string { return agent?.status || agent?.startupStatus || agent?.connectionState || (agent?.connected ? 'connected' : 'offline'); }
function runtimeTone(status: string): string {
  if (status === 'connected' || status === 'running' || status === 'active') return 'text-emerald-200 border-emerald-400/30 bg-emerald-400/10';
  if (status === 'starting' || status === 'launching') return 'text-sky-100 border-sky-400/30 bg-sky-400/10';
  if (status === 'stopping') return 'text-amber-100 border-amber-400/30 bg-amber-400/10';
  return 'text-zinc-400 border-white/10 bg-white/[0.04]';
}
function providerValue(provider: any): string { return provider?.id || provider?.profile || provider?.provider_profile || provider?.name || String(provider || ''); }
function providerLabel(provider: any): string { return provider?.label || provider?.display_name || providerValue(provider); }
function formatError(err: any): string { return String(err?.message || err || 'Request failed'); }

function buildEdges(tasks: TaskLike[], ids: Set<string>) {
  const edges: Array<{ from: string; to: string }> = [];
  tasks.forEach((task) => {
    const to = taskId(task);
    taskDependsOn(task).forEach((from) => {
      if (ids.has(from) && ids.has(to)) edges.push({ from, to });
    });
  });
  return edges;
}

function autoLayout(tasks: TaskLike[]): Record<string, Point> {
  const ids = new Set(tasks.map(taskId).filter(Boolean));
  const depsByTask = new Map<string, string[]>();
  tasks.forEach((task) => depsByTask.set(taskId(task), taskDependsOn(task).filter((id) => ids.has(id))));
  const depthMemo = new Map<string, number>();
  const visiting = new Set<string>();
  const depthOf = (id: string): number => {
    if (depthMemo.has(id)) return depthMemo.get(id)!;
    if (visiting.has(id)) return 0;
    visiting.add(id);
    const deps = depsByTask.get(id) || [];
    const depth = deps.length ? 1 + Math.max(...deps.map(depthOf)) : 0;
    visiting.delete(id);
    depthMemo.set(id, depth);
    return depth;
  };
  const columns = new Map<number, string[]>();
  tasks.forEach((task) => {
    const id = taskId(task);
    const depth = depthOf(id);
    if (!columns.has(depth)) columns.set(depth, []);
    columns.get(depth)!.push(id);
  });
  const positions: Record<string, Point> = {};
  Array.from(columns.keys()).sort((a, b) => a - b).forEach((depth) => {
    const column = columns.get(depth) || [];
    column.forEach((id, index) => {
      positions[id] = { x: 28 + depth * H_GAP, y: 28 + index * V_GAP };
    });
  });
  return positions;
}

function loadLayout(chainId: string): Record<string, Point> | null {
  try {
    const raw = window.localStorage.getItem(`${STORAGE_PREFIX}${chainId}`);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
  } catch (_err) {
    return null;
  }
}

function saveLayout(chainId: string, positions: Record<string, Point>) {
  try { window.localStorage.setItem(`${STORAGE_PREFIX}${chainId}`, JSON.stringify(positions)); } catch (_err) { /* ignore */ }
}

export default function ChainEditor({ chain, tasks, tasksById = {}, team, agents = [], identities = [], providers = [], initialTaskId = '', onBack, onReturnToChain, onSelectTask }: ChainEditorProps) {
  const dispatch = useDispatch<any>();
  const session = useSelector((state: any) => state.chat?.session || {});
  const conversationSummaryById = useSelector((state: any) => state.chat?.conversationSummaryById || {});
  const conversationSummariesQuery = useListConversationSummariesQuery(undefined, { skip: !session.clientToken });
  const effectiveConversationSummaryById = conversationSummariesQuery.data || conversationSummaryById;
  const auth = { daemonUrl: session.daemonUrl || '', clientInstanceId: session.clientInstanceId || '', clientToken: session.clientToken || '' };
  const orderedTasks = useMemo(() => [...tasks].sort((a, b) => taskId(a).localeCompare(taskId(b))), [tasks]);
  const ids = useMemo(() => new Set(orderedTasks.map(taskId).filter(Boolean)), [orderedTasks]);
  const edges = useMemo(() => buildEdges(orderedTasks, ids), [orderedTasks, ids]);
  const [selectedTaskId, setSelectedTaskId] = useState(initialTaskId || taskId(orderedTasks[0] || {}) || '');
  const [positions, setPositions] = useState<Record<string, Point>>({});
  const [pan, setPan] = useState<Point>({ x: 0, y: 0 });
  const [titleDraft, setTitleDraft] = useState('');
  const [descriptionDraft, setDescriptionDraft] = useState('');
  const [acceptanceDraft, setAcceptanceDraft] = useState('');
  const [newDepId, setNewDepId] = useState('');
  const [newTaskTitle, setNewTaskTitle] = useState('');
  const [newParticipantAgentId, setNewParticipantAgentId] = useState('');
  const [newParticipantRole, setNewParticipantRole] = useState('lgtm_required');
  const [newMemberRole, setNewMemberRole] = useState('specialist');
  const [newMemberAgentId, setNewMemberAgentId] = useState('');
  const [runtimeProviderByAgent, setRuntimeProviderByAgent] = useState<Record<string, string>>({});
  const [runtimeTierByAgent, setRuntimeTierByAgent] = useState<Record<string, string>>({});
  const [chainTitleDraft, setChainTitleDraft] = useState('');
  const [chainDescriptionDraft, setChainDescriptionDraft] = useState('');
  const [chainCoordinatorDraft, setChainCoordinatorDraft] = useState('');
  const [chainReviewerDraft, setChainReviewerDraft] = useState('');
  const [chainRolePicker, setChainRolePicker] = useState<null | 'coordinator' | 'reviewer'>(null);
  const [completeSummaryDraft, setCompleteSummaryDraft] = useState('Completed from Task Chain Editor.');
  const [edgeCreateMode, setEdgeCreateMode] = useState(false);
  const [edgeSourceTaskId, setEdgeSourceTaskId] = useState('');
  const [busyAction, setBusyAction] = useState('');
  const [editorError, setEditorError] = useState('');
  const canvasRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<{ kind: 'node' | 'pan'; id?: string; startClient: Point; startPoint: Point } | null>(null);

  useEffect(() => {
    if (!chain?.chainId) return;
    const stored = loadLayout(chain.chainId) || {};
    const auto = autoLayout(orderedTasks);
    const next: Record<string, Point> = {};
    orderedTasks.forEach((task) => {
      const id = taskId(task);
      const saved = stored[id];
      next[id] = saved && Number.isFinite(saved.x) && Number.isFinite(saved.y) ? saved : auto[id] || { x: 28, y: 28 };
    });
    setPositions(next);
  }, [chain?.chainId, orderedTasks]);

  useEffect(() => {
    if (!chain?.chainId || !Object.keys(positions).length) return;
    saveLayout(chain.chainId, positions);
  }, [chain?.chainId, positions]);

  useEffect(() => {
    if (initialTaskId && ids.has(initialTaskId)) setSelectedTaskId(initialTaskId);
  }, [initialTaskId, ids]);

  const selectedTask = selectedTaskId ? (tasksById[selectedTaskId] || orderedTasks.find((task) => taskId(task) === selectedTaskId)) : null;
  const selectedDeps = selectedTask ? taskDependsOn(selectedTask) : [];
  const dependents = selectedTask ? orderedTasks.filter((task) => taskDependsOn(task).includes(selectedTaskId)).map(taskId) : [];
  const selectedParticipants = useMemo(() => {
    if (!selectedTask) return [] as Array<{ agentInstanceId: string; role: string }>;
    const rows = (selectedTask.participants || []).map((p) => ({ agentInstanceId: participantAgentId(p), role: participantRole(p) })).filter((p) => p.agentInstanceId && p.role);
    const primaryReviewer = selectedTask.reviewerAgentInstanceId || selectedTask.reviewer_agent_instance_id || '';
    if (primaryReviewer && !rows.some((p) => p.agentInstanceId === primaryReviewer && p.role === 'lgtm_required')) rows.unshift({ agentInstanceId: primaryReviewer, role: 'lgtm_required' });
    return rows;
  }, [selectedTask]);
  const members = team?.members || [];
  const chainProjectId = chain.projectId || chain.project_id || '';
  const agentOptions = useMemo(() => Array.from(new Set([
    ...members.map(chainMemberAgentId),
    ...agents.map((agent: any) => agent.id || agent.agentInstanceId || agent.agent_instance_id || ''),
    ...orderedTasks.flatMap((task) => [taskAssignee(task), taskReviewer(task)]),
  ].filter(Boolean))).sort(), [members, agents, orderedTasks]);
  const agentById = useMemo(() => {
    const map: Record<string, any> = {};
    agents.forEach((agent: any) => {
      const id = agent.id || agent.agentInstanceId || agent.agent_instance_id || '';
      if (id) map[id] = agent;
    });
    return map;
  }, [agents]);
  const providerOptions = useMemo(() => {
    const vals = providers.map(providerValue).filter(Boolean);
    return vals.length ? vals : ['pi'];
  }, [providers]);

  useEffect(() => {
    if (!selectedTask) {
      setTitleDraft(''); setDescriptionDraft(''); setAcceptanceDraft(''); setNewDepId('');
      return;
    }
    setTitleDraft(selectedTask.title || '');
    setDescriptionDraft(selectedTask.description || '');
    setAcceptanceDraft(taskAcceptance(selectedTask));
    setNewDepId('');
    setEditorError('');
    // Rehydrate drafts only when the selected task identity changes. Depending
    // on task title/description/acceptance would re-run on background task
    // refreshes and wipe long-form edits mid-typing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTaskId]);

  useEffect(() => {
    setChainTitleDraft(chain.title || '');
    setChainDescriptionDraft(chain.description || '');
    setChainCoordinatorDraft(chain.coordinatorAgentInstanceId || chain.coordinator_agent_instance_id || '');
    setChainReviewerDraft(chain.defaultReviewerAgentInstanceId || chain.default_reviewer_agent_instance_id || '');
    // Rehydrate only when switching chains. Chain metadata refreshes rebuild the
    // chain object and must not clobber in-progress chain description edits.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chain.chainId]);

  const runMutation = async (label: string, fn: () => Promise<any>, successTitle: string, successMessage = '') => {
    if (!auth.clientToken) throw new Error('Not connected to daemon');
    setBusyAction(label);
    setEditorError('');
    try {
      const result = await fn();
      dispatch(showToast({ kind: 'success', title: successTitle, message: successMessage }));
      return result;
    } catch (err: any) {
      const message = formatError(err);
      setEditorError(message);
      dispatch(showToast({ kind: 'error', title: `${successTitle} failed`, message }));
      throw err;
    } finally {
      setBusyAction('');
    }
  };

  const saveSelectedTaskText = async () => {
    if (!selectedTask) return;
    const id = taskId(selectedTask);
    await runMutation('save-text', () => dispatch(tasksApi.endpoints.updateTask.initiate({ taskId: id, chainId: chain.chainId, title: titleDraft, description: descriptionDraft, acceptanceCriteria: acceptanceDraft })).unwrap(), 'Task saved', titleDraft || id);
  };

  const setTaskStatus = async (status: string) => {
    if (!selectedTask || !status || status === selectedTask.status) return;
    const id = taskId(selectedTask);
    await runMutation(`status-${status}`, () => dispatch(tasksApi.endpoints.setTaskStatus.initiate({ taskId: id, chainId: chain.chainId, status, body: 'Status set via Task Chain Editor.' })).unwrap(), 'Task status updated', `${id} → ${status}`);
  };

  const setTaskAssignee = async (agentInstanceId: string) => {
    if (!selectedTask) return;
    const id = taskId(selectedTask);
    await runMutation('assign', () => dispatch(tasksApi.endpoints.assignTask.initiate({ taskId: id, chainId: chain.chainId, agentInstanceId })).unwrap(), 'Assignee updated', agentInstanceId || 'unassigned');
  };

  const addTaskParticipant = async (agentInstanceId: string, role: string) => {
    if (!selectedTask || !agentInstanceId || !role) return;
    const id = taskId(selectedTask);
    await runMutation('add-participant', () => dispatch(tasksApi.endpoints.addTaskParticipant.initiate({ taskId: id, chainId: chain.chainId, agentInstanceId, role })).unwrap(), `${participantRoleLabel(role)} added`, agentInstanceId);
  };

  const removeTaskParticipant = async (agentInstanceId: string, role: string) => {
    if (!selectedTask || !agentInstanceId || !role) return;
    const id = taskId(selectedTask);
    await runMutation('remove-participant', () => dispatch(tasksApi.endpoints.removeTaskParticipant.initiate({ taskId: id, chainId: chain.chainId, agentInstanceId, role })).unwrap(), `${participantRoleLabel(role)} removed`, agentInstanceId);
  };

  const setTaskReviewer = async (agentInstanceId: string) => {
    // Primary-reviewer compatibility: this select now adds one required reviewer
    // and intentionally does not remove/replace any existing reviewers.
    await addTaskParticipant(agentInstanceId, 'lgtm_required');
  };

  const addSelectedParticipant = async () => {
    const agentId = newParticipantAgentId.trim();
    if (!agentId || !newParticipantRole) return;
    await addTaskParticipant(agentId, newParticipantRole);
    setNewParticipantAgentId('');
  };

  const replaceDependencies = async (deps: string[], label = 'dependencies') => {
    if (!selectedTask) return;
    const id = taskId(selectedTask);
    const unique = Array.from(new Set(deps.map((dep) => dep.trim()).filter(Boolean)));
    await runMutation(label, () => dispatch(tasksApi.endpoints.updateTask.initiate({ taskId: id, chainId: chain.chainId, dependsOn: unique.join(',') })).unwrap(), 'Dependencies updated', id);
  };

  const addDependency = async () => {
    const dep = newDepId.trim();
    if (!selectedTask || !dep) return;
    await replaceDependencies([...selectedDeps, dep], 'add-dependency');
    setNewDepId('');
  };

  const removeDependency = async (dep: string) => {
    await replaceDependencies(selectedDeps.filter((id) => id !== dep), 'remove-dependency');
  };

  const removeEdgeDependency = async (fromTaskId: string, toTaskId: string) => {
    const target = tasksById[toTaskId] || orderedTasks.find((task) => taskId(task) === toTaskId);
    if (!target) return;
    const nextDeps = taskDependsOn(target).filter((dep) => dep !== fromTaskId);
    await runMutation('remove-edge', () => dispatch(tasksApi.endpoints.updateTask.initiate({ taskId: toTaskId, chainId: chain.chainId, dependsOn: nextDeps.join(',') })).unwrap(), 'Dependency removed', `${fromTaskId} → ${toTaskId}`);
    selectTask(toTaskId);
  };

  const createGraphDependency = async (fromTaskId: string, toTaskId: string) => {
    if (!fromTaskId || !toTaskId) return;
    if (fromTaskId === toTaskId) {
      const message = 'A task cannot depend on itself.';
      setEditorError(message);
      dispatch(showToast({ kind: 'error', title: 'Dependency rejected', message }));
      return;
    }
    const target = tasksById[toTaskId] || orderedTasks.find((task) => taskId(task) === toTaskId);
    if (!target) return;
    const nextDeps = Array.from(new Set([...taskDependsOn(target), fromTaskId]));
    await runMutation('create-edge', () => dispatch(tasksApi.endpoints.updateTask.initiate({ taskId: toTaskId, chainId: chain.chainId, dependsOn: nextDeps.join(',') })).unwrap(), 'Dependency created', `${fromTaskId} → ${toTaskId}`);
    setEdgeSourceTaskId('');
    selectTask(toTaskId);
  };

  const handleGraphNodeClick = (id: string) => {
    if (!edgeCreateMode) {
      selectTask(id);
      return;
    }
    if (!edgeSourceTaskId) {
      setEdgeSourceTaskId(id);
      selectTask(id);
      setEditorError('');
      dispatch(showToast({ kind: 'success', title: 'Dependency source selected', message: `Now click target task for ${id}` }));
      return;
    }
    void createGraphDependency(edgeSourceTaskId, id);
  };

  const createNewTask = async () => {
    const title = newTaskTitle.trim();
    if (!title) return;
    const result = await runMutation('create-task', () => dispatch(tasksApi.endpoints.createTask.initiate({ chainId: chain.chainId, title, status: 'planning' })).unwrap(), 'Task added', title);
    const createdId = result?.task?.task_id || result?.task_id || '';
    setNewTaskTitle('');
    if (createdId) selectTask(createdId);
  };

  const deleteSelectedTask = async () => {
    if (!selectedTask) return;
    const id = taskId(selectedTask);
    if (!window.confirm(`Delete task ${id}? This is distinct from cancellation and will be rejected if active dependents exist.`)) return;
    await runMutation('delete-task', () => dispatch(tasksApi.endpoints.deleteTask.initiate({ taskId: id, chainId: chain.chainId })).unwrap(), 'Task deleted', id);
    const next = orderedTasks.find((task) => taskId(task) !== id);
    setSelectedTaskId(next ? taskId(next) : '');
  };

  const addTeamMember = async () => {
    const agentId = newMemberAgentId.trim();
    if (!agentId) return;
    await runMutation('add-member', () => dispatch(workspaceApi.endpoints.addTeamMember.initiate({ teamId: chain.teamId || chain.team_id || '', roleKey: newMemberRole || 'specialist', agentInstanceId: agentId })).unwrap(), 'Team member added', agentId);
    setNewMemberAgentId('');
  };

  const startRosterAgent = async (member: any) => {
    const agentId = chainMemberAgentId(member);
    if (!agentId) return;
    const provider = runtimeProviderByAgent[agentId] || providerOptions[0] || 'pi';
    const tier = runtimeTierByAgent[agentId] || 'normal';
    await runMutation(`start-${agentId}`, () => dispatch(agentsApi.endpoints.startAgent.initiate({ agentInstanceId: agentId, provider, modelTier: tier, projectId: chain.projectId || chain.project_id || '', displayName: agentId, agentRole: member.role_key || member.roleKey || '' })).unwrap(), 'Agent start requested', `${agentId} · ${provider}/${tier}`);
  };

  const stopRosterAgent = async (member: any) => {
    const agentId = chainMemberAgentId(member);
    if (!agentId) return;
    await runMutation(`stop-${agentId}`, () => dispatch(agentsApi.endpoints.stopAgent.initiate({ agentInstanceId: agentId, timeInSec: 30 })).unwrap(), 'Agent stop requested', agentId);
  };

  const saveChainMetadata = async () => {
    await runMutation('save-chain', () => dispatch(workspaceApi.endpoints.updateChain.initiate({ chainId: chain.chainId, title: chainTitleDraft, description: chainDescriptionDraft, coordinatorAgentInstanceId: chainCoordinatorDraft, defaultReviewerAgentInstanceId: chainReviewerDraft })).unwrap(), 'Chain saved', chainTitleDraft || chain.chainId);
  };

  const handleChainRolePick = async (agentInstanceId: string) => {
    if (!chainRolePicker) return;
    if (chainRolePicker === 'coordinator') {
      if (agentInstanceId === 'user_proxy') throw new Error('Coordinator cannot be user_proxy');
      setChainCoordinatorDraft(agentInstanceId);
    } else {
      setChainReviewerDraft(agentInstanceId);
    }
    setChainRolePicker(null);
  };

  const setChainStatus = async (status: string) => {
    const summary = status === 'completed' ? (completeSummaryDraft.trim() || 'Completed from Task Chain Editor.') : undefined;
    await runMutation(`chain-${status}`, () => dispatch(workspaceApi.endpoints.updateChainStatus.initiate({ chainId: chain.chainId, status, finalSummary: summary })).unwrap(), status === 'completed' ? 'Chain completed' : 'Chain status updated', status);
  };

  const selectTask = (id: string) => {
    setSelectedTaskId(id);
    onSelectTask?.(id);
  };

  const resetLayout = () => {
    const next = autoLayout(orderedTasks);
    setPositions(next);
    setPan({ x: 0, y: 0 });
  };

  const onCanvasPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 1 && !event.shiftKey) return;
    event.preventDefault();
    dragRef.current = { kind: 'pan', startClient: { x: event.clientX, y: event.clientY }, startPoint: pan };
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const onNodePointerDown = (event: PointerEvent<HTMLDivElement>, id: string) => {
    if (edgeCreateMode) return;
    if (event.button !== 0 || event.shiftKey) return;
    event.preventDefault();
    event.stopPropagation();
    selectTask(id);
    dragRef.current = { kind: 'node', id, startClient: { x: event.clientX, y: event.clientY }, startPoint: positions[id] || { x: 28, y: 28 } };
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag) return;
    const dx = event.clientX - drag.startClient.x;
    const dy = event.clientY - drag.startClient.y;
    if (drag.kind === 'pan') {
      setPan({ x: drag.startPoint.x + dx, y: drag.startPoint.y + dy });
      return;
    }
    if (drag.id) {
      setPositions((prev) => ({ ...prev, [drag.id!]: { x: Math.max(0, drag.startPoint.x + dx), y: Math.max(0, drag.startPoint.y + dy) } }));
    }
  };

  const onPointerUp = () => { dragRef.current = null; };

  return (
    <div data-debug-id="chain-editor-page" className="mx-auto max-w-[1360px] px-8 py-8 text-zinc-100">
      {chainRolePicker ? (
        <div className="fixed inset-0 z-50 flex items-start justify-center bg-black/60 px-4 py-16 backdrop-blur-sm" onMouseDown={() => setChainRolePicker(null)}>
          <div className="w-full max-w-2xl rounded-3xl border border-white/10 bg-[#101217] p-5 shadow-2xl shadow-black/50" onMouseDown={(event) => event.stopPropagation()}>
            <div className="mb-4 flex items-start justify-between gap-4">
              <div className="min-w-0">
                <h2 className="text-lg font-semibold text-zinc-100">Set chain {chainRolePicker}</h2>
                <p className="mt-1 truncate text-sm text-zinc-500">{chain.title || chain.chainId}</p>
              </div>
              <button data-debug-id="chain-editor-role-picker-close-btn" onClick={() => setChainRolePicker(null)} className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 transition hover:bg-white/15">Close</button>
            </div>
            <AgentPicker
              debugId={`chain-editor-${chainRolePicker}-picker`}
              daemonUrl={auth.daemonUrl}
              agents={chainRolePicker === 'coordinator'
                ? agents.filter((agent: any) => String(agent?.id || agent?.agent_instance_id || '') !== 'user_proxy')
                : [{ id: 'user_proxy', label: 'User / operator', agentRole: 'user', templateId: 'user', providerProfile: 'heimdall', projectId: chainProjectId || '', connected: true, connectionState: 'connected' }, ...agents]}
              identities={identities}
              team={team}
              projects={chainProjectId ? [{ projectId: chainProjectId, name: chainProjectId }] : []}
              providers={providers}
              roleHint={chainRolePicker === 'reviewer' ? '' : 'coordinator'}
              defaultProjectId={chainProjectId}
              conversationSummaryById={effectiveConversationSummaryById}
              value={chainRolePicker === 'coordinator' ? chainCoordinatorDraft : chainReviewerDraft}
              selectionOnly
              onSelected={(agentInstanceId) => handleChainRolePick(agentInstanceId)}
            />
          </div>
        </div>
      ) : null}
      <div className="flex items-center gap-3">
        <button data-debug-id="chain-editor-back-btn" onClick={onReturnToChain} className="rounded-full bg-white/5 px-4 py-2 text-sm hover:bg-white/10">← Chain</button>
        <div className="text-xs font-semibold uppercase tracking-[0.18em] text-zinc-500">Task Chain Editor</div>
        <div className="flex-1" />
        <button data-debug-id="chain-editor-home-btn" onClick={onBack} className="rounded-full border border-white/10 bg-white/[0.04] px-4 py-2 text-sm hover:bg-white/10">Home</button>
      </div>

      <div className="mt-6">
        <h1 className="text-3xl font-semibold tracking-tight">{chain.title || chain.chainId}</h1>
        <p className="mt-2 max-w-3xl text-sm text-zinc-400">Full manual control · the graph is the navigator; pick a task node to inspect it, wire dependencies, and keep layout locally for this chain.</p>
        <div className="mt-4 flex flex-wrap gap-2">
          <span className={`inline-flex items-center gap-2 rounded-full border px-3 py-1 text-xs ${statusTone(chain.status)}`}><span className={`h-2 w-2 rounded-full ${dotTone(chain.status)}`} />{chain.status || 'unknown'}</span>
          <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 font-mono text-xs text-zinc-400">chain: {chain.chainId}</span>
          <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-zinc-400">Coordinator <b className="text-zinc-200">{chain.coordinatorAgentInstanceId || chain.coordinator_agent_instance_id || '—'}</b></span>
          <span className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 text-xs text-zinc-400">Project <b className="text-zinc-200">{chain.projectId || chain.project_id || '—'}</b></span>
        </div>
      </div>

      <div className="mt-6 rounded-2xl border border-sky-400/25 bg-sky-400/10 px-4 py-3 text-sm text-sky-100">🧭 Scaffold based on the task-chain-editor mockup. Drag nodes to reposition; <kbd className="rounded bg-black/30 px-1.5 py-0.5 font-mono text-[11px]">Shift</kbd> + drag or middle-drag to pan. Node positions persist in localStorage per chain.</div>

      <div className="mt-6 grid gap-5 xl:grid-cols-[minmax(0,1fr)_340px] xl:items-start">
        <div>
          <section data-debug-id="chain-editor-graph-card" className="rounded-3xl border border-white/10 bg-white/[0.035] p-5">
            <div className="mb-4 flex items-center gap-3">
              <div>
                <h2 className="font-semibold">Dependency graph</h2>
                <p className="mt-1 text-xs text-zinc-500">Edges point from dependency → dependent task. The graph is the primary navigator.</p>
              </div>
              <div className="flex-1" />
              <button data-debug-id="chain-editor-graph-edge-mode-btn" onClick={() => { setEdgeCreateMode(!edgeCreateMode); setEdgeSourceTaskId(''); }} className={`rounded-full border px-3 py-1.5 text-xs hover:bg-white/10 ${edgeCreateMode ? 'border-sky-400/50 bg-sky-400/15 text-sky-100' : 'border-white/10 bg-white/[0.04]'}`}>{edgeCreateMode ? 'Adding edge…' : 'Add edge'}</button>
              <button data-debug-id="chain-editor-graph-edge-cancel-btn" disabled={!edgeCreateMode && !edgeSourceTaskId} onClick={() => { setEdgeCreateMode(false); setEdgeSourceTaskId(''); }} className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1.5 text-xs hover:bg-white/10 disabled:cursor-not-allowed disabled:opacity-40">Cancel edge</button>
              <button data-debug-id="chain-editor-graph-autolayout-btn" onClick={resetLayout} className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1.5 text-xs hover:bg-white/10">Auto-layout</button>
              <button data-debug-id="chain-editor-graph-fit-btn" onClick={() => setPan({ x: 0, y: 0 })} className="rounded-full border border-white/10 bg-white/[0.04] px-3 py-1.5 text-xs hover:bg-white/10">Fit</button>
            </div>
            <div className="overflow-hidden rounded-2xl border border-white/10 bg-black/30">
              <div className="flex items-center gap-4 border-b border-white/10 px-4 py-3 text-[11px] text-zinc-500">
                <span className="inline-flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-emerald-300" />done</span>
                <span className="inline-flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-teal-300" />in progress</span>
                <span className="inline-flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-zinc-400" />queued</span>
                <span className="inline-flex items-center gap-1.5"><span className="h-2 w-2 rounded-full bg-amber-300" />blocked</span>
                <span data-debug-id="chain-editor-graph-edge-mode-hint" className="ml-auto">{edgeCreateMode ? (edgeSourceTaskId ? `source ${shortId(edgeSourceTaskId)} selected · click target` : 'click source task, then target task') : `${orderedTasks.length} tasks · ${edges.length} dependencies`}</span>
              </div>
              <div
                ref={canvasRef}
                data-debug-id="chain-editor-graph-canvas"
                className="relative h-[430px] cursor-grab overflow-hidden select-none"
                onPointerDown={onCanvasPointerDown}
                onPointerMove={onPointerMove}
                onPointerUp={onPointerUp}
                onPointerCancel={onPointerUp}
              >
                <div className="absolute left-0 top-0 h-[2200px] w-[2600px] origin-top-left" style={{ transform: `translate(${pan.x}px, ${pan.y}px)` }}>
                  <svg className="absolute left-0 top-0 h-[2200px] w-[2600px] overflow-visible">
                    <defs>
                      <marker id="chain-editor-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="rgba(125,211,252,.75)" /></marker>
                    </defs>
                    {edges.map((edge) => {
                      const from = positions[edge.from] || { x: 0, y: 0 };
                      const to = positions[edge.to] || { x: 0, y: 0 };
                      const x1 = from.x + NODE_W;
                      const y1 = from.y + NODE_H / 2;
                      const x2 = to.x;
                      const y2 = to.y + NODE_H / 2;
                      const mid = Math.max(28, (x2 - x1) / 2);
                      return <path key={`${edge.from}->${edge.to}`} data-debug-id={`chain-editor-edge-${edge.from}-${edge.to}`} d={`M ${x1} ${y1} C ${x1 + mid} ${y1}, ${x2 - mid} ${y2}, ${x2} ${y2}`} fill="none" stroke="rgba(125,211,252,.65)" strokeWidth="3" markerEnd="url(#chain-editor-arrow)" className="cursor-pointer hover:stroke-red-300" style={{ pointerEvents: 'stroke' }} onClick={(event) => { event.stopPropagation(); void removeEdgeDependency(edge.from, edge.to); }} />;
                    })}
                  </svg>
                  {orderedTasks.map((task, index) => {
                    const id = taskId(task);
                    const pos = positions[id] || { x: 28, y: 28 };
                    const selected = id === selectedTaskId;
                    const status = task.status || '';
                    return (
                      <div
                        key={id}
                        role="button"
                        tabIndex={0}
                        data-debug-id={`chain-editor-node-${id}`}
                        onPointerDown={(event) => onNodePointerDown(event, id)}
                        onClick={() => handleGraphNodeClick(id)}
                        onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') handleGraphNodeClick(id); }}
                        className={`absolute rounded-2xl border bg-zinc-900/95 p-3 shadow-2xl shadow-black/30 transition ${edgeSourceTaskId === id ? 'border-emerald-300 ring-2 ring-emerald-300/30' : selected ? 'border-sky-400 ring-2 ring-sky-400/30' : 'border-white/10 hover:border-sky-400/50'}`}
                        style={{ left: pos.x, top: pos.y, width: NODE_W, minHeight: NODE_H }}
                      >
                        <div className="font-mono text-[10px] text-zinc-500">T{index + 1} · {status || 'unknown'}</div>
                        <div className="mt-1 line-clamp-2 text-[13px] font-semibold leading-snug text-zinc-100">{task.title || id}</div>
                        <div className="mt-3 flex items-center gap-2 text-[11px] text-zinc-500">
                          <span className={`h-2 w-2 rounded-full ${dotTone(status)}`} />
                          <span className="grid h-5 w-5 place-items-center rounded-full bg-slate-800 text-[9px] text-slate-200">{initials(taskAssignee(task))}</span>
                          <span className="truncate">{shortId(taskAssignee(task) || 'unassigned')}</span>
                        </div>
                        <div className="absolute -right-2 top-1/2 h-4 w-4 -translate-y-1/2 rounded-full border-2 border-sky-400 bg-zinc-950" title="dependency out-port" />
                        <div className="absolute -left-2 top-1/2 h-4 w-4 -translate-y-1/2 rounded-full border-2 border-zinc-600 bg-zinc-950" title="dependency in-port" />
                      </div>
                    );
                  })}
                </div>
              </div>
            </div>
          </section>

          <section data-debug-id="chain-editor-selected-task-card" className="mt-5 rounded-3xl border border-white/10 bg-white/[0.035] p-5">
            <div className="flex flex-wrap items-start gap-3">
              <div>
                <h2 className="font-semibold">Selected task</h2>
                <p className="mt-1 text-xs text-zinc-500">Edit the graph-selected task. Free-text fields save on blur or with Save; actions persist immediately.</p>
              </div>
              <div className="ml-auto flex flex-wrap items-center gap-2">
                {selectedTask && <span className={`rounded-full border px-3 py-1 text-xs ${statusTone(selectedTask.status || '')}`}>{selectedTask.status || 'unknown'}</span>}
                <button data-debug-id="chain-editor-task-save-btn" disabled={!selectedTask || Boolean(busyAction)} onClick={() => { void saveSelectedTaskText(); }} className="rounded-full bg-white px-4 py-2 text-xs font-semibold text-black hover:bg-zinc-200 disabled:cursor-not-allowed disabled:opacity-50">Save task</button>
                <button data-debug-id="chain-editor-task-delete-btn" disabled={!selectedTask || Boolean(busyAction)} onClick={() => { void deleteSelectedTask(); }} className="rounded-full border border-red-400/30 bg-red-400/10 px-4 py-2 text-xs font-semibold text-red-100 hover:bg-red-400/20 disabled:cursor-not-allowed disabled:opacity-50">Delete</button>
              </div>
            </div>
            {editorError && <div data-debug-id="chain-editor-error" className="mt-4 rounded-2xl border border-red-400/30 bg-red-400/10 p-3 text-sm text-red-100">{editorError}</div>}
            {selectedTask ? (
              <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.85fr)]">
                <div className="space-y-4 rounded-2xl border border-white/10 bg-black/20 p-4">
                  <div className="font-mono text-xs text-zinc-500">{selectedTaskId}</div>
                  <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Title
                    <input data-debug-id="chain-editor-task-title-input" value={titleDraft} onChange={(event) => setTitleDraft(event.target.value)} onBlur={() => { if (titleDraft !== (selectedTask.title || '')) void saveSelectedTaskText(); }} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400" />
                  </label>
                  <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">
                    <div className="mb-2 flex items-center justify-between gap-3"><span>Description</span><VimEditButton debugId="chain-editor-task-description-vim-edit-btn" title="Task description" value={descriptionDraft} onApply={(value) => setDescriptionDraft(value)} lang="markdown" /></div>
                    <textarea data-debug-id="chain-editor-task-description-textarea" value={descriptionDraft} onChange={(event) => setDescriptionDraft(event.target.value)} onBlur={() => { if (descriptionDraft !== (selectedTask.description || '')) void saveSelectedTaskText(); }} rows={7} className="w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 font-mono text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400" />
                  </label>
                  <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">
                    <div className="mb-2 flex items-center justify-between gap-3"><span>Acceptance criteria</span><VimEditButton debugId="chain-editor-task-acceptance-vim-edit-btn" title="Task acceptance criteria" value={acceptanceDraft} onApply={(value) => setAcceptanceDraft(value)} lang="markdown" /></div>
                    <textarea data-debug-id="chain-editor-task-acceptance-textarea" value={acceptanceDraft} onChange={(event) => setAcceptanceDraft(event.target.value)} onBlur={() => { if (acceptanceDraft !== taskAcceptance(selectedTask)) void saveSelectedTaskText(); }} rows={5} className="w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 font-mono text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400" />
                  </label>
                  {taskBlockedReason(selectedTask) && <div className="rounded-xl border border-amber-400/20 bg-amber-400/10 p-3 text-xs text-amber-100">{taskBlockedReason(selectedTask)}</div>}
                </div>
                <div className="space-y-4 rounded-2xl border border-white/10 bg-black/20 p-4">
                  <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-1">
                    <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Status
                      <select data-debug-id="chain-editor-task-status-select" value={selectedTask.status || ''} disabled={Boolean(busyAction)} onChange={(event) => { void setTaskStatus(event.target.value); }} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400">
                        {['planning','queued','in_progress','review_ready','blocked','approved','cancelled'].map((status) => <option key={status} value={status}>{status}</option>)}
                      </select>
                    </label>
                    <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Assignee
                      <select data-debug-id="chain-editor-task-assignee-select" value={taskAssignee(selectedTask)} disabled={Boolean(busyAction)} onChange={(event) => { void setTaskAssignee(event.target.value); }} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400">
                        <option value="">Unassigned</option>
                        {agentOptions.map((agentId) => <option key={agentId} value={agentId}>{agentId}</option>)}
                      </select>
                    </label>
                    <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Add required reviewer
                      <select data-debug-id="chain-editor-task-reviewer-select" value="" disabled={Boolean(busyAction)} onChange={(event) => { void setTaskReviewer(event.target.value); }} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400">
                        <option value="">Choose reviewer to add…</option>
                        {agentOptions.map((agentId) => <option key={agentId} value={agentId}>{agentId}</option>)}
                      </select>
                    </label>
                  </div>

                  <div data-debug-id="chain-editor-participants-panel" className="rounded-2xl border border-white/10 bg-white/[0.025] p-3">
                    <div className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Reviewers & participants</div>
                    <div className="mt-3 space-y-2">
                      {selectedParticipants.length ? selectedParticipants.map((participant) => <div key={`${participant.role}:${participant.agentInstanceId}`} data-debug-id={`chain-editor-participant-row-${participant.role}-${participant.agentInstanceId}`} className="flex items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-3 py-2">
                        <div className="min-w-0 flex-1"><div className="truncate font-mono text-xs text-zinc-200">{participant.agentInstanceId}</div><div className="text-[11px] text-zinc-500">{participantRoleLabel(participant.role)}</div></div>
                        <button data-debug-id={`chain-editor-participant-remove-${participant.role}-${participant.agentInstanceId}`} disabled={Boolean(busyAction)} onClick={() => { void removeTaskParticipant(participant.agentInstanceId, participant.role); }} className="rounded-lg border border-red-400/30 bg-red-400/10 px-2 py-1 text-xs text-red-100 hover:bg-red-400/20 disabled:cursor-not-allowed disabled:opacity-50">Remove</button>
                      </div>) : <div className="rounded-xl border border-dashed border-white/10 p-3 text-sm text-zinc-500">No task participants are attached.</div>}
                    </div>
                    <div className="mt-3 grid gap-2 sm:grid-cols-[minmax(0,1fr)_150px_auto] lg:grid-cols-1">
                      <select data-debug-id="chain-editor-participant-add-agent-select" value={newParticipantAgentId} disabled={Boolean(busyAction)} onChange={(event) => setNewParticipantAgentId(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
                        <option value="">Add participant agent…</option>
                        {agentOptions.map((agentId) => <option key={agentId} value={agentId}>{agentId}</option>)}
                      </select>
                      <select data-debug-id="chain-editor-participant-add-role-select" value={newParticipantRole} disabled={Boolean(busyAction)} onChange={(event) => setNewParticipantRole(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
                        {PARTICIPANT_ROLES.map((role) => <option key={role} value={role}>{participantRoleLabel(role)}</option>)}
                      </select>
                      <button data-debug-id="chain-editor-participant-add-btn" disabled={!newParticipantAgentId || Boolean(busyAction)} onClick={() => { void addSelectedParticipant(); }} className="rounded-xl border border-sky-400/30 bg-sky-400/10 px-3 py-2 text-sm text-sky-100 hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-50">Add participant</button>
                    </div>
                  </div>

                  <div>
                    <div className="text-xs font-semibold uppercase tracking-wide text-zinc-500">Dependency chips</div>
                    <div className="mt-3 flex flex-wrap gap-2">
                      {selectedDeps.length ? selectedDeps.map((dep) => <span key={dep} data-debug-id={`chain-editor-dependency-chip-${dep}`} className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.04] px-3 py-1 font-mono text-xs text-zinc-300">← {shortId(dep)}<button data-debug-id={`chain-editor-dependency-remove-${dep}`} disabled={Boolean(busyAction)} onClick={() => { void removeDependency(dep); }} className="text-zinc-500 hover:text-red-300" title="Remove dependency">×</button></span>) : <span className="text-sm text-zinc-500">No dependencies</span>}
                    </div>
                    <div className="mt-3 flex gap-2">
                      <select data-debug-id="chain-editor-dependency-add-select" value={newDepId} disabled={Boolean(busyAction)} onChange={(event) => setNewDepId(event.target.value)} className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
                        <option value="">Add dependency…</option>
                        {orderedTasks.filter((task) => taskId(task) !== selectedTaskId && !selectedDeps.includes(taskId(task))).map((task) => <option key={taskId(task)} value={taskId(task)}>{task.title || taskId(task)}</option>)}
                      </select>
                      <button data-debug-id="chain-editor-dependency-add-btn" disabled={!newDepId || Boolean(busyAction)} onClick={() => { void addDependency(); }} className="rounded-xl border border-sky-400/30 bg-sky-400/10 px-3 py-2 text-sm text-sky-100 hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-50">Add</button>
                    </div>
                    <div className="mt-4 text-xs font-semibold uppercase tracking-wide text-zinc-500">Dependents</div>
                    <div className="mt-3 flex flex-wrap gap-2">
                      {dependents.length ? dependents.map((dep) => <span key={dep} className="rounded-full border border-sky-400/20 bg-sky-400/10 px-3 py-1 font-mono text-xs text-sky-100">→ {shortId(dep)}</span>) : <span className="text-sm text-zinc-500">No dependents</span>}
                    </div>
                  </div>
                </div>
              </div>
            ) : <div className="mt-4 rounded-2xl border border-dashed border-white/10 p-6 text-sm text-zinc-500">Select a graph node to inspect it.</div>}
            <div className="mt-5 rounded-2xl border border-dashed border-white/10 bg-black/10 p-4">
              <div className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">Add task</div>
              <div className="flex gap-2">
                <input data-debug-id="chain-editor-add-task-title-input" value={newTaskTitle} onChange={(event) => setNewTaskTitle(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') void createNewTask(); }} placeholder="New task title" className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
                <button data-debug-id="chain-editor-add-task-btn" disabled={!newTaskTitle.trim() || Boolean(busyAction)} onClick={() => { void createNewTask(); }} className="rounded-xl bg-white px-4 py-2 text-sm font-semibold text-black hover:bg-zinc-200 disabled:cursor-not-allowed disabled:opacity-50">+ Add task</button>
              </div>
            </div>
          </section>
        </div>

        <aside className="space-y-5">
          <section data-debug-id="chain-editor-roster-panel" className="rounded-3xl border border-white/10 bg-white/[0.035] p-5">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h2 className="font-semibold">Roster</h2>
                <p className="mt-1 text-xs text-zinc-500">Runtime provider/tier are next-start overrides only.</p>
              </div>
              <span className="rounded-full bg-white/[0.04] px-2 py-1 text-xs text-zinc-500">{members.length}</span>
            </div>
            <div className="mt-4 space-y-3">
              {members.map((member: any) => {
                const agentId = chainMemberAgentId(member);
                const agent = agentById[agentId];
                const status = runtimeStatus(agent);
                const provider = runtimeProviderByAgent[agentId] || providerOptions[0] || 'pi';
                const tier = runtimeTierByAgent[agentId] || 'normal';
                return <div key={member.team_member_id || `${member.role_key}-${agentId}`} data-debug-id={`chain-editor-roster-member-${agentId}`} className="rounded-2xl border border-white/10 bg-black/20 p-3">
                  <div className="flex items-center gap-3">
                    <span className="grid h-8 w-8 place-items-center rounded-full bg-slate-800 text-xs text-slate-200">{initials(agentId)}</span>
                    <div className="min-w-0 flex-1"><div className="truncate text-sm font-semibold">{shortId(agentId || member.role_key || 'agent')}</div><div className="text-xs text-zinc-500">{member.role_key || 'role'} · {member.lifecycle_status || 'unknown'}</div></div>
                    <span className={`rounded-full border px-2 py-1 text-[10px] ${runtimeTone(status)}`}>{status}</span>
                  </div>
                  <div className="mt-3 grid grid-cols-2 gap-2">
                    <select data-debug-id={`chain-editor-roster-provider-${agentId}`} value={provider} onChange={(event) => setRuntimeProviderByAgent((prev) => ({ ...prev, [agentId]: event.target.value }))} className="rounded-xl border border-white/10 bg-black/30 px-2 py-2 text-xs text-zinc-100 outline-none focus:border-sky-400">
                      {providerOptions.map((value) => <option key={value} value={value}>{providerLabel(providers.find((p: any) => providerValue(p) === value) || value)}</option>)}
                    </select>
                    <select data-debug-id={`chain-editor-roster-tier-${agentId}`} value={tier} onChange={(event) => setRuntimeTierByAgent((prev) => ({ ...prev, [agentId]: event.target.value }))} className="rounded-xl border border-white/10 bg-black/30 px-2 py-2 text-xs text-zinc-100 outline-none focus:border-sky-400">
                      {['cheap','normal','smart'].map((value) => <option key={value} value={value}>{value}</option>)}
                    </select>
                  </div>
                  <div className="mt-3 flex gap-2">
                    <button data-debug-id={`chain-editor-roster-start-${agentId}`} disabled={Boolean(busyAction)} onClick={() => { void startRosterAgent(member); }} className="flex-1 rounded-xl bg-emerald-400/90 px-3 py-2 text-xs font-semibold text-black hover:bg-emerald-300 disabled:cursor-not-allowed disabled:opacity-50">Start</button>
                    <button data-debug-id={`chain-editor-roster-stop-${agentId}`} disabled={Boolean(busyAction)} onClick={() => { void stopRosterAgent(member); }} className="flex-1 rounded-xl border border-white/10 bg-white/[0.04] px-3 py-2 text-xs hover:bg-white/10 disabled:cursor-not-allowed disabled:opacity-50">Stop</button>
                  </div>
                </div>;
              })}
              {!members.length && <div className="rounded-2xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No team roster loaded yet.</div>}
            </div>
            <div className="mt-4 rounded-2xl border border-dashed border-white/10 bg-black/10 p-3">
              <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">Add agent to chain</div>
              <div className="grid gap-2">
                <input data-debug-id="chain-editor-roster-add-agent-input" value={newMemberAgentId} onChange={(event) => setNewMemberAgentId(event.target.value)} placeholder="agent@instance" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
                <select data-debug-id="chain-editor-roster-add-role-select" value={newMemberRole} onChange={(event) => setNewMemberRole(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
                  {['specialist','coder','reviewer','tester','coordinator'].map((role) => <option key={role} value={role}>{role}</option>)}
                </select>
                <button data-debug-id="chain-editor-roster-add-btn" disabled={!newMemberAgentId.trim() || Boolean(busyAction)} onClick={() => { void addTeamMember(); }} className="rounded-xl border border-sky-400/30 bg-sky-400/10 px-3 py-2 text-sm font-semibold text-sky-100 hover:bg-sky-400/20 disabled:cursor-not-allowed disabled:opacity-50">+ Add member</button>
              </div>
            </div>
          </section>

          <section data-debug-id="chain-editor-chain-controls-panel" className="rounded-3xl border border-white/10 bg-white/[0.035] p-5">
            <h2 className="font-semibold">Chain controls</h2>
            <p className="mt-1 text-xs text-zinc-500">Title, description, coordinator, reviewer, pause, and complete.</p>
            <div className="mt-4 space-y-3">
              <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Title
                <input data-debug-id="chain-editor-chain-title-input" value={chainTitleDraft} onChange={(event) => setChainTitleDraft(event.target.value)} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400" />
              </label>
              <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">
                <div className="mb-2 flex items-center justify-between gap-3"><span>Description</span><VimEditButton debugId="chain-editor-description-vim-edit-btn" title="Chain description" value={chainDescriptionDraft} onApply={(value) => setChainDescriptionDraft(value)} lang="markdown" /></div>
                <textarea data-debug-id="chain-editor-chain-description-textarea" value={chainDescriptionDraft} onChange={(event) => setChainDescriptionDraft(event.target.value)} rows={7} className="w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 font-mono text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400" />
              </label>
              <div className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Coordinator
                <button data-debug-id="chain-editor-chain-coordinator-picker-btn" onClick={() => setChainRolePicker('coordinator')} className="mt-2 flex w-full items-center justify-between rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none hover:bg-white/[0.05]">
                  <span className="truncate">{chainCoordinatorDraft || 'Choose coordinator…'}</span>
                  <span className="text-zinc-500">Pick</span>
                </button>
              </div>
              <div className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Default reviewer
                <button data-debug-id="chain-editor-chain-reviewer-picker-btn" onClick={() => setChainRolePicker('reviewer')} className="mt-2 flex w-full items-center justify-between rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none hover:bg-white/[0.05]">
                  <span className="truncate">{chainReviewerDraft || 'Choose reviewer…'}</span>
                  <span className="text-zinc-500">Pick</span>
                </button>
              </div>
              <button data-debug-id="chain-editor-chain-save-btn" disabled={Boolean(busyAction)} onClick={() => { void saveChainMetadata(); }} className="w-full rounded-xl bg-white px-4 py-2 text-sm font-semibold text-black hover:bg-zinc-200 disabled:cursor-not-allowed disabled:opacity-50">Save chain controls</button>
              <div className="rounded-2xl border border-white/10 bg-black/20 p-3">
                <label className="block text-xs font-semibold uppercase tracking-wide text-zinc-500">Completion summary
                  <textarea data-debug-id="chain-editor-chain-complete-summary" value={completeSummaryDraft} onChange={(event) => setCompleteSummaryDraft(event.target.value)} rows={3} className="mt-2 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm normal-case tracking-normal text-zinc-100 outline-none focus:border-sky-400" />
                </label>
                <div className="mt-3 flex gap-2">
                  <button data-debug-id="chain-editor-chain-pause-btn" disabled={Boolean(busyAction)} onClick={() => { void setChainStatus('paused'); }} className="flex-1 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-xs font-semibold text-amber-100 hover:bg-amber-400/20 disabled:cursor-not-allowed disabled:opacity-50">Pause</button>
                  <button data-debug-id="chain-editor-chain-complete-btn" disabled={Boolean(busyAction)} onClick={() => { void setChainStatus('completed'); }} className="flex-1 rounded-xl bg-emerald-400/90 px-3 py-2 text-xs font-semibold text-black hover:bg-emerald-300 disabled:cursor-not-allowed disabled:opacity-50">Complete</button>
                </div>
              </div>
            </div>
          </section>
        </aside>
      </div>
    </div>
  );
}
