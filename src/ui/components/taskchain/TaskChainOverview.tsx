import React, { useState } from 'react';
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

interface TaskChainOverviewProps {
  chainId: string;
  onClose?: () => void;
  isMobile?: boolean;
}

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
  const [voteTask] = useVoteTaskMutation();
  const [nudgeTask] = useNudgeTaskMutation();
  const [addMember] = useAddChainMemberMutation();
  const [removeMember] = useRemoveChainMemberMutation();

  // Local state
  const [descExpanded, setDescExpanded] = useState(true);
  const [expandedTaskIds, setExpandedTaskIds] = useState<Record<string, boolean>>({});
  const [commentInputs, setCommentInputs] = useState<Record<string, string>>({});
  const [statusMenuOpenTaskId, setStatusMenuOpenTaskId] = useState<string | null>(null);

  // Modal state
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [newTaskTitle, setNewTaskTitle] = useState('');
  const [newTaskDesc, setNewTaskDesc] = useState('');
  const [showAddMemberModal, setShowAddMemberModal] = useState(false);
  const [newMemberInstanceId, setNewMemberInstanceId] = useState('');
  const [newMemberRole, setNewMemberRole] = useState('worker');

  const chain = data?.chain;
  const tasks: any[] = chain?.tasks || [];
  const members: any[] = chain?.members || [];

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

  const handleAddMember = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newMemberInstanceId.trim()) return;
    try {
      await addMember({
        chainId,
        agentInstanceId: newMemberInstanceId.trim(),
        role: newMemberRole,
      }).unwrap();
      setNewMemberInstanceId('');
      setShowAddMemberModal(false);
      refetch();
    } catch (err) {
      console.error('Failed to add member:', err);
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

  const handleAddComment = async (taskId: string) => {
    const text = commentInputs[taskId]?.trim();
    if (!text) return;
    try {
      await addComment({ chainId, taskId, body: text }).unwrap();
      setCommentInputs((prev) => ({ ...prev, [taskId]: '' }));
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
                {m.role}: {m.agentInstanceId || m.agent_instance_id}
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
                      {task.description && (
                        <p
                          data-debug-id={`taskchain-task-description-${taskId}`}
                          className="mt-1 whitespace-pre-wrap text-[11.5px] leading-5 text-zinc-300"
                        >
                          {task.description}
                        </p>
                      )}
                      <div className="mt-1 flex flex-wrap gap-2 text-[11px] text-zinc-400">
                        {task.assigneeRef && (
                          <span data-debug-id={`taskchain-task-assignee-${taskId}`}>
                            assignee: <span className="text-zinc-300">{task.assigneeRef.agent_instance_id || task.assigneeRef.user_id}</span>
                          </span>
                        )}
                        {task.reviewerRefs && task.reviewerRefs.length > 0 && (
                          <span data-debug-id={`taskchain-task-reviewers-${taskId}`}>
                            reviewers: <span className="text-zinc-300">{task.reviewerRefs.map((r: any) => r.agent_instance_id || r.user_id).join(', ')}</span>
                          </span>
                        )}
                      </div>
                    </div>
                  </div>

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
                  </div>
                </div>

                {/* Quick Action Buttons Strip */}
                <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-white/5 pt-2">
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-nudge-btn-${taskId}`}
                    onClick={() => handleNudge(taskId)}
                    className="rounded bg-zinc-800 px-2 py-1 text-[11px] font-semibold text-zinc-300 hover:bg-zinc-700"
                  >
                    Nudge
                  </button>
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-lgtm-btn-${taskId}`}
                    onClick={() => handleVote(taskId, 'lgtm')}
                    className="rounded bg-emerald-950 px-2 py-1 text-[11px] font-semibold text-emerald-400 border border-emerald-800 hover:bg-emerald-900"
                  >
                    LGTM
                  </button>
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-ngtm-btn-${taskId}`}
                    onClick={() => handleVote(taskId, 'ngtm')}
                    className="rounded bg-red-950 px-2 py-1 text-[11px] font-semibold text-red-400 border border-red-800 hover:bg-red-900"
                  >
                    NGTM
                  </button>

                  {/* Status Dropdown Menu */}
                  <div className="relative inline-block text-left">
                    <button
                      type="button"
                      data-debug-id={`taskchain-task-status-menu-btn-${taskId}`}
                      onClick={() => setStatusMenuOpenTaskId(statusMenuOpenTaskId === taskId ? null : taskId)}
                      className="rounded bg-zinc-800 px-2 py-1 text-[11px] font-semibold text-zinc-300 hover:bg-zinc-700"
                    >
                      Status ▾
                    </button>
                    {statusMenuOpenTaskId === taskId && (
                      <div className="absolute right-0 z-20 mt-1 w-32 rounded border border-white/10 bg-[#181818] shadow-lg">
                        {['in_progress', 'in_validation', 'paused', 'completed'].map((st) => (
                          <button
                            key={st}
                            type="button"
                            data-debug-id={`taskchain-task-status-${st}-btn-${taskId}`}
                            onClick={() => handleStatusChange(taskId, st)}
                            className="block w-full px-3 py-1.5 text-left text-[11px] text-zinc-300 hover:bg-white/10"
                          >
                            {st}
                          </button>
                        ))}
                      </div>
                    )}
                  </div>

                  <button
                    type="button"
                    data-debug-id={`taskchain-task-cancel-btn-${taskId}`}
                    onClick={() => handleCancelTask(taskId)}
                    className="rounded bg-zinc-800 px-2 py-1 text-[11px] font-semibold text-zinc-400 hover:bg-red-900/50 hover:text-red-300"
                  >
                    Cancel
                  </button>
                </div>

                {/* Expanded Card Details (Description & Comments) */}
                {isExpanded && (
                  <div className="mt-3 border-t border-white/5 pt-3 space-y-3">
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
                          <div className="mt-0.5 text-zinc-200">{comment.body}</div>
                        </div>
                      ))}

                      {/* Comment Composer */}
                      <div className="flex gap-2 pt-1">
                        <input
                          type="text"
                          data-debug-id={`taskchain-task-comment-input-${taskId}`}
                          placeholder="Write a comment..."
                          value={commentInputs[taskId] || ''}
                          onChange={(e) => setCommentInputs({ ...commentInputs, [taskId]: e.target.value })}
                          className="flex-1 rounded border border-white/10 bg-zinc-900 px-2 py-1 text-white placeholder-zinc-500 focus:outline-none focus:border-sky-500"
                        />
                        <button
                          type="button"
                          data-debug-id={`taskchain-task-comment-submit-btn-${taskId}`}
                          onClick={() => handleAddComment(taskId)}
                          className="rounded bg-sky-600 px-3 py-1 font-semibold text-white hover:bg-sky-500"
                        >
                          Send
                        </button>
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

      {/* Add Member Modal */}
      {showAddMemberModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <form
            onSubmit={handleAddMember}
            className="w-full max-w-md rounded-lg border border-white/10 bg-[#141414] p-5 text-xs text-white"
          >
            <h3 className="text-sm font-bold text-white">Add Agent to Task Chain</h3>
            <div className="mt-4 space-y-3">
              <div>
                <label className="block text-zinc-400">Agent Instance ID</label>
                <input
                  type="text"
                  required
                  value={newMemberInstanceId}
                  onChange={(e) => setNewMemberInstanceId(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white placeholder-zinc-500 focus:outline-none focus:border-sky-500"
                  placeholder="agent_instance_id..."
                />
              </div>
              <div>
                <label className="block text-zinc-400">Role</label>
                <select
                  value={newMemberRole}
                  onChange={(e) => setNewMemberRole(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="worker">worker</option>
                  <option value="reviewer">reviewer</option>
                  <option value="coordinator">coordinator</option>
                </select>
              </div>
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
                type="submit"
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500"
              >
                Add Member
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
};

export default TaskChainOverview;
