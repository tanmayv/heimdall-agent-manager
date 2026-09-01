import React, { useEffect, useRef, useState } from 'react';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import Markdown from '../Markdown';
import {
  appendArtifactLinks,
  artifactIdFromLink,
  artifactIdsFromText,
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';
import {
  useFetchTaskChainDetailQuery,
  useCreateTaskMutation,
  useUpdateTaskDetailMutation,
  useSetTaskStatusMutation,
  useCancelTaskDetailMutation,
  useAddTaskCommentMutation,
  useVoteTaskMutation,
  useNudgeTaskMutation,
  useAddChainMemberMutation,
  useRemoveChainMemberMutation,
} from '../../api/endpoints/tasks';
import { useDispatch } from 'react-redux';
import {
  upsertAgentInCaches,
  useCreateAgentInstanceInChainMutation,
  useFetchAgentInstanceQuery,
  useListAgentIdentitiesQuery,
} from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import {
  bridgeLabel,
  launchProvidersFor,
  launchTiersFor,
  launchableBridgeRows,
} from '../../utils/bridgeLaunchOptions';

interface TaskChainOverviewProps {
  chainId: string;
  onClose?: () => void;
  isMobile?: boolean;
}

type CommentAttachmentStatus = 'uploading' | 'uploaded' | 'error';

type CommentAttachment = {
  localId: string;
  id: string;
  link: string;
  name: string;
  file: File;
  status: CommentAttachmentStatus;
  error: string;
};

export const TaskChainOverview: React.FC<TaskChainOverviewProps> = ({
  chainId,
  onClose,
  isMobile,
}) => {
  const { data, isLoading, error, refetch } = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId }
  );

  const [createTask] = useCreateTaskMutation();
  const [updateTask] = useUpdateTaskDetailMutation();
  const [setStatus] = useSetTaskStatusMutation();
  const [cancelTask] = useCancelTaskDetailMutation();
  const [addComment] = useAddTaskCommentMutation();
  const [createArtifact] = useCreateArtifactMutation();
  const [voteTask] = useVoteTaskMutation();
  const [nudgeTask] = useNudgeTaskMutation();
  const [addMember] = useAddChainMemberMutation();
  const [removeMember] = useRemoveChainMemberMutation();
  const [createInstanceInChain, { isLoading: addingAgent }] = useCreateAgentInstanceInChainMutation();
  const dispatch = useDispatch();

  // Data sources for the Add-Agent popup's dependent selects.
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });

  // Local state
  // H12: chain description collapsed by default so the chain view is scannable.
  const [descExpanded, setDescExpanded] = useState(false);
  const [expandedTaskIds, setExpandedTaskIds] = useState<Record<string, boolean>>({});
  const [commentInputs, setCommentInputs] = useState<Record<string, string>>({});
  const [commentAttachments, setCommentAttachments] = useState<Record<string, CommentAttachment[]>>({});
  const [statusMenuOpenTaskId, setStatusMenuOpenTaskId] = useState<string | null>(null);
  // H12: single quick-actions menu open at a time (mirrors statusMenuOpenTaskId).
  const [actionsMenuOpenTaskId, setActionsMenuOpenTaskId] = useState<string | null>(null);
  const actionsMenuRef = useRef<HTMLDivElement | null>(null);

  // H12: close the quick-actions menu on outside-click (one-open-at-a-time).
  useEffect(() => {
    if (!actionsMenuOpenTaskId) return;
    const onDocClick = (e: MouseEvent) => {
      if (actionsMenuRef.current && !actionsMenuRef.current.contains(e.target as Node)) {
        setActionsMenuOpenTaskId(null);
        setStatusMenuOpenTaskId(null);
      }
    };
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, [actionsMenuOpenTaskId]);

  // Modal state
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [newTaskTitle, setNewTaskTitle] = useState('');
  const [newTaskDesc, setNewTaskDesc] = useState('');
  const [showAddMemberModal, setShowAddMemberModal] = useState(false);
  const [newMemberRole, setNewMemberRole] = useState('worker');
  // Add-Agent popup selection state (identity -> bridge -> provider -> tier).
  const [addAgentId, setAddAgentId] = useState('');
  const [addBridgeId, setAddBridgeId] = useState('');
  const [addProvider, setAddProvider] = useState('');
  const [addTier, setAddTier] = useState('');
  const [addAgentError, setAddAgentError] = useState('');

  const chain = data?.chain;
  const tasks: any[] = chain?.tasks || [];
  const members: any[] = chain?.members || [];

  // Add-Agent popup dependent option lists (identity -> bridge -> provider -> tier).
  const agentIdentities: any[] = agentIdentitiesQuery.data?.agents || [];
  const addBridgeRows = launchableBridgeRows(bridgesQuery.data?.bridges || []);
  const selectedAddBridge = addBridgeRows.find((row) => row.bridgeId === addBridgeId)?.bridge;
  const selectedAddAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === addAgentId);
  const addProviderOptions = selectedAddBridge ? launchProvidersFor(selectedAddBridge) : [];
  const addTierOptions = selectedAddBridge ? launchTiersFor(selectedAddBridge, addProvider, selectedAddAgent) : [];

  // Compute progress buckets
  const progressBuckets = {
    todo: tasks.filter((t) => t.status === 'assigned' || t.status === 'pending').length,
    in_progress: tasks.filter((t) => t.status === 'in_progress').length,
    in_validation: tasks.filter((t) => t.status === 'in_validation').length,
    validated_good: tasks.filter((t) => t.status === 'validated_good' || t.status === 'completed').length,
    blocked: tasks.filter((t) => t.blocked).length,
  };

  const toggleTaskExpanded = (id: string) => {
    setExpandedTaskIds((prev) => ({ ...prev, [id]: !prev[id] }));
  };

  const handleCreateTask = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newTaskTitle.trim()) return;
    try {
      await createTask({
        chainId,
        title: newTaskTitle.trim(),
        description: newTaskDesc.trim(),
      }).unwrap();
      setNewTaskTitle('');
      setNewTaskDesc('');
      setShowNewTaskModal(false);
      refetch();
    } catch (err) {
      console.error('Failed to create task:', err);
    }
  };

  // Add-Agent popup: LAUNCH a new instance of the chosen agent-id on the chosen
  // bridge/provider/tier bound to THIS chain, then add it as a member with the
  // selected role. bridge_id/chain_id/provider/tier are honored by the hub's
  // POST /api/v1/agent-instances handler (instance_input_from_body), so this is a
  // pure UI plumb through createAgentInstanceInChain.
  const handleAddMember = async (e: React.FormEvent) => {
    e.preventDefault();
    setAddAgentError('');
    if (!addAgentId) { setAddAgentError('Choose an agent identity to launch.'); return; }
    if (addProvider && !addProviderOptions.includes(addProvider)) { setAddAgentError('Selected provider is not supported by the chosen bridge.'); return; }
    if (addTier && !addTierOptions.includes(addTier)) { setAddAgentError('Selected tier is not supported by the chosen bridge/provider.'); return; }
    try {
      const result = await createInstanceInChain({
        agentId: addAgentId,
        chainId,
        ...(addBridgeId ? { bridgeId: addBridgeId } : {}),
        ...(addProvider ? { providerProfile: addProvider } : {}),
        ...(addTier ? { modelTier: addTier } : {}),
      }).unwrap();
      const newInstance = result?.agent_instance || result?.agentInstance || result?.agent;
      if (newInstance) upsertAgentInCaches(dispatch, newInstance);
      // Ensure the new instance is a chain member with the chosen role (create may
      // not attach the role). Skip if it already landed as a member.
      const newInstanceId = String(newInstance?.agent_instance_id || newInstance?.agentInstanceId || '');
      const alreadyMember = newInstanceId && members.some((m: any) => String(m.agentInstanceId || m.agent_instance_id || '') === newInstanceId);
      if (newInstanceId && !alreadyMember) {
        try {
          await addMember({ chainId, agentInstanceId: newInstanceId, role: newMemberRole }).unwrap();
        } catch (memberErr) {
          console.error('Instance launched but adding as chain member failed:', memberErr);
        }
      }
      setShowAddMemberModal(false);
      setAddAgentId(''); setAddBridgeId(''); setAddProvider(''); setAddTier('');
      refetch();
    } catch (err: any) {
      setAddAgentError(String(err?.message || err || 'Failed to launch and add agent'));
    }
  };

  const handleRemoveMember = async (agentInstanceId: string) => {
    try {
      await removeMember({ chainId, agentInstanceId }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to remove member:', err);
    }
  };

  const updateCommentAttachments = (taskId: string, updater: (items: CommentAttachment[]) => CommentAttachment[]) => {
    setCommentAttachments((prev) => ({
      ...prev,
      [taskId]: updater(prev[taskId] || []),
    }));
  };

  const uploadCommentAttachment = async (taskId: string, file: File, existingLocalId = '') => {
    const localId = existingLocalId || `task_att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, 'task-comment-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    updateCommentAttachments(taskId, (items) => [
      ...items.filter((item) => item.localId !== localId),
      {
        localId,
        id: '',
        link: '',
        name,
        file,
        status: tooLarge ? 'error' : 'uploading',
        error: tooLarge ? `File is too large. Maximum upload size is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.` : '',
      },
    ]);
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'task_comment',
        originRef: `${chainId}:${taskId}`,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = artifactIdFromLink(link);
      if (!id) throw new Error('Upload failed: Hub did not return an artifact id.');
      updateCommentAttachments(taskId, (items) => items.map((item) => (
        item.localId === localId ? { ...item, id, link, status: 'uploaded', error: '' } : item
      )));
    } catch (err: any) {
      const message = String(err?.data?.message || err?.message || err || 'Upload failed');
      updateCommentAttachments(taskId, (items) => items.map((item) => (
        item.localId === localId ? { ...item, status: 'error', error: message } : item
      )));
    }
  };

  const handleCommentPaste = (event: React.ClipboardEvent<HTMLInputElement>, taskId: string) => {
    const files = clipboardFilesFromEvent(event);
    if (files.length === 0) return;
    event.preventDefault();
    files.forEach((file) => void uploadCommentAttachment(taskId, file));
  };

  const handleAddComment = async (taskId: string) => {
    const text = commentInputs[taskId]?.trim() || '';
    const attachments = commentAttachments[taskId] || [];
    if (attachments.some((item) => item.status === 'uploading' || item.status === 'error')) return;
    const body = appendArtifactLinks(text, attachments.filter((item) => item.status === 'uploaded' && item.link).map((item) => item.link)).trim();
    if (!body) return;
    try {
      await addComment({ chainId, taskId, body }).unwrap();
      setCommentInputs((prev) => ({ ...prev, [taskId]: '' }));
      setCommentAttachments((prev) => ({ ...prev, [taskId]: [] }));
      refetch();
    } catch (err) {
      console.error('Failed to add comment:', err);
    }
  };

  const handleVote = async (taskId: string, result: 'lgtm' | 'ngtm') => {
    try {
      await voteTask({ chainId, taskId, result }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to vote:', err);
    }
  };

  const handleStatusChange = async (taskId: string, status: string) => {
    try {
      await setStatus({ chainId, taskId, status, body: '' }).unwrap();
      setStatusMenuOpenTaskId(null);
      refetch();
    } catch (err) {
      console.error('Failed to update status:', err);
    }
  };

  const handleCancelTask = async (taskId: string) => {
    try {
      await cancelTask({ chainId, taskId }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to cancel task:', err);
    }
  };

  const handleNudge = async (taskId: string) => {
    try {
      await nudgeTask({ chainId, taskId, message: 'Nudge: please check task status' }).unwrap();
    } catch (err) {
      console.error('Failed to nudge:', err);
    }
  };

  if (!chainId) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-zinc-400">
        No task chain ID provided.
      </div>
    );
  }

  if (isLoading) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-zinc-400">
        Loading Task Chain overview...
      </div>
    );
  }

  if (error || !chain) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-red-400">
        Failed to load Task Chain details.
      </div>
    );
  }

  return (
    <div
      data-debug-id="taskchain-overview"
      className="flex h-full w-full flex-col overflow-y-auto bg-[#090909] text-white"
    >
      {/* Mobile Back Header (Requirement 10) */}
      {isMobile && onClose && (
        <div
          data-debug-id="taskchain-overview-back-btn-container"
          className="sticky top-0 z-30 flex items-center justify-between border-b border-white/10 bg-[#0c0c0c] px-4 py-3 sm:hidden"
        >
          <button
            type="button"
            data-debug-id="taskchain-overview-back-btn"
            onClick={onClose}
            className="flex items-center gap-2 text-sm font-semibold text-sky-400 hover:text-sky-300"
          >
            ← Back to Chat
          </button>
          <span className="text-xs font-bold uppercase tracking-wider text-zinc-400">Task Chain</span>
        </div>
      )}

      {/* Header Info */}
      <div className="border-b border-white/10 p-4 sm:p-6">
        <div className="flex items-center justify-between">
          <h2
            data-debug-id="taskchain-overview-title"
            className="text-lg font-bold text-white sm:text-xl"
          >
            {chain.title || 'Untitled Chain'}
          </h2>
          <span
            data-debug-id="taskchain-overview-status"
            className={`rounded-full px-3 py-1 text-xs font-semibold uppercase tracking-wider ${
              chain.status === 'completed'
                ? 'bg-emerald-500/20 text-emerald-400'
                : chain.status === 'cancelled'
                ? 'bg-red-500/20 text-red-400'
                : 'bg-sky-500/20 text-sky-400'
            }`}
          >
            {chain.status}
          </span>
        </div>

        {/* Collapsible Description */}
        {chain.description && (
          <div className="mt-2">
            <button
              type="button"
              data-debug-id="taskchain-overview-description-toggle-btn"
              onClick={() => setDescExpanded(!descExpanded)}
              className="flex items-center gap-1 text-xs font-semibold text-zinc-400 hover:text-zinc-200"
            >
              <span>{descExpanded ? '▾' : '▸'}</span> description
            </button>
            {descExpanded && (
              <p className="mt-1 text-sm text-zinc-300">
                {chain.description}
              </p>
            )}
          </div>
        )}

        {/* Progress Summary Pill Counters */}
        <div
          data-debug-id="taskchain-overview-progress"
          className="mt-4 flex flex-wrap gap-2 text-xs"
        >
          <span
            data-debug-id="taskchain-overview-progress-todo"
            className="rounded bg-zinc-800 px-2 py-1 text-zinc-300"
          >
            todo {progressBuckets.todo}
          </span>
          <span
            data-debug-id="taskchain-overview-progress-in_progress"
            className="rounded bg-sky-900/50 px-2 py-1 text-sky-300"
          >
            doing {progressBuckets.in_progress}
          </span>
          <span
            data-debug-id="taskchain-overview-progress-in_validation"
            className="rounded bg-purple-900/50 px-2 py-1 text-purple-300"
          >
            review {progressBuckets.in_validation}
          </span>
          <span
            data-debug-id="taskchain-overview-progress-validated_good"
            className="rounded bg-emerald-900/50 px-2 py-1 text-emerald-300"
          >
            done {progressBuckets.validated_good}
          </span>
          {progressBuckets.blocked > 0 && (
            <span
              data-debug-id="taskchain-overview-progress-blocked"
              className="rounded bg-amber-900/50 px-2 py-1 text-amber-300"
            >
              blocked {progressBuckets.blocked}
            </span>
          )}
        </div>

        {/* Members Strip */}
        <div
          data-debug-id="taskchain-overview-members"
          className="mt-4 flex flex-wrap items-center gap-3 border-t border-white/5 pt-3 text-xs"
        >
          <span className="font-semibold text-zinc-400">Members:</span>
          {members.map((m: any) => (
            <div
              key={m.agentInstanceId || m.agent_instance_id}
              data-debug-id={`taskchain-overview-member-${m.agentInstanceId || m.agent_instance_id}`}
              className="flex items-center gap-1 rounded bg-zinc-800 px-2 py-0.5"
            >
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-400"></span>
              <span className="font-mono text-zinc-300">
                {m.role}: <InstanceIdLink instanceId={m.agentInstanceId || m.agent_instance_id} />
              </span>
              <button
                type="button"
                data-debug-id={`taskchain-overview-member-remove-btn-${m.agentInstanceId || m.agent_instance_id}`}
                onClick={() => handleRemoveMember(m.agentInstanceId || m.agent_instance_id)}
                className="ml-1 text-zinc-500 hover:text-red-400"
                title="Remove member"
              >
                ×
              </button>
            </div>
          ))}
          <button
            type="button"
            data-debug-id="taskchain-overview-add-member-btn"
            onClick={() => setShowAddMemberModal(true)}
            className="rounded bg-white/10 px-2 py-0.5 font-semibold text-zinc-300 hover:bg-white/20"
          >
            + Add member
          </button>
        </div>
      </div>

      {/* Task List Header */}
      <div className="flex items-center justify-between px-4 py-3 sm:px-6">
        <h3 className="text-sm font-bold uppercase tracking-wider text-zinc-400">
          Tasks ({tasks.length})
        </h3>
        <button
          type="button"
          data-debug-id="taskchain-new-task-btn"
          onClick={() => setShowNewTaskModal(true)}
          className="rounded bg-sky-600 px-3 py-1 text-xs font-semibold text-white hover:bg-sky-500"
        >
          + New task
        </button>
      </div>

      {/* Tasks List */}
      <div className="flex-1 space-y-3 px-4 pb-6 sm:px-6">
        {tasks.length === 0 ? (
          <div className="rounded-lg border border-dashed border-white/10 p-6 text-center text-xs text-zinc-500">
            No tasks in this chain yet. Click "+ New task" to get started.
          </div>
        ) : (
          tasks.map((task: any) => {
            const taskId = task.taskId || task.id;
            const isExpanded = Boolean(expandedTaskIds[taskId]);
            const taskCommentAttachments = commentAttachments[taskId] || [];
            const taskCommentUploading = taskCommentAttachments.some((item) => item.status === 'uploading');
            const taskCommentFailed = taskCommentAttachments.some((item) => item.status === 'error');
            const taskCommentReady = taskCommentAttachments.filter((item) => item.status === 'uploaded' && item.link);
            const taskCommentCanSend = !taskCommentUploading && !taskCommentFailed && (Boolean((commentInputs[taskId] || '').trim()) || taskCommentReady.length > 0);

            return (
              <div
                key={taskId}
                data-debug-id={`taskchain-task-row-${taskId}`}
                className="rounded-lg border border-white/10 bg-[#111111] p-3 text-xs"
              >
                {/* Main Card Header */}
                <div className="flex items-start justify-between gap-2">
                  <div className="flex items-start gap-2">
                    <button
                      type="button"
                      data-debug-id={`taskchain-task-expand-btn-${taskId}`}
                      onClick={() => toggleTaskExpanded(taskId)}
                      className="mt-0.5 text-zinc-400 hover:text-white"
                    >
                      {isExpanded ? '▾' : '▸'}
                    </button>
                    <div>
                      <div
                        data-debug-id={`taskchain-task-title-${taskId}`}
                        className="font-semibold text-white"
                      >
                        {task.title}
                      </div>
                      {/* H12: compact header shows ONLY the assignee; the full
                          description + reviewers live in the expanded block. */}
                      {task.assigneeRef && (
                        <div className="mt-1 flex flex-wrap gap-2 text-[11px] text-zinc-400">
                          <span data-debug-id={`taskchain-task-assignee-${taskId}`}>
                            assignee: {task.assigneeRef.agent_instance_id
                              ? <InstanceIdLink instanceId={task.assigneeRef.agent_instance_id} />
                              : <span className="text-zinc-300">{task.assigneeRef.user_id}</span>}
                          </span>
                        </div>
                      )}
                    </div>
                  </div>

                  {/* H12: compact right side — status/blocked badges + a single
                      quick-actions MENU button (actionable without expanding). */}
                  <div className="flex items-center gap-2">
                    {task.blocked && (
                      <span
                        data-debug-id={`taskchain-task-blocked-${taskId}`}
                        className="rounded bg-amber-900/50 px-2 py-0.5 font-semibold text-amber-300"
                      >
                        ⛔ blocked
                      </span>
                    )}
                    <span
                      data-debug-id={`taskchain-task-status-${taskId}`}
                      className="rounded bg-zinc-800 px-2 py-0.5 font-mono uppercase text-zinc-300"
                    >
                      {task.status}
                    </span>
                    <div
                      className="relative inline-block text-left"
                      ref={actionsMenuOpenTaskId === taskId ? actionsMenuRef : undefined}
                    >
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-actions-menu-btn-${taskId}`}
                        aria-haspopup="menu"
                        aria-expanded={actionsMenuOpenTaskId === taskId}
                        title="Quick actions"
                        onClick={() => {
                          setActionsMenuOpenTaskId(actionsMenuOpenTaskId === taskId ? null : taskId);
                          setStatusMenuOpenTaskId(null);
                        }}
                        className="rounded bg-zinc-800 px-2 py-0.5 text-[13px] font-semibold text-zinc-300 hover:bg-zinc-700"
                      >
                        ⋯
                      </button>
                      {actionsMenuOpenTaskId === taskId && (
                        <div
                          data-debug-id={`taskchain-task-actions-menu-${taskId}`}
                          className="absolute right-0 z-30 mt-1 w-40 rounded border border-white/10 bg-[#181818] p-1 shadow-lg"
                        >
                          <button
                            type="button"
                            data-debug-id={`taskchain-task-nudge-btn-${taskId}`}
                            onClick={() => { setActionsMenuOpenTaskId(null); void handleNudge(taskId); }}
                            className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-zinc-300 hover:bg-white/10"
                          >
                            Nudge
                          </button>
                          <button
                            type="button"
                            data-debug-id={`taskchain-task-lgtm-btn-${taskId}`}
                            onClick={() => { setActionsMenuOpenTaskId(null); void handleVote(taskId, 'lgtm'); }}
                            className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-emerald-400 hover:bg-emerald-900/40"
                          >
                            LGTM
                          </button>
                          <button
                            type="button"
                            data-debug-id={`taskchain-task-ngtm-btn-${taskId}`}
                            onClick={() => { setActionsMenuOpenTaskId(null); void handleVote(taskId, 'ngtm'); }}
                            className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-red-400 hover:bg-red-900/40"
                          >
                            NGTM
                          </button>
                          {/* Status submenu (kept inline; one status list at a time). */}
                          <button
                            type="button"
                            data-debug-id={`taskchain-task-status-menu-btn-${taskId}`}
                            onClick={() => setStatusMenuOpenTaskId(statusMenuOpenTaskId === taskId ? null : taskId)}
                            className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-zinc-300 hover:bg-white/10"
                          >
                            Status ▾
                          </button>
                          {statusMenuOpenTaskId === taskId && (
                            <div className="ml-2 border-l border-white/10 pl-1">
                              {['in_progress', 'in_validation', 'paused', 'completed'].map((st) => (
                                <button
                                  key={st}
                                  type="button"
                                  data-debug-id={`taskchain-task-status-${st}-btn-${taskId}`}
                                  onClick={() => { setActionsMenuOpenTaskId(null); setStatusMenuOpenTaskId(null); void handleStatusChange(taskId, st); }}
                                  className="block w-full rounded px-3 py-1.5 text-left text-[11px] text-zinc-300 hover:bg-white/10"
                                >
                                  {st}
                                </button>
                              ))}
                            </div>
                          )}
                          <button
                            type="button"
                            data-debug-id={`taskchain-task-cancel-btn-${taskId}`}
                            onClick={() => { setActionsMenuOpenTaskId(null); void handleCancelTask(taskId); }}
                            className="mt-0.5 block w-full rounded border-t border-white/10 px-3 py-1.5 text-left text-[11px] font-semibold text-zinc-400 hover:bg-red-900/50 hover:text-red-300"
                          >
                            Cancel
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                </div>

                {/* Expanded Card Details (Description & Comments) */}
                {isExpanded && (
                  <div className="mt-3 border-t border-white/5 pt-3 space-y-3">
                    {/* H12: full description shows ONLY when expanded. */}
                    {task.description && (
                      <p
                        data-debug-id={`taskchain-task-description-${taskId}`}
                        className="whitespace-pre-wrap text-[11.5px] leading-5 text-zinc-300"
                      >
                        {task.description}
                      </p>
                    )}
                    {/* H12: reviewers moved into the expanded details to keep the
                        collapsed header to a compact single line. */}
                    {task.reviewerRefs && task.reviewerRefs.length > 0 && (
                      <div data-debug-id={`taskchain-task-reviewers-${taskId}`} className="text-[11px] text-zinc-400">
                        reviewers: {task.reviewerRefs.map((r: any, ri: number) => (
                          <React.Fragment key={r.agent_instance_id || r.user_id || ri}>
                            {ri > 0 ? ', ' : ''}
                            {r.agent_instance_id
                              ? <InstanceIdLink instanceId={r.agent_instance_id} />
                              : <span className="text-zinc-300">{r.user_id}</span>}
                          </React.Fragment>
                        ))}
                      </div>
                    )}
                    {/* Comments Thread */}
                    <div data-debug-id={`taskchain-task-comments-${taskId}`} className="space-y-2">
                      <span className="font-semibold text-zinc-400">Comments:</span>
                      {(task.comments || []).map((comment: any, idx: number) => (
                        <div
                          key={comment.commentId || idx}
                          data-debug-id={`taskchain-task-comment-${taskId}-${idx}`}
                          className="rounded bg-zinc-900 p-2 text-[11px]"
                        >
                          <div className="font-semibold text-zinc-400">
                            {comment.authorAgentInstanceId || 'user'}:
                          </div>
                          <div className="mt-1 text-zinc-200">
                            <Markdown source={comment.body || ''} compact copyAll={false} data-debug-id={`taskchain-task-comment-body-${taskId}-${idx}`} />
                            {artifactIdsFromText(comment.body || '').length > 0 ? (
                              <div data-debug-id={`taskchain-task-comment-artifacts-${taskId}-${idx}`} className="mt-2 flex flex-wrap gap-2">
                                {artifactIdsFromText(comment.body || '').map((artifactId) => (
                                  <ArtifactAttachmentPreview
                                    key={artifactId}
                                    artifactId={artifactId}
                                    session={{ daemonUrl: '', clientToken: '' }}
                                    debugId={`taskchain-task-comment-artifact-${taskId}-${idx}-${artifactId}`}
                                  />
                                ))}
                              </div>
                            ) : null}
                          </div>
                        </div>
                      ))}

                      {/* Comment Composer */}
                      <div className="space-y-2 pt-1">
                        {taskCommentAttachments.length > 0 ? (
                          <div data-debug-id={`taskchain-task-comment-attachment-tray-${taskId}`} className="space-y-1 rounded border border-white/10 bg-black/20 p-2">
                            {taskCommentAttachments.map((attachment) => (
                              <div key={attachment.localId} data-debug-id={`taskchain-task-comment-attachment-${taskId}-${attachment.localId}`} className="rounded bg-zinc-950/60 px-2 py-1.5">
                                <div className="flex min-w-0 items-center gap-2">
                                  <span className={attachment.status === 'uploaded' ? 'text-emerald-300' : attachment.status === 'error' ? 'text-red-300' : 'text-sky-300'}>{attachment.status === 'uploading' ? '⇧' : attachment.status === 'uploaded' ? '✓' : '!'}</span>
                                  <span className="min-w-0 flex-1 truncate" title={attachment.name}>{attachment.name}</span>
                                  <span className={attachment.status === 'uploaded' ? 'text-emerald-300' : attachment.status === 'error' ? 'text-red-300' : 'text-sky-300'}>{attachment.status === 'uploading' ? 'Uploading…' : attachment.status === 'uploaded' ? 'Uploaded' : 'Failed'}</span>
                                  {attachment.status === 'error' ? (
                                    <button type="button" data-debug-id={`taskchain-task-comment-attachment-retry-${taskId}-${attachment.localId}`} onClick={() => void uploadCommentAttachment(taskId, attachment.file, attachment.localId)} className="rounded border border-white/10 px-2 py-0.5 text-zinc-300 hover:bg-white/10">
                                      Retry
                                    </button>
                                  ) : null}
                                  <button type="button" data-debug-id={`taskchain-task-comment-attachment-remove-${taskId}-${attachment.localId}`} onClick={() => updateCommentAttachments(taskId, (items) => items.filter((item) => item.localId !== attachment.localId))} className="rounded border border-white/10 px-2 py-0.5 text-zinc-400 hover:bg-white/10">
                                    Remove
                                  </button>
                                </div>
                                {attachment.status === 'uploading' ? <div data-debug-id={`taskchain-task-comment-attachment-progress-${taskId}-${attachment.localId}`} className="mt-1 h-1 overflow-hidden rounded-full bg-white/10"><div className="h-full w-1/2 animate-pulse rounded-full bg-sky-300" /></div> : null}
                                {attachment.error ? <div data-debug-id={`taskchain-task-comment-attachment-error-${taskId}-${attachment.localId}`} className="mt-1 text-red-300">{attachment.error}</div> : null}
                              </div>
                            ))}
                            {taskCommentUploading ? <div data-debug-id={`taskchain-task-comment-uploading-hint-${taskId}`} className="text-[11px] text-zinc-500">You can keep typing. Send unlocks when uploads finish.</div> : null}
                            {taskCommentFailed ? <div data-debug-id={`taskchain-task-comment-failed-hint-${taskId}`} className="text-[11px] text-red-300">Retry or remove failed uploads before sending.</div> : null}
                          </div>
                        ) : null}
                        <div className="flex min-w-0 gap-2">
                          <label data-debug-id={`taskchain-task-comment-attach-btn-${taskId}`} className="grid h-8 w-8 shrink-0 cursor-pointer place-items-center rounded border border-white/10 bg-zinc-900 text-sm font-semibold text-zinc-400 hover:border-sky-500 hover:text-white" title="Upload attachment">
                            <input
                              type="file"
                              multiple
                              data-debug-id={`taskchain-task-comment-attach-input-${taskId}`}
                              className="hidden"
                              onChange={(e) => {
                                const files = Array.from(e.target.files || []) as File[];
                                e.target.value = '';
                                files.forEach((file) => void uploadCommentAttachment(taskId, file));
                              }}
                            />
                            ＋
                          </label>
                          <input
                            type="text"
                            data-debug-id={`taskchain-task-comment-input-${taskId}`}
                            placeholder="Write a comment, paste an image/file, or attach one..."
                            value={commentInputs[taskId] || ''}
                            onChange={(e) => setCommentInputs({ ...commentInputs, [taskId]: e.target.value })}
                            onPaste={(e) => handleCommentPaste(e, taskId)}
                            className="min-w-0 flex-1 rounded border border-white/10 bg-zinc-900 px-2 py-1 text-base text-white placeholder-zinc-500 focus:border-sky-500 focus:outline-none sm:text-sm"
                          />
                          <button
                            type="button"
                            data-debug-id={`taskchain-task-comment-submit-btn-${taskId}`}
                            disabled={!taskCommentCanSend}
                            onClick={() => handleAddComment(taskId)}
                            title={taskCommentUploading ? 'Wait for uploads to finish before sending' : taskCommentFailed ? 'Retry or remove failed uploads before sending' : 'Send comment'}
                            className="rounded bg-sky-600 px-3 py-1 font-semibold text-white hover:bg-sky-500 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400"
                          >
                            {taskCommentUploading ? 'Uploading…' : 'Send'}
                          </button>
                        </div>
                      </div>
                    </div>
                  </div>
                )}
              </div>
            );
          })
        )}
      </div>

      {/* New Task Modal */}
      {showNewTaskModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <form
            onSubmit={handleCreateTask}
            className="w-full max-w-md rounded-lg border border-white/10 bg-[#141414] p-5 text-xs text-white"
          >
            <h3 className="text-sm font-bold text-white">Create New Task</h3>
            <div className="mt-4 space-y-3">
              <div>
                <label className="block text-zinc-400">Title</label>
                <input
                  type="text"
                  data-debug-id="taskchain-new-task-title-input"
                  required
                  value={newTaskTitle}
                  onChange={(e) => setNewTaskTitle(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white placeholder-zinc-500 focus:outline-none focus:border-sky-500"
                  placeholder="Task title..."
                />
              </div>
              <div>
                <label className="block text-zinc-400">Description</label>
                <textarea
                  value={newTaskDesc}
                  onChange={(e) => setNewTaskDesc(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white placeholder-zinc-500 focus:outline-none focus:border-sky-500"
                  placeholder="Task description (optional)..."
                  rows={3}
                />
              </div>
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowNewTaskModal(false)}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-debug-id="taskchain-new-task-submit-btn"
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500"
              >
                Create Task
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Add Agent to Chain popup: launch a new instance (identity + bridge +
          provider + tier) and add it to this chain with the chosen role. */}
      {showAddMemberModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <form
            onSubmit={handleAddMember}
            className="w-full max-w-md rounded-lg border border-white/10 bg-[#141414] p-5 text-xs text-white"
          >
            <h3 className="text-sm font-bold text-white">Add Agent to Task Chain</h3>
            <p className="mt-1 text-[11px] text-zinc-500">Launch a new instance of an agent onto a bridge and add it to this chain.</p>
            <div className="mt-4 space-y-3">
              <div>
                <label className="block text-zinc-400">Agent identity</label>
                <select
                  data-debug-id="taskchain-add-agent-agentid-select"
                  required
                  value={addAgentId}
                  onChange={(e) => setAddAgentId(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="">Choose agent…</option>
                  {agentIdentities.map((a: any) => {
                    const id = String(a.agent_id || a.agentId || a.id || '');
                    return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                  })}
                </select>
              </div>
              <div>
                <label className="block text-zinc-400">Bridge</label>
                <select
                  data-debug-id="taskchain-add-agent-bridge-select"
                  value={addBridgeId}
                  onChange={(e) => { setAddBridgeId(e.target.value); setAddProvider(''); setAddTier(''); }}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="">Choose bridge…</option>
                  {addBridgeRows.map((row) => <option key={row.bridgeId} value={row.bridgeId}>{bridgeLabel(row.bridge)}</option>)}
                </select>
                {addBridgeRows.length === 0 && <p className="mt-1 text-[11px] text-amber-300/80">No online bridge with provider capabilities is available.</p>}
              </div>
              <div>
                <label className="block text-zinc-400">Provider</label>
                <select
                  data-debug-id="taskchain-add-agent-provider-select"
                  value={addProvider}
                  onChange={(e) => { setAddProvider(e.target.value); setAddTier(''); }}
                  disabled={!selectedAddBridge}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                >
                  <option value="">Use bridge default provider</option>
                  {addProviderOptions.map((p) => <option key={p} value={p}>{p}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-zinc-400">Tier</label>
                <select
                  data-debug-id="taskchain-add-agent-tier-select"
                  value={addTier}
                  onChange={(e) => setAddTier(e.target.value)}
                  disabled={!selectedAddBridge}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                >
                  <option value="">Use bridge default tier</option>
                  {addTierOptions.map((tier) => <option key={tier} value={tier}>{tier}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-zinc-400">Role</label>
                <select
                  data-debug-id="taskchain-add-agent-role-select"
                  value={newMemberRole}
                  onChange={(e) => setNewMemberRole(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="worker">worker</option>
                  <option value="reviewer">reviewer</option>
                  <option value="coordinator">coordinator</option>
                </select>
              </div>
              {addAgentError && <p data-debug-id="taskchain-add-agent-error" className="text-[11px] text-red-300">{addAgentError}</p>}
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowAddMemberModal(false)}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-add-agent-submit"
                type="submit"
                disabled={addingAgent || !addAgentId}
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
              >
                {addingAgent ? 'Launching…' : 'Launch & Add'}
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
};

// H10: shellHash builds the routed-shell hash link the dashboard uses for
// navigation (mirrors the helper in AgentDetailPanel).
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }

// H10: InstanceIdLink renders an agent instance id as a clickable control that
// opens that agent's chat. It resolves instance_id -> conversation_id via the
// agents API (GET /agent-instances/{id}) and links to shellHash(/conversations/
// <conversationId>). Graceful fallbacks: while resolving it links to the agent
// instance's chain-agnostic detail is unknown, so it links to /conversations only
// once resolved; if no conversation can be resolved it falls back to the agents
// list route and shows a tooltip — never a dead link and never a crash. user_id
// refs are NOT agent instances and must be rendered with plain text by callers.
export function InstanceIdLink({ instanceId }: { instanceId: string }) {
  const trimmed = String(instanceId || '').trim();
  // Only agent instance ids are clickable; guard against empty values.
  const { data } = useFetchAgentInstanceQuery({ instanceId: trimmed }, { skip: !trimmed });
  if (!trimmed) return null;
  const inst = data?.instance || null;
  const conversationId = String(inst?.conversation_id || inst?.conversationId || '');
  const href = conversationId
    ? shellHash(`/conversations/${conversationId}`)
    : shellHash(`/agents`);
  const title = conversationId
    ? `Open chat with ${trimmed}`
    : `No conversation resolved for ${trimmed} — open agents`;
  return (
    <a
      data-debug-id={`taskchain-instance-link-${trimmed}`}
      href={href}
      title={title}
      className="font-mono text-sky-300 underline decoration-dotted underline-offset-2 hover:text-sky-200"
    >
      {trimmed}
    </a>
  );
}

export default TaskChainOverview;
