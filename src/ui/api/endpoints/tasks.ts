import * as daemonApi from '../daemonApi';
import { upsertTaskLogEvent } from '../taskCache';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function normalizeTask(task: any) {
  const result: any = {
    id: task.task_id || task.id,
    taskId: task.task_id || task.id,
    chainId: task.chain_id || '',
    title: task.title || '',
    description: task.description || '',
    priority: task.priority || 'normal',
    status: task.status || 'pending',
    assigneeAgentInstanceId: task.assignee_agent_instance_id || '',
    reviewerAgentInstanceId: task.reviewer_agent_instance_id || '',
    coordinatorAgentInstanceId: task.coordinator_agent_instance_id || '',
    dependsOn: task.depends_on || (task.depends_on_task_ids ? task.depends_on_task_ids : []),
    blocked: Boolean(task.blocked),
    assigneeRef: task.assignee_ref || task.assigneeRef || (task.assignee_agent_instance_id ? { type: 'agent_instance', agent_instance_id: task.assignee_agent_instance_id } : null),
    reviewerRefs: task.reviewer_refs || task.reviewerRefs || (task.reviewer_agent_instance_id ? [{ type: 'agent_instance', agent_instance_id: task.reviewer_agent_instance_id }] : []),
    comments: (task.comments || []).map(normalizeTaskComments),
    createdBy: task.created_by || '',
    createdAtUnixMs: Number(task.created_at_unix_ms || 0),
    updatedAtUnixMs: Number(task.updated_at_unix_ms || 0),
    notActionableReason: task.not_actionable_reason || '',
    votes: (task.votes || []).map((vote: any) => ({
      reviewerAgentInstanceId: vote.reviewer_agent_instance_id || vote.reviewerAgentInstanceId,
      vote: vote.vote || (vote.approved ? 'lgtm' : 'ngtm'),
      comment: vote.comment || '',
    })),
    participants: (task.participants || []).map((participant: any) => ({
      agentInstanceId: participant.agent_instance_id,
      role: participant.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    commentIds: task.comment_ids || [],
  };
  if (task.acceptance_criteria !== undefined) {
    result.acceptanceCriteria = task.acceptance_criteria;
  }
  return result;
}

function normalizeTaskLogEvent(event: any) {
  return {
    eventId: event.event_id || '',
    kind: event.kind || '',
    taskId: event.task_id || '',
    chainId: event.chain_id || '',
    status: event.status || '',
    body: event.body || '',
    authorAgentInstanceId: event.author_agent_instance_id || '',
    createdUnixMs: Number(event.created_unix_ms || 0),
    commentId: event.comment_id || '',
  };
}

function normalizeTaskComments(comment: any) {
  return {
    commentId: comment.comment_id || '',
    taskId: comment.task_id || '',
    chainId: comment.chain_id || '',
    authorAgentInstanceId: comment.author_agent_instance_id || '',
    body: comment.body || '',
    resolved: Boolean(comment.resolved),
    createdUnixMs: Number(comment.created_unix_ms || 0),
  };
}

function normalizeTaskLogPage(taskId: string, data: any) {
  return {
    taskId,
    events: (data?.events || []).map(normalizeTaskLogEvent),
    nextCursor: Number(data?.next_cursor || data?.nextCursor || 0),
    hasMore: Boolean(data?.has_more || data?.hasMore),
    total: Number(data?.total || 0),
  };
}

function taskMutationAuth(session: any, agentToken?: string) {
  return {
    agentToken: String(agentToken || '').trim(),
    clientInstanceId: session?.clientInstanceId || '',
    clientToken: session?.clientToken || '',
  };
}

function preciseTaskTags(taskId?: string, chainId?: string, includeComments = false) {
  const tags: Array<{ type: 'TaskLog' | 'Task' | 'TaskComments' | 'ChainTasks'; id: string }> = [];
  if (taskId) {
    tags.push({ type: 'Task', id: taskId });
    tags.push({ type: 'TaskLog', id: taskId });
    if (includeComments) tags.push({ type: 'TaskComments', id: taskId });
  }
  if (chainId) tags.push({ type: 'ChainTasks', id: chainId });
  return tags;
}


function normalizeTaskChainDetail(data: any) {
  if (!data) return null;
  return {
    chainId: data.chain_id || data.chainId,
    title: data.title || '',
    description: data.description || '',
    publishState: data.publish_state || 'draft',
    status: data.status || 'active',
    kind: data.kind || 'team_work',
    coordinatorAgentInstanceId: data.coordinator_agent_instance_id || '',
    defaultReviewerRefs: data.default_reviewer_refs || [],
    members: (data.members || []).map((m: any) => ({
      chainId: m.chain_id,
      agentInstanceId: m.agent_instance_id,
      agentId: m.agent_id,
      role: m.role,
      createdAt: m.created_at,
    })),
    tasks: (data.tasks || []).map(normalizeTask),
    createdAt: data.created_at || '',
    updatedAt: data.updated_at || '',
  };
}

export const tasksApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    fetchTaskChainDetail: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chain: null };
        const data = await daemonApi.fetchTaskChainDetail({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
        });
        return { chain: data ? normalizeTaskChainDetail(data) : null };
      }),
      providesTags: (_result, _error, { chainId }) => [
        { type: 'Chain', id: chainId },
        { type: 'ChainTasks', id: chainId },
      ],
    }),
    createTaskChain: build.mutation<any, { title: string; description?: string; kind?: string; coordinatorAgentId?: string }>({
      queryFn: withSessionQuery(async ({ title, description, kind, coordinatorAgentId }, { session }) => {
        return daemonApi.createTaskChainRest({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          title,
          description,
          kind,
          coordinatorAgentId,
        });
      }),
      invalidatesTags: ['ChainList'],
    }),
    updateTaskChain: build.mutation<any, { chainId: string; title?: string; description?: string; status?: string }>({
      queryFn: withSessionQuery(async ({ chainId, title, description, status }, { session }) => {
        return daemonApi.updateTaskChainRest({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          title,
          description,
          status,
        });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }, 'ChainList'],
    }),
    updateTaskDetail: build.mutation<any, { chainId: string; taskId: string; title?: string; description?: string; assigneeRef?: any; reviewerRefs?: any[] }>({
      queryFn: withSessionQuery(async ({ chainId, taskId, title, description, assigneeRef, reviewerRefs }, { session }) => {
        return daemonApi.updateTaskDetail({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          taskId,
          title,
          description,
          assigneeRef,
          reviewerRefs,
        });
      }),
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    cancelTaskDetail: build.mutation<any, { chainId: string; taskId: string }>({
      queryFn: withSessionQuery(async ({ chainId, taskId }, { session }) => {
        return daemonApi.cancelTaskDetail({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          taskId,
        });
      }),
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    addChainMember: build.mutation<any, { chainId: string; agentInstanceId: string; role?: string }>({
      queryFn: withSessionQuery(async ({ chainId, agentInstanceId, role }, { session }) => {
        return daemonApi.addChainMember({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          agentInstanceId,
          role,
        });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }],
    }),
    removeChainMember: build.mutation<any, { chainId: string; agentInstanceId: string }>({
      queryFn: withSessionQuery(async ({ chainId, agentInstanceId }, { session }) => {
        return daemonApi.removeChainMember({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          agentInstanceId,
        });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }],
    }),

    fetchChainTasks: build.query<any, { chainId: string; limit?: number; offset?: number }>({
      queryFn: withSessionQuery(async ({ chainId, limit = 100, offset = 0 }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, tasks: [] };
        const data = await daemonApi.listChainTasks({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          limit,
          offset,
        });
        return {
          chainId,
          tasks: (data?.tasks || []).map(normalizeTask),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      providesTags: (result, _error, { chainId }) => [
        { type: 'ChainTasks' as const, id: chainId },
        ...((result?.tasks || []).map((task: any) => ({ type: 'Task' as const, id: task.taskId }))),
      ],
    }),
    fetchChainTasksPage: build.query<any, { chainId: string; limit?: number; offset: number }>({
      queryFn: withSessionQuery(async ({ chainId, limit = 100, offset }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, tasks: [] };
        const data = await daemonApi.listChainTasks({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          limit,
          offset,
        });
        return {
          chainId,
          tasks: (data?.tasks || []).map(normalizeTask),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const { chainId, limit = 100 } = arg;
          const cacheKeyArgs = { chainId, limit };
          dispatch(
            tasksApi.util.updateQueryData('fetchChainTasks', cacheKeyArgs as any, (draft) => {
              if (!draft) return;
              draft.has_more = data.has_more;
              draft.next_offset = data.next_offset;
              draft.total = data.total;
              
              const existingIds = new Set(draft.tasks.map((t: any) => t.taskId));
              for (const task of data.tasks) {
                if (!existingIds.has(task.taskId)) {
                  draft.tasks.push(task);
                }
              }
            })
          );
        } catch {}
      }
    }),
    fetchTask: build.query<any, { taskId: string }>({
      queryFn: withSessionQuery(async ({ taskId }, { session }) => {
        if (!session?.clientToken || !taskId) return { task: null };
        const data = await daemonApi.fetchTask({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
        });
        return {
          task: data?.task ? normalizeTask(data.task) : null,
        };
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'Task', id: taskId }],
    }),
    fetchTaskComments: build.query<any, { taskId: string; unresolved?: boolean; limit?: number; offset?: number }>({
      queryFn: withSessionQuery(async ({ taskId, unresolved = false, limit = 20, offset = 0 }, { session }) => {
        if (!session?.clientToken || !taskId) return { taskId, comments: [] };
        const data = await daemonApi.fetchTaskComments({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          unresolved,
          limit,
          offset,
        });
        return {
          taskId,
          comments: (data?.comments || []).map(normalizeTaskComments),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskComments', id: taskId }],
    }),
    fetchTaskCommentsPage: build.query<any, { taskId: string; unresolved?: boolean; limit?: number; offset: number }>({
      queryFn: withSessionQuery(async ({ taskId, unresolved = false, limit = 20, offset }, { session }) => {
        if (!session?.clientToken || !taskId) return { taskId, comments: [] };
        const data = await daemonApi.fetchTaskComments({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          unresolved,
          limit,
          offset,
        });
        return {
          taskId,
          comments: (data?.comments || []).map(normalizeTaskComments),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const { taskId, unresolved = false, limit = 20 } = arg;
          const cacheKeyArgs = { taskId, unresolved, limit };
          dispatch(
            tasksApi.util.updateQueryData('fetchTaskComments', cacheKeyArgs as any, (draft) => {
              if (!draft) return;
              draft.has_more = data.has_more;
              draft.next_offset = data.next_offset;
              draft.total = data.total;
              
              const existingIds = new Set(draft.comments.map((c: any) => c.comment_id || c.commentId));
              for (const comment of data.comments) {
                const id = comment.comment_id || comment.commentId;
                if (!existingIds.has(id)) {
                  draft.comments.push(comment);
                }
              }
            })
          );
        } catch {}
      }
    }),
    fetchTaskComment: build.query<any, { taskId: string; commentId: string }>({
      queryFn: withSessionQuery(async ({ taskId, commentId }, { session }) => {
        if (!session?.clientToken || !taskId || !commentId) return { comment: null };
        const data = await daemonApi.fetchTaskComment({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          commentId,
        });
        return {
          comment: data?.comment ? normalizeTaskComments(data.comment) : null,
        };
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskComments', id: taskId }],
    }),
    fetchTaskLog: build.query<any, { taskId: string; limit?: number }>({
      queryFn: withSessionQuery(async ({ taskId, limit = 50 }, { session }) => {
        if (!session?.clientToken || !taskId) return normalizeTaskLogPage(taskId, null);
        const data = await daemonApi.fetchTaskLog({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          taskId,
          limit,
          cursor: 0,
        });
        return normalizeTaskLogPage(taskId, data);
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskLog', id: taskId }],
    }),
    fetchTaskLogPage: build.query<any, { taskId: string; cursor: number; limit?: number }>({
      queryFn: withSessionQuery(async ({ taskId, cursor, limit = 50 }, { session }) => {
        if (!session?.clientToken || !taskId) return normalizeTaskLogPage(taskId, null);
        const data = await daemonApi.fetchTaskLog({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          taskId,
          limit,
          cursor,
        });
        return normalizeTaskLogPage(taskId, data);
      }),
      async onQueryStarted({ taskId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          dispatch(tasksApi.util.updateQueryData('fetchTaskLog', { taskId }, (draft: any) => {
            if (!draft) return;
            for (const event of data?.events || []) {
              upsertTaskLogEvent(draft.events || (draft.events = []), event);
            }
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
            draft.total = Number(data?.total || 0);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    createTask: build.mutation<any, { chainId: string; title: string; description?: string; status?: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ chainId, title, description, status = 'planning', agentToken }, { session }) => {
        return daemonApi.createTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          chain_id: chainId,
          title,
          description,
          status,
        });
      }),
      invalidatesTags: (_result, _error, { chainId }) => chainId ? [{ type: 'ChainTasks', id: chainId }] : [],
    }),
    deleteTask: build.mutation<any, { taskId: string; chainId: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentToken }, { session }) => {
        return daemonApi.deleteTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId, true),
    }),
    addTaskComment: build.mutation<any, { taskId: string; chainId: string; body: string; agentToken?: string; resolveImmediately?: boolean }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, body, agentToken, resolveImmediately }, { session }) => {
        const response = await daemonApi.addTaskComment({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          body,
        });
        if (resolveImmediately && response?.comment_id) {
          await daemonApi.resolveTaskComment({
            daemonUrl: session.daemonUrl,
            ...taskMutationAuth(session, agentToken),
            taskId,
            chainId,
            commentId: response.comment_id,
          });
        }
        return response;
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId, true),
    }),
    resolveTaskComment: build.mutation<any, { taskId: string; chainId: string; commentId: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, commentId, agentToken }, { session }) => {
        return daemonApi.resolveTaskComment({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          commentId,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId, true),
    }),
    setTaskStatus: build.mutation<any, { taskId: string; chainId: string; status: string; body?: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, status, body = '', agentToken }, { session }) => {
        return daemonApi.updateTaskStatus({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          status,
          body,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    updateTask: build.mutation<any, { taskId: string; chainId: string; title?: string; description?: string; acceptanceCriteria?: string; dependsOn?: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, title, description, acceptanceCriteria, dependsOn, agentToken }, { session }) => {
        return daemonApi.updateTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          title,
          description,
          acceptanceCriteria,
          dependsOn,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    assignTask: build.mutation<any, { taskId: string; chainId: string; agentInstanceId: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentInstanceId, agentToken }, { session }) => {
        return daemonApi.assignTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          agentInstanceId,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    addTaskParticipant: build.mutation<any, { taskId: string; chainId: string; agentInstanceId: string; role: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentInstanceId, role, agentToken }, { session }) => {
        return daemonApi.addTaskParticipant({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          agentInstanceId,
          role,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    removeTaskParticipant: build.mutation<any, { taskId: string; chainId: string; agentInstanceId: string; role: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentInstanceId, role, agentToken }, { session }) => {
        return daemonApi.removeTaskParticipant({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          agentInstanceId,
          role,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    voteTask: build.mutation<any, { taskId: string; chainId: string; result?: 'lgtm' | 'ngtm'; approved?: boolean; comment?: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, result, approved, comment = '', agentToken }, { session }) => {
        const isApproved = approved ?? (result === 'lgtm');
        return daemonApi.voteTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          approved: isApproved,
          comment,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    nudgeTask: build.mutation<any, { taskId: string; chainId: string; body?: string; message?: string; interrupt?: boolean; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, body, message, interrupt, agentToken }, { session }) => {
        return daemonApi.nudgeTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          body: body ?? message ?? '',
          interrupt,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
  }),
});

export const {
  useFetchChainTasksQuery,
  useLazyFetchChainTasksPageQuery,
  useFetchTaskQuery,
  useLazyFetchTaskQuery,
  useFetchTaskCommentsQuery,
  useLazyFetchTaskCommentsPageQuery,
  useFetchTaskCommentQuery,
  useLazyFetchTaskCommentQuery,
  useFetchTaskLogQuery,
  useLazyFetchTaskLogPageQuery,

  useFetchTaskChainDetailQuery,
  useCreateTaskChainMutation,
  useUpdateTaskChainMutation,
  useUpdateTaskDetailMutation,
  useCancelTaskDetailMutation,
  useAddChainMemberMutation,
  useRemoveChainMemberMutation,

  useCreateTaskMutation,
  useDeleteTaskMutation,
  useAddTaskCommentMutation,
  useResolveTaskCommentMutation,
  useSetTaskStatusMutation,
  useUpdateTaskMutation,
  useAssignTaskMutation,
  useAddTaskParticipantMutation,
  useRemoveTaskParticipantMutation,
  useVoteTaskMutation,
  useNudgeTaskMutation,
} = tasksApi;
