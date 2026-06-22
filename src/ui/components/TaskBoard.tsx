import { useEffect, useState, useMemo, memo } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  addCommentToSelectedTask,
  addParticipantToSelectedTask,
  assignSelectedTask,
  createChainFromBoard,
  createTaskFromBoard,
  fetchSelectedTaskLog,
  nudgeSelectedTask,
  refreshTaskBoard,
  selectChain,
  selectTask,
  updateSelectedChainMetadata,
  updateSelectedChainStatus,
  updateSelectedTaskStatus,
  fetchTasksForChain,
} from '../store/taskSlice';

const STATUS_COLUMNS = [
  { id: 'planned', label: 'Planned' },
  { id: 'ready', label: 'Ready' },
  { id: 'working', label: 'Working' },
  { id: 'done', label: 'Done' },
];

const TASK_STATUS_BY_COLUMN = {
  planned: 'pending',
  ready: 'ready',
  working: 'working',
  done: 'done',
};

const CHAIN_STATUS_BY_COLUMN = {
  planned: 'planned',
  ready: 'ready',
  working: 'working',
  done: 'done',
};

const blankCreateForm = {
  mode: 'root',
  title: '',
  description: '',
  priority: 'normal',
  status: 'ready',
  assigneeAgentInstanceId: '',
  reviewerAgentInstanceId: '',
  coordinatorAgentInstanceId: '',
};

function formatTime(unixMs: number) {
  if (!unixMs) return '—';
  return new Date(unixMs).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function statusBucket(status: string) {
  const value = (status || '').toLowerCase();
  if (['done', 'good', 'validated', 'approved', 'completed', 'archived', 'cancelled'].some((item) => value.includes(item))) return 'done';
  if (['working', 'claimed', 'in_progress', 'review', 'blocked'].some((item) => value.includes(item))) return 'working';
  if (['ready', 'open', 'needs_improvements'].some((item) => value.includes(item))) return 'ready';
  return 'planned';
}

function statusTone(status: string) {
  const bucket = statusBucket(status);
  if (bucket === 'done') return 'text-emerald-300 border-emerald-500/25 bg-emerald-500/10';
  if (bucket === 'working') return 'text-blue-200 border-[var(--fd-accent-blue)]/30 bg-[var(--fd-accent-blue)]/10';
  if (bucket === 'ready') return 'text-amber-200 border-amber-500/25 bg-amber-500/10';
  return 'text-[#cfcfcf] border-[var(--fd-hairline)] bg-[var(--fd-surface-1)]';
}

function isTerminalTaskStatus(status: string) {
  return ['done', 'archived', 'cancelled'].includes((status || '').toLowerCase());
}

function StatusPill({ status }: { status: string }) {
  return <span className={`rounded-full border px-2 py-1 text-[11px] font-medium ${statusTone(status)}`}>{status || 'unknown'}</span>;
}

interface ChainCardProps {
  chain: any;
  chainId: string;
  bucket: string;
  taskCount: number;
  handleDragStart: (kind: 'task' | 'chain', id: string, bucket: string) => void;
  setDraggedItem: (item: any) => void;
  openChain: (chainId: string) => void;
}

const ChainCard = memo(function ChainCard({ chain, chainId, bucket, taskCount, handleDragStart, setDraggedItem, openChain }: ChainCardProps) {
  return (
    <button
      type="button"
      data-debug-id={`chain-card-${chainId}`}
      draggable
      onDragStart={() => handleDragStart('chain', chainId, bucket)}
      onDragEnd={() => setDraggedItem(null)}
      onClick={() => openChain(chainId)}
      className="framer-card w-full cursor-grab p-3 text-left transition-colors hover:border-[var(--fd-accent-blue)]/50 active:cursor-grabbing"
    >
      <div className="flex items-start justify-between gap-2">
        <p className="line-clamp-2 text-sm font-semibold text-white">{chain.title || chain.chainId}</p>
        <StatusPill status={chain.status} />
      </div>
      <p className="framer-subtext mt-2 break-all text-xs">{chain.chainId}</p>
      <p className="framer-subtext mt-2 text-xs">{taskCount} tasks</p>
    </button>
  );
});

interface TaskCardProps {
  task: any;
  taskId: string;
  bucket: string;
  handleDragStart: (kind: 'task' | 'chain', id: string, bucket: string) => void;
  setDraggedItem: (item: any) => void;
  openTask: (taskId: string) => void;
}

const TaskCard = memo(function TaskCard({ task, taskId, bucket, handleDragStart, setDraggedItem, openTask }: TaskCardProps) {
  return (
    <button
      type="button"
      data-debug-id={`task-card-${taskId}`}
      draggable
      onDragStart={() => handleDragStart('task', taskId, bucket)}
      onDragEnd={() => setDraggedItem(null)}
      onClick={() => openTask(taskId)}
      className="framer-card w-full cursor-grab p-3 text-left transition-colors hover:border-[var(--fd-accent-blue)]/50 active:cursor-grabbing"
    >
      <div className="flex items-start justify-between gap-2">
        <p className="line-clamp-2 text-sm font-semibold text-white">{task?.title || taskId}</p>
        <StatusPill status={task?.status} />
      </div>
      <p className="framer-subtext mt-2 break-all text-xs">{taskId}</p>
    </button>
  );
});

function Field({ label, value }: { label: string; value: string | number | boolean }) {
  return (
    <div className="framer-card p-3">
      <p className="framer-topline text-[10px]">{label}</p>
      <p className="mt-1 break-words text-sm text-white">{String(value || '—')}</p>
    </div>
  );
}

function uniqueValues(values: string[]) {
  return Array.from(new Set(values.map((value) => value?.trim()).filter(Boolean))).sort();
}

function defaultChainId(title: string) {
  const slug = (title || 'task-chain').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 36) || 'task-chain';
  return `chain-${slug}-${Date.now().toString(16)}`;
}

