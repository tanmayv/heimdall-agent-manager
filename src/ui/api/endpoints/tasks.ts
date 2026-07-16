import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function normalizeTask(task: any) {
  return {
    id: task.task_id,
    taskId: task.task_id,
    chainId: task.chain_id || '',
    title: task.title || '',
    description: task.description || '',
    acceptanceCriteria: task.acceptance_criteria || '',
    priority: task.priority || 'normal',
    status: task.status || 'pending',
    assigneeAgentInstanceId: task.assignee_agent_instance_id || '',
    reviewerAgentInstanceId: task.reviewer_agent_instance_id || '',
    coordinatorAgentInstanceId: task.coordinator_agent_instance_id || '',
    dependsOn: task.depends_on || '',
    createdBy: task.created_by || '',
    createdAtUnixMs: Number(task.created_at_unix_ms || 0),
    updatedAtUnixMs: Number(task.updated_at_unix_ms || 0),
    notActionableReason: task.not_actionable_reason || '',
    votes: (task.votes || []).map((vote: any) => ({
      reviewerAgentInstanceId: vote.reviewer_agent_instance_id,
      approved: Boolean(vote.approved),
      comment: vote.comment || '',
    })),
    participants: (task.participants || []).map((participant: any) => ({
      agentInstanceId: participant.agent_instance_id,
      role: participant.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    unresolvedComments: (task.unresolved_comments || []).map(normalizeTaskLogEvent),
  };
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

export const tasksApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    fetchChainTasks: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, tasks: [] };
        const data = await daemonApi.listChainTasks({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
        });
        return {
          chainId,
          tasks: (data?.tasks || []).map(normalizeTask),
        };
      }),
      providesTags: (result, _error, { chainId }) => [
        { type: 'ChainTasks' as const, id: chainId },
        ...((result?.tasks || []).map((task: any) => ({ type: 'Task' as const, id: task.taskId }))),
      ],
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
    fetchTaskComments: build.query<any, { taskId: string; unresolved?: boolean }>({
      queryFn: withSessionQuery(async ({ taskId, unresolved = false }, { session }) => {
        if (!session?.clientToken || !taskId) return { taskId, comments: [] };
        const data = await daemonApi.fetchTaskComments({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          unresolved,
        });
        return {
          taskId,
          comments: (data?.comments || []).map(normalizeTaskComments),
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
            const byId = new Map<string, any>();
            for (const event of [...(draft.events || []), ...(data?.events || [])]) {
              byId.set(event.eventId || `${event.kind}-${event.createdUnixMs}-${event.body}`, event);
            }
            draft.events = Array.from(byId.values()).sort((left: any, right: any) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
            draft.total = Number(data?.total || 0);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    createTask: build.mutation<any, { chainId: string; title: string; status?: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ chainId, title, status = 'planning', agentToken }, { session }) => {
        return daemonApi.createTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          chain_id: chainId,
          title,
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
    setTaskStatus: build.mutation<any, { taskId: string; chainId: string; status: string; body: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, status, body, agentToken }, { session }) => {
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
    voteTask: build.mutation<any, { taskId: string; chainId: string; approved: boolean; comment: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, approved, comment, agentToken }, { session }) => {
        return daemonApi.voteTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          approved,
          comment,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    nudgeTask: build.mutation<any, { taskId: string; chainId: string; body: string; interrupt?: boolean; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, body, interrupt, agentToken }, { session }) => {
        return daemonApi.nudgeTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          body,
          interrupt,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
  }),
});

export const {
  useFetchChainTasksQuery,
  useFetchTaskCommentsQuery,
  useFetchTaskLogQuery,
  useLazyFetchTaskLogPageQuery,
} = tasksApi;