function AgentSelect({ value, onChange, agents, placeholder = 'Select agent', debugId }: { value: string; onChange: (value: string) => void; agents: string[]; placeholder?: string; debugId?: string }) {
  return (
    <select data-debug-id={debugId} value={value} onChange={(event) => onChange(event.target.value)} className="framer-input w-full px-3 py-2 text-sm">
      <option value="">{placeholder}</option>
      {agents.map((agentId) => <option key={agentId} value={agentId}>{agentId}</option>)}
    </select>
  );
}

function getCreatedAfterTimestamp(range: 'all' | '24h' | '7d' | '30d'): number {
  let createdAfter = 0;
  const now = Date.now();
  if (range === '24h') createdAfter = now - 24 * 3600 * 1000;
  else if (range === '7d') createdAfter = now - 7 * 24 * 3600 * 1000;
  else if (range === '30d') createdAfter = now - 30 * 24 * 3600 * 1000;
  return createdAfter;
}

export default function TaskBoard({ session }) {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] TaskBoard took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const taskState = useSelector((state: any) => state.tasks);
  const chatAgents = useSelector((state: any) => state.chat.agents);
  const {
    chainsById,
    tasksById,
    chainTaskIds,
    participantsByTaskId,
    selectedChainId,
    selectedTaskId,
    taskLogsByTaskId,
    loading,
    error,
  } = taskState;

  const [page, setPage] = useState<'overview' | 'chain' | 'task' | 'createChain' | 'createTask'>('overview');
  const [history, setHistory] = useState<Array<'overview' | 'chain' | 'task' | 'createChain' | 'createTask'>>([]);
  const [agentToken, setAgentToken] = useState(() => window.localStorage.getItem('odin.taskAgentToken') || '');
  const [createForm, setCreateForm] = useState(blankCreateForm);
  const [createChainForm, setCreateChainForm] = useState({ chainId: '', title: '', description: '', coordinatorAgentInstanceId: '', defaultReviewerAgentInstanceId: '' });
  const [commentBody, setCommentBody] = useState('');
  const [statusForm, setStatusForm] = useState({ status: 'working', body: '' });
  const [assignmentAgent, setAssignmentAgent] = useState('');
  const [participantForm, setParticipantForm] = useState({ agentInstanceId: '', role: 'reviewer' });
  const [chainForm, setChainForm] = useState({ title: '', description: '', coordinatorAgentInstanceId: '', defaultReviewerAgentInstanceId: '', finalSummary: '' });
  const [chainStatusForm, setChainStatusForm] = useState({ status: 'active', finalSummary: '' });
  const [mutationError, setMutationError] = useState('');
  const [mutating, setMutating] = useState(false);
  const [nudgeState, setNudgeState] = useState({ taskId: '', status: 'idle', message: '' });
  const [draggedItem, setDraggedItem] = useState<{ kind: 'task' | 'chain'; id: string; fromBucket: string } | null>(null);
  const [timeRange, setTimeRange] = useState<'all' | '24h' | '7d' | '30d'>('7d');

  function handleTimeRangeChange(range: typeof timeRange) {
    setTimeRange(range);
    const createdAfter = getCreatedAfterTimestamp(range);
    dispatch(refreshTaskBoard({ createdAfter }));
  }


  const chainIds = useMemo(() => 
    Object.keys(chainTaskIds).sort((left, right) => (chainsById[right]?.createdAtUnixMs || 0) - (chainsById[left]?.createdAtUnixMs || 0)),
    [chainTaskIds, chainsById]
  );
  const selectedChain = selectedChainId ? chainsById[selectedChainId] : null;
  const selectedTask = selectedTaskId ? tasksById[selectedTaskId] : null;
  const selectedEvents = selectedTaskId ? taskLogsByTaskId[selectedTaskId] ?? [] : [];
  const comments = useMemo(() => 
    selectedEvents.filter((event) => event.body || event.kind === 'Task_Comment'),
    [selectedEvents]
  );
  const participants = selectedTaskId ? participantsByTaskId[selectedTaskId] ?? [] : [];
  const selectedTaskTerminal = selectedTask ? isTerminalTaskStatus(selectedTask.status) : false;
  const canMutate = Boolean(session.clientToken) && session.connected && !mutating;
  const nudgeInFlight = nudgeState.taskId === selectedTaskId && nudgeState.status === 'sending';
  
  const agentOptions = useMemo(() => 
    uniqueValues([
      ...(chatAgents ?? []).map((agent: any) => agent.id || agent.label),
      ...Object.values(tasksById).flatMap((task: any) => [task.assigneeAgentInstanceId, task.reviewerAgentInstanceId, task.coordinatorAgentInstanceId]),
      ...Object.values(participantsByTaskId).flatMap((items: any) => (items ?? []).map((participant: any) => participant.agentInstanceId)),
      ...Object.values(chainsById).flatMap((chain: any) => [chain.coordinatorAgentInstanceId, chain.defaultReviewerAgentInstanceId]),
    ]),
    [chatAgents, tasksById, participantsByTaskId, chainsById]
  );

  useEffect(() => {
    if (session.connected && session.clientToken) {
      const createdAfter = getCreatedAfterTimestamp('7d');
      dispatch(refreshTaskBoard({ createdAfter }));
    }
  }, [dispatch, session.connected, session.clientToken]);

  useEffect(() => {
    if (selectedTaskId) dispatch(fetchSelectedTaskLog(selectedTaskId));
  }, [dispatch, selectedTaskId]);

  useEffect(() => {
    if (!selectedChain) return;
    setChainForm({
      title: selectedChain.title || '',
      description: selectedChain.description || '',
      coordinatorAgentInstanceId: selectedChain.coordinatorAgentInstanceId || '',
      defaultReviewerAgentInstanceId: selectedChain.defaultReviewerAgentInstanceId || '',
      finalSummary: selectedChain.finalSummary || '',
    });
    setChainStatusForm({ status: selectedChain.status || 'active', finalSummary: selectedChain.finalSummary || '' });
  }, [selectedChainId, selectedChain?.updatedAtUnixMs]);

  function go(nextPage: typeof page) {
    setHistory((current) => [...current, page]);
    setPage(nextPage);
  }

  function back() {
    setHistory((current) => {
      const next = [...current];
      setPage(next.pop() || 'overview');
      return next;
    });
  }

  function openChain(chainId: string) {
    dispatch(selectChain(chainId));
    dispatch(fetchTasksForChain(chainId));
    go('chain');
  }

  function openTask(taskId: string) {
    dispatch(selectTask(taskId));
    go('task');
  }

  function openCreateTask(mode = 'root') {
    setCreateForm((current) => ({ ...current, mode }));
    go('createTask');
  }

  function openCreateChain() {
    go('createChain');
  }

  async function runMutation(callback: () => Promise<any>) {
    setMutationError('');
    setMutating(true);
    try {
      window.localStorage.setItem('odin.taskAgentToken', agentToken.trim());
      await callback();
    } catch (error: any) {
      setMutationError(error?.message || 'Task mutation failed');
    } finally {
      setMutating(false);
    }
  }

  function handleCreateChain(event) {
    event.preventDefault();
    if (!canMutate || !createChainForm.title.trim()) return;
    runMutation(async () => {
      const result = await dispatch(createChainFromBoard({
        chain_id: createChainForm.chainId.trim() || defaultChainId(createChainForm.title),
        title: createChainForm.title.trim(),
        description: createChainForm.description.trim(),
        coordinator_agent_instance_id: createChainForm.coordinatorAgentInstanceId.trim(),
        default_reviewer_agent_instance_id: createChainForm.defaultReviewerAgentInstanceId.trim(),
      })).unwrap();
      setCreateChainForm({ chainId: '', title: '', description: '', coordinatorAgentInstanceId: '', defaultReviewerAgentInstanceId: '' });
      if (result?.chain_id) dispatch(selectChain(result.chain_id));
      setPage('chain');
      setHistory(['overview']);
    });
  }

  function handleCreateTask(event) {
    event.preventDefault();
    if (!canMutate || !createForm.title.trim()) return;
    const chainId = createForm.mode === 'subtask' ? selectedChainId : '';
    runMutation(async () => {
      const result = await dispatch(createTaskFromBoard({
        title: createForm.title.trim(),
        description: createForm.description.trim(),
        priority: createForm.priority.trim() || 'normal',
        status: createForm.status.trim() || 'ready',
        chain_id: chainId,
        standalone: createForm.mode === 'standalone',
        assignee_agent_instance_id: createForm.assigneeAgentInstanceId.trim(),
        reviewer_agent_instance_id: createForm.reviewerAgentInstanceId.trim(),
        coordinator_agent_instance_id: createForm.coordinatorAgentInstanceId.trim(),
      })).unwrap();
      if (result?.chain_id || chainId) dispatch(selectChain(result?.chain_id || chainId));
      if (result?.task_id) dispatch(selectTask(result.task_id));
      setCreateForm(blankCreateForm);
      setPage('task');
      setHistory(['overview', 'chain']);
    });
  }

  function handleComment(event) {
    event.preventDefault();
    if (!canMutate || !selectedTask || !commentBody.trim()) return;
    runMutation(async () => {
      await dispatch(addCommentToSelectedTask({ agentToken: agentToken.trim(), body: commentBody.trim() })).unwrap();
      setCommentBody('');
    });
  }

  function handleStatus(event) {
    event.preventDefault();
    if (!canMutate || !selectedTask || !statusForm.status.trim() || !statusForm.body.trim()) return;
    runMutation(async () => {
      await dispatch(updateSelectedTaskStatus({ agentToken: agentToken.trim(), status: statusForm.status.trim(), body: statusForm.body.trim() })).unwrap();
      setStatusForm({ ...statusForm, body: '' });
    });
  }

  function handleAssign(event) {
    event.preventDefault();
    if (!canMutate || !selectedTask || !assignmentAgent.trim()) return;
    runMutation(async () => {
      await dispatch(assignSelectedTask({ agentToken: agentToken.trim(), agentInstanceId: assignmentAgent.trim() })).unwrap();
      setAssignmentAgent('');
    });
  }

  function handleParticipant(event) {
    event.preventDefault();
    if (!canMutate || !selectedTask || !participantForm.agentInstanceId.trim()) return;
    runMutation(async () => {
      await dispatch(addParticipantToSelectedTask({ agentToken: agentToken.trim(), agentInstanceId: participantForm.agentInstanceId.trim(), role: participantForm.role.trim() })).unwrap();
      setParticipantForm({ ...participantForm, agentInstanceId: '' });
    });
  }

  function handleChainMetadata(event) {
    event.preventDefault();
    if (!canMutate || !selectedChain) return;
    runMutation(async () => {
      await dispatch(updateSelectedChainMetadata({
        agentToken: agentToken.trim(),
        chainId: selectedChain.chainId,
        title: chainForm.title.trim(),
        description: chainForm.description.trim(),
        coordinatorAgentInstanceId: chainForm.coordinatorAgentInstanceId.trim(),
        defaultReviewerAgentInstanceId: chainForm.defaultReviewerAgentInstanceId.trim(),
        finalSummary: chainForm.finalSummary.trim(),
      })).unwrap();
    });
  }

  function handleChainStatus(event) {
    event.preventDefault();
    if (!canMutate || !selectedChain || !chainStatusForm.status.trim()) return;
    runMutation(async () => {
      await dispatch(updateSelectedChainStatus({ agentToken: agentToken.trim(), chainId: selectedChain.chainId, status: chainStatusForm.status.trim(), finalSummary: chainStatusForm.finalSummary.trim() })).unwrap();
    });
  }

  function dragStatusForColumn(kind: 'task' | 'chain', columnId: string) {
    return kind === 'task' ? TASK_STATUS_BY_COLUMN[columnId] : CHAIN_STATUS_BY_COLUMN[columnId];
  }

  function defaultDragSummary(kind: 'task' | 'chain', status: string) {
    const actor = session.userId || 'user';
    return kind === 'task' ? `Task moved to ${status} by ${actor}` : `Task chain moved to ${status} by ${actor}`;
  }

  function handleDragStart(kind: 'task' | 'chain', id: string, fromBucket: string) {
    setDraggedItem({ kind, id, fromBucket });
  }

  function canDropOnColumn(kind: 'task' | 'chain', columnId: string) {
    return canMutate && Boolean(dragStatusForColumn(kind, columnId));
  }

  function handleColumnDrop(kind: 'task' | 'chain', columnId: string) {
    const item = draggedItem;
    setDraggedItem(null);
    if (!item || item.kind !== kind || !canDropOnColumn(kind, columnId) || item.fromBucket === columnId) return;
    const nextStatus = dragStatusForColumn(kind, columnId);
    if (!nextStatus) return;

    runMutation(async () => {
      if (kind === 'task') {
        await dispatch(updateSelectedTaskStatus({
          agentToken: agentToken.trim(),
          taskId: item.id,
          status: nextStatus,
          body: defaultDragSummary('task', nextStatus),
        })).unwrap();
      } else {
        await dispatch(updateSelectedChainStatus({
          agentToken: agentToken.trim(),
          chainId: item.id,
          status: nextStatus,
          finalSummary: defaultDragSummary('chain', nextStatus),
        })).unwrap();
      }
    });
  }

  function handleNudgeTask() {
    if (!canMutate || !selectedTask || selectedTaskTerminal || nudgeInFlight) return;
    setMutationError('');
    setNudgeState({ taskId: selectedTask.taskId, status: 'sending', message: 'Sending nudge…' });
    dispatch(nudgeSelectedTask({ agentToken: agentToken.trim(), body: `Nudge requested from Heimdall for ${selectedTask.taskId}` }))
      .unwrap()
      .then((result) => {
        const target = result?.target_agent_instance_id ? ` to ${result.target_agent_instance_id}` : '';
        setNudgeState({ taskId: selectedTask.taskId, status: 'sent', message: `Sent${target}` });
        window.setTimeout(() => setNudgeState((current) => current.taskId === selectedTask.taskId ? { taskId: '', status: 'idle', message: '' } : current), 3500);
      })
      .catch((error) => setNudgeState({ taskId: selectedTask.taskId, status: 'error', message: error?.message || 'Nudge failed' }));
  }

  function renderHeader(subtitle: string) {
    return (
      <header className="border-b border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-6 py-4 flex items-center justify-between">
        <div className="min-w-0">
          <p className="framer-topline">Task workspace</p>
          <h2 className="mt-1 truncate text-2xl framer-headline">Tasks</h2>
          <p className="framer-subtext mt-1 truncate">{subtitle}</p>
        </div>
        <div className="flex items-center gap-2">
          {page === 'overview' && (
            <select
              value={timeRange}
              onChange={(e) => handleTimeRangeChange(e.target.value as any)}
              className="framer-input text-xs px-2 py-1 h-[32px] bg-[var(--fd-surface-1)] border-[var(--fd-hairline)] rounded-md text-white mr-1 cursor-pointer"
            >
              <option value="all">All Time</option>
              <option value="24h">Last 24h</option>
              <option value="7d">Last 7 Days</option>
              <option value="30d">Last 30 Days</option>
            </select>
          )}
          {page !== 'overview' && <button type="button" data-debug-id="task-back-btn" onClick={back} className="framer-pill-secondary">Back</button>}
          {page === 'chain' ? (
            <button type="button" data-debug-id="task-add-to-chain-btn" onClick={() => openCreateTask('subtask')} className="framer-pill bg-white">+ Add Task</button>
          ) : (
            <>
              <button type="button" data-debug-id="task-new-chain-btn" onClick={openCreateChain} className="framer-pill-secondary">+ Chain</button>
              <button type="button" data-debug-id="task-new-root-btn" onClick={() => openCreateTask('root')} className="framer-pill bg-white">+ Task</button>
            </>
          )}
          <button type="button" data-debug-id="task-refresh-btn" onClick={() => {
            const createdAfter = getCreatedAfterTimestamp(timeRange);
            dispatch(refreshTaskBoard({ createdAfter }));
          }} disabled={!session.connected || loading} className="framer-pill-secondary disabled:cursor-not-allowed disabled:opacity-40">{loading ? 'Refreshing…' : 'Refresh'}</button>
        </div>
      </header>
    );
  }

  const renderColumn = (column, cards, kind: 'task' | 'chain') => {
    const dropActive = draggedItem?.kind === kind && canDropOnColumn(kind, column.id) && draggedItem.fromBucket !== column.id;
    return (
      <div
        key={column.id}
        onDragOver={(event) => {
          if (dropActive) event.preventDefault();
        }}
        onDrop={(event) => {
          event.preventDefault();
          handleColumnDrop(kind, column.id);
        }}
        className={`framer-card-xl min-w-0 p-3 transition-colors ${dropActive ? 'border-[var(--fd-accent-blue)] bg-[var(--fd-accent-blue)]/10' : ''}`}
      >
        <div className="mb-3 flex items-center justify-between"><p className="framer-topline">{column.label}</p><span className="framer-chip">{cards.length}</span></div>
        <div className="space-y-2 overflow-y-auto pr-1">
          {cards.length ? cards : <p className="framer-subtext p-3 text-sm">Drop items here or drag from another column.</p>}
        </div>
      </div>
    );
  };

  function renderOverview() {
    const chainsByBucket = STATUS_COLUMNS.reduce((acc, column) => ({ ...acc, [column.id]: [] }), {} as any);
    chainIds.forEach((chainId) => {
      const chain = chainsById[chainId] ?? { chainId, title: chainId, status: 'planned' };
      const bucket = statusBucket(chain.status);
      const taskCount = (chainTaskIds[chainId] ?? []).length;
      chainsByBucket[bucket].push(
        <ChainCard
          key={chainId}
          chain={chain}
          chainId={chainId}
          bucket={bucket}
          taskCount={taskCount}
          handleDragStart={handleDragStart}
          setDraggedItem={setDraggedItem}
          openChain={openChain}
        />
      );
    });
    return (
      <>
        {renderHeader('Task-chain Kanban overview')}
        <section className="grid min-h-0 flex-1 grid-cols-4 gap-4 overflow-hidden p-4">
          {STATUS_COLUMNS.map((column) => renderColumn(column, chainsByBucket[column.id], 'chain'))}
        </section>
      </>
    );
  }

  function renderChainView() {
    if (!selectedChain) return renderOverview();
    const taskIds = chainTaskIds[selectedChain.chainId] ?? [];
    const tasksByBucket = STATUS_COLUMNS.reduce((acc, column) => ({ ...acc, [column.id]: [] }), {} as any);
    taskIds.forEach((taskId) => {
      const task = tasksById[taskId];
      const bucket = statusBucket(task?.status);
      tasksByBucket[bucket].push(
        <TaskCard
          key={taskId}
          task={task}
          taskId={taskId}
          bucket={bucket}
          handleDragStart={handleDragStart}
          setDraggedItem={setDraggedItem}
          openTask={openTask}
        />
      );
    });
    return (
      <>
        {renderHeader(`Chain: ${selectedChain.title || selectedChain.chainId}`)}
        <section className="min-h-0 flex-1 overflow-y-auto p-4">
          <div className="framer-card-xl mb-4 p-4">
            <div className="flex items-start justify-between gap-4"><div><p className="framer-topline">Chain detail</p><h3 className="mt-1 text-2xl font-bold text-white">{selectedChain.title || selectedChain.chainId}</h3><p className="framer-subtext mt-1 break-all text-xs">{selectedChain.chainId}</p></div><StatusPill status={selectedChain.status} /></div>
            <form onSubmit={handleChainMetadata} className="mt-4 grid gap-3">
              <input data-debug-id="chain-edit-title" value={chainForm.title} onChange={(event) => setChainForm({ ...chainForm, title: event.target.value })} placeholder="Chain title" className="framer-input px-3 py-2 text-sm" />
              <textarea data-debug-id="chain-edit-description" value={chainForm.description} onChange={(event) => setChainForm({ ...chainForm, description: event.target.value })} placeholder="Chain description" rows={2} className="framer-input resize-none px-3 py-2 text-sm" />
              <div className="grid grid-cols-2 gap-3"><AgentSelect debugId="chain-edit-coordinator-select" value={chainForm.coordinatorAgentInstanceId} onChange={(value) => setChainForm({ ...chainForm, coordinatorAgentInstanceId: value })} agents={agentOptions} placeholder="No coordinator" /><AgentSelect debugId="chain-edit-reviewer-select" value={chainForm.defaultReviewerAgentInstanceId} onChange={(value) => setChainForm({ ...chainForm, defaultReviewerAgentInstanceId: value })} agents={agentOptions} placeholder="No default reviewer" /></div>
              <textarea data-debug-id="chain-edit-final-summary" value={chainForm.finalSummary} onChange={(event) => setChainForm({ ...chainForm, finalSummary: event.target.value })} placeholder="Final summary" rows={2} className="framer-input resize-none px-3 py-2 text-sm" />
              <div className="flex flex-wrap gap-2"><button data-debug-id="chain-save-metadata-btn" disabled={!canMutate} className="framer-pill bg-white disabled:opacity-40">Save metadata</button></div>
            </form>
            <form onSubmit={handleChainStatus} className="mt-3 grid grid-cols-[0.55fr_1fr_auto] gap-2"><input data-debug-id="chain-status-input" value={chainStatusForm.status} onChange={(event) => setChainStatusForm({ ...chainStatusForm, status: event.target.value })} placeholder="status" className="framer-input px-3 py-2 text-sm" /><input data-debug-id="chain-status-summary" value={chainStatusForm.finalSummary} onChange={(event) => setChainStatusForm({ ...chainStatusForm, finalSummary: event.target.value })} placeholder="final summary" className="framer-input px-3 py-2 text-sm" /><button data-debug-id="chain-set-status-btn" disabled={!canMutate || !chainStatusForm.status.trim()} className="framer-pill bg-white disabled:opacity-40">Set status</button></form>
          </div>
          <div className="grid min-h-[420px] grid-cols-4 gap-4">
            {STATUS_COLUMNS.map((column) => renderColumn(column, [
              <button key={`${column.id}-add`} type="button" data-debug-id={`chain-add-task-btn-${column.id}`} onClick={() => openCreateTask('subtask')} className="framer-card mb-2 w-full border-dashed p-3 text-left text-sm text-[var(--fd-accent-blue)] hover:border-[var(--fd-accent-blue)]/50">+ Add task to chain</button>,
              ...tasksByBucket[column.id],
            ], 'task'))}
          </div>
        </section>
      </>
    );
  }

  function renderCreateChainView() {
    return (
      <>
        {renderHeader('Create chain')}
        <section className="min-h-0 flex-1 overflow-y-auto p-6">
          <form onSubmit={handleCreateChain} className="framer-card-xl mx-auto max-w-3xl p-6">
            <p className="framer-topline">Create chain</p>
            <h3 className="mt-1 text-3xl font-bold text-white">New chain only</h3>
            <p className="framer-subtext mt-2">Create chain metadata without creating a root task. You can add tasks to this chain later.</p>
            <input data-debug-id="create-chain-title" value={createChainForm.title} onChange={(event) => setCreateChainForm({ ...createChainForm, title: event.target.value })} placeholder="Chain title" className="framer-input mt-5 w-full px-3 py-3 text-sm" />
            <input data-debug-id="create-chain-id" value={createChainForm.chainId} onChange={(event) => setCreateChainForm({ ...createChainForm, chainId: event.target.value })} placeholder="Optional chain id" className="framer-input mt-2 w-full px-3 py-2 text-sm" />
            <textarea data-debug-id="create-chain-description" value={createChainForm.description} onChange={(event) => setCreateChainForm({ ...createChainForm, description: event.target.value })} placeholder="Chain-level description" rows={7} className="framer-input mt-2 w-full resize-none px-3 py-3 text-sm" />
            <div className="mt-3 grid grid-cols-2 gap-3">
              <AgentSelect debugId="create-chain-coordinator-select" value={createChainForm.coordinatorAgentInstanceId} onChange={(value) => setCreateChainForm({ ...createChainForm, coordinatorAgentInstanceId: value })} agents={agentOptions} placeholder="No coordinator" />
              <AgentSelect debugId="create-chain-reviewer-select" value={createChainForm.defaultReviewerAgentInstanceId} onChange={(value) => setCreateChainForm({ ...createChainForm, defaultReviewerAgentInstanceId: value })} agents={agentOptions} placeholder="No reviewer" />
            </div>
            <div className="mt-6 flex justify-end gap-3">
              <button type="button" data-debug-id="create-chain-cancel-btn" onClick={back} className="framer-pill-secondary">Cancel</button>
              <button data-debug-id="create-chain-submit-btn" disabled={!canMutate || !createChainForm.title.trim()} className="framer-pill bg-white disabled:opacity-40">Create chain</button>
            </div>
          </form>
        </section>
      </>
    );
  }

  function renderCreateTaskView() {
    return (
      <>
        {renderHeader('Create task')}
        <section className="min-h-0 flex-1 overflow-y-auto p-6">
          <form onSubmit={handleCreateTask} className="framer-card-xl mx-auto max-w-3xl p-6">
            <p className="framer-topline">Create task</p>
            <h3 className="mt-1 text-3xl font-bold text-white">New task</h3>
            <p className="framer-subtext mt-2">Create root work, a task in the selected chain, or a standalone task. Task metadata is separate from chain metadata.</p>
            <div className="mt-5 grid grid-cols-3 gap-3">
              <select data-debug-id="create-task-mode-select" value={createForm.mode} onChange={(event) => setCreateForm({ ...createForm, mode: event.target.value })} className="framer-input px-3 py-2 text-sm"><option value="root">Root task + chain</option><option value="subtask">Task in selected chain</option><option value="standalone">Standalone task</option></select>
              <input data-debug-id="create-task-priority" value={createForm.priority} onChange={(event) => setCreateForm({ ...createForm, priority: event.target.value })} placeholder="priority" className="framer-input px-3 py-2 text-sm" />
              <input data-debug-id="create-task-status" value={createForm.status} onChange={(event) => setCreateForm({ ...createForm, status: event.target.value })} placeholder="status" className="framer-input px-3 py-2 text-sm" />
            </div>
            {createForm.mode === 'subtask' && (
              <div className="framer-card mt-4 p-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <p className="framer-topline text-[10px]">Selected chain</p>
                    <h4 className="mt-1 text-lg font-semibold text-white">{selectedChain?.title || selectedChain?.chainId || 'No chain selected'}</h4>
                    <p className="framer-subtext mt-1 break-all text-xs">{selectedChain?.chainId || 'Select a chain before creating in-chain work.'}</p>
                  </div>
                  {selectedChain && <StatusPill status={selectedChain.status} />}
                </div>
                <p className="mt-3 whitespace-pre-wrap text-sm leading-6 text-[#d6d6d6]">{selectedChain?.description || 'No chain description provided.'}</p>
                {selectedChain && <p className="framer-subtext mt-3 text-xs">Coordinator: {selectedChain.coordinatorAgentInstanceId || '—'} · Default reviewer: {selectedChain.defaultReviewerAgentInstanceId || '—'} · Tasks: {(chainTaskIds[selectedChain.chainId] ?? []).length}</p>}
              </div>
            )}
            <input data-debug-id="create-task-title" value={createForm.title} onChange={(event) => setCreateForm({ ...createForm, title: event.target.value })} placeholder="Task title" className="framer-input mt-4 w-full px-3 py-3 text-sm" />
            <textarea data-debug-id="create-task-description" value={createForm.description} onChange={(event) => setCreateForm({ ...createForm, description: event.target.value })} placeholder="Task-specific description" rows={7} className="framer-input mt-2 w-full resize-none px-3 py-3 text-sm" />
            <div className="mt-3 grid grid-cols-3 gap-3">
              <AgentSelect debugId="create-task-assignee-select" value={createForm.assigneeAgentInstanceId} onChange={(value) => setCreateForm({ ...createForm, assigneeAgentInstanceId: value })} agents={agentOptions} placeholder="No assignee" />
              <AgentSelect debugId="create-task-reviewer-select" value={createForm.reviewerAgentInstanceId} onChange={(value) => setCreateForm({ ...createForm, reviewerAgentInstanceId: value })} agents={agentOptions} placeholder="No reviewer" />
              <AgentSelect debugId="create-task-coordinator-select" value={createForm.coordinatorAgentInstanceId} onChange={(value) => setCreateForm({ ...createForm, coordinatorAgentInstanceId: value })} agents={agentOptions} placeholder="No coordinator" />
            </div>
            <div className="mt-6 flex justify-end gap-3">
              <button type="button" data-debug-id="create-task-cancel-btn" onClick={back} className="framer-pill-secondary">Cancel</button>
              <button data-debug-id="create-task-submit-btn" disabled={!canMutate || !createForm.title.trim() || (createForm.mode === 'subtask' && !selectedChainId)} className="framer-pill bg-white disabled:opacity-40">Create task</button>
            </div>
          </form>
        </section>
      </>
    );
  }


  function renderTaskView() {
    if (!selectedTask) return renderOverview();
    return (
      <>
        {renderHeader(`Task: ${selectedTask.title}`)}
        <section className="min-h-0 flex-1 overflow-y-auto p-6">
          <div className="mx-auto max-w-4xl space-y-4">
            <div className="framer-card-xl p-5"><div className="flex items-start justify-between gap-4"><div><p className="framer-topline">Task detail</p><h3 className="mt-1 text-3xl font-bold text-white">{selectedTask.title}</h3><p className="framer-subtext mt-2 break-all text-xs">{selectedTask.taskId}</p></div><div className="flex flex-col items-end gap-2"><StatusPill status={selectedTask.status} />{!selectedTaskTerminal && <button type="button" data-debug-id="task-nudge-btn" onClick={handleNudgeTask} disabled={!canMutate || nudgeInFlight} className="framer-pill bg-white px-4 py-2 text-xs disabled:opacity-40">{nudgeInFlight ? 'Nudging…' : nudgeState.taskId === selectedTask.taskId && nudgeState.status === 'sent' ? 'Sent' : 'Nudge'}</button>}{nudgeState.taskId === selectedTask.taskId && nudgeState.message && <p className={`text-right text-xs ${nudgeState.status === 'error' ? 'text-red-200' : 'text-[#999]'}`}>{nudgeState.message}</p>}</div></div>{selectedTask.description && <p className="mt-4 whitespace-pre-wrap text-sm leading-6 text-[#d6d6d6]">{selectedTask.description}</p>}</div>
            <div className="grid grid-cols-2 gap-3"><Field label="Assignee" value={selectedTask.assigneeAgentInstanceId} /><Field label="Reviewer" value={selectedTask.reviewerAgentInstanceId} /><Field label="Coordinator" value={selectedTask.coordinatorAgentInstanceId} /><Field label="Priority" value={selectedTask.priority} /><Field label="Created by" value={selectedTask.createdBy} /><Field label="Updated" value={formatTime(selectedTask.updatedAtUnixMs)} /></div>
            <div className="framer-card p-4"><p className="framer-topline">Mutations</p><form onSubmit={handleComment} className="mt-3 flex gap-2"><input data-debug-id="task-comment-input" value={commentBody} onChange={(event) => setCommentBody(event.target.value)} placeholder="Add comment" className="framer-input min-w-0 flex-1 px-3 py-2 text-sm" /><button data-debug-id="task-comment-submit-btn" disabled={!canMutate || !commentBody.trim()} className="framer-pill bg-white disabled:opacity-40">Comment</button></form><form onSubmit={handleStatus} className="mt-2 grid grid-cols-[0.55fr_1fr_auto] gap-2"><input data-debug-id="task-status-input" value={statusForm.status} onChange={(event) => setStatusForm({ ...statusForm, status: event.target.value })} placeholder="status" className="framer-input px-3 py-2 text-sm" /><input data-debug-id="task-status-note-input" value={statusForm.body} onChange={(event) => setStatusForm({ ...statusForm, body: event.target.value })} placeholder="status note" className="framer-input px-3 py-2 text-sm" /><button data-debug-id="task-status-update-btn" disabled={!canMutate || !statusForm.status.trim() || !statusForm.body.trim()} className="framer-pill bg-white disabled:opacity-40">Update</button></form><form onSubmit={handleAssign} className="mt-2 grid grid-cols-[1fr_auto] gap-2"><AgentSelect debugId="task-assign-agent-select" value={assignmentAgent} onChange={setAssignmentAgent} agents={agentOptions} placeholder="New assignee" /><button data-debug-id="task-assign-submit-btn" disabled={!canMutate || !assignmentAgent.trim()} className="framer-pill bg-white disabled:opacity-40">Assign</button></form><form onSubmit={handleParticipant} className="mt-2 grid grid-cols-[1fr_0.55fr_auto] gap-2"><AgentSelect debugId="task-participant-agent-select" value={participantForm.agentInstanceId} onChange={(value) => setParticipantForm({ ...participantForm, agentInstanceId: value })} agents={agentOptions} placeholder="Participant" /><select data-debug-id="task-participant-role-select" value={participantForm.role} onChange={(event) => setParticipantForm({ ...participantForm, role: event.target.value })} className="framer-input px-3 py-2 text-sm"><option value="reviewer">reviewer</option><option value="coordinator">coordinator</option><option value="verifier">verifier</option><option value="observer">observer</option><option value="specialist">specialist</option><option value="assignee">assignee</option></select><button data-debug-id="task-participant-submit-btn" disabled={!canMutate || !participantForm.agentInstanceId.trim()} className="framer-pill bg-white disabled:opacity-40">Add</button></form></div>
            <div className="framer-card p-4"><p className="framer-topline">Participants</p><div className="mt-3 flex flex-wrap gap-2">{participants.length ? participants.map((participant, index) => <span key={`${participant.agentInstanceId}-${participant.role}-${index}`} className="framer-chip">{participant.role}: <span className="text-white">{participant.agentInstanceId}</span></span>) : <p className="framer-subtext text-sm">No participants recorded.</p>}</div></div>
            <div className="framer-card p-4"><p className="framer-topline">Comments & status notes</p><div className="mt-3 space-y-3">{comments.length ? comments.map((event) => <div key={event.eventId || `${event.kind}-${event.createdUnixMs}`} className="rounded-[var(--fd-radius-lg)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] p-3"><div className="flex items-center justify-between gap-3"><p className="text-xs font-semibold text-white">{event.kind || 'Event'}</p><p className="framer-subtext text-xs">{formatTime(event.createdUnixMs)}</p></div><p className="framer-subtext mt-1 text-xs">{event.authorAgentInstanceId || 'unknown author'}</p>{event.body && <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-[#d6d6d6]">{event.body}</p>}</div>) : <p className="framer-subtext text-sm">No comments or status notes for this task.</p>}</div></div>
          </div>
        </section>
      </>
    );
  }

  return (
    <main className="framer-panel flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      {mutationError && <div className="border-b border-red-500/30 bg-red-500/10 px-6 py-2 text-sm text-red-100">{mutationError}</div>}
      {page === 'overview' && renderOverview()}
      {page === 'chain' && renderChainView()}
      {page === 'task' && renderTaskView()}
      {page === 'createChain' && renderCreateChainView()}
      {page === 'createTask' && renderCreateTaskView()}
    </main>
  );
}
