import * as daemonApi from '../daemonApi';
import { upsertTaskLogEvent } from '../taskCache';
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

// The rewrite shell is cookie-authenticated (same session as /api/v1/me), not the
// legacy per-client token session. Task-chain reads/writes below must use
// cookieJsonFetch/cookieMutation against /api/v1/task-chains/... so they work in
// the routed/Electron shell where session.clientToken is not populated.
function unwrapData(res: any): any {
  if (res && typeof res === 'object' && 'data' in res && !Array.isArray(res)) return (res as any).data;
  return res;
}

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
    commentSummary: task.comment_summary ? {
      count: Number(task.comment_summary.count || 0),
      lastCommentAt: String(task.comment_summary.last_comment_at || ''),
      lastCommentAuthorAgentInstanceId: String(task.comment_summary.last_comment_author_agent_instance_id || ''),
      lastCommentPreview: String(task.comment_summary.last_comment_preview || ''),
    } : null,
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

function preciseTaskTags(taskId?: string, chainId?: string, includeComments = true) {
  const tags: Array<{ type: 'TaskLog' | 'Task' | 'TaskComments' | 'ChainTasks' | 'Chain' | 'ChainList'; id: string }> = [];
  if (taskId) {
    tags.push({ type: 'Task', id: taskId });
    tags.push({ type: 'TaskLog', id: taskId });
    if (includeComments) tags.push({ type: 'TaskComments', id: taskId });
  }
  if (chainId) {
    tags.push({ type: 'ChainTasks', id: chainId });
    tags.push({ type: 'Chain', id: chainId });
  }
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
      queryFn: async ({ chainId }) => {
        if (!chainId) return { data: { chain: null } };
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}`);
          const data = unwrapData(raw);
          return { data: { chain: data ? normalizeTaskChainDetail(data) : null } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [
        { type: 'Chain', id: chainId },
        { type: 'ChainTasks', id: chainId },
      ],
    }),
    // Cookie-auth lazy comment fetch for the live shell. The chain/task list now
    // ships only a comment_summary (count + last), so the comment thread is
    // loaded on demand (task expand) via GET .../comments?last=N.
    fetchChainTaskComments: build.query<any, { chainId: string; taskId: string; last?: number }>({
      queryFn: async ({ chainId, taskId, last }) => {
        if (!chainId || !taskId) return { data: { taskId, comments: [] } };
        try {
          const q = last && last > 0 ? `?last=${last}` : '';
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/comments${q}`);
          const rows = unwrapData(raw);
          const comments = (Array.isArray(rows) ? rows : (rows?.comments || [])).map(normalizeTaskComments);
          return { data: { taskId, comments } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskComments' as const, id: taskId }],
    }),
    // H9 U1: the chains an agent instance COORDINATES (single canonical source on
    // the hub: task_chain_members role='coordinator'). An agent can coordinate
    // multiple chains, so this returns a list normalized to { chainId, title,
    // status } for the coordinator-chains dropdown.
    listChainsByCoordinator: build.query<Array<{ chainId: string; title: string; status: string }>, { agentInstanceId: string }>({
      queryFn: async ({ agentInstanceId }) => {
        if (!agentInstanceId) return { data: [] };
        try {
          const raw = await cookieJsonFetch(`/task-chains?coordinated_by=${encodeURIComponent(agentInstanceId)}`);
          const data = unwrapData(raw);
          const list = Array.isArray(data) ? data : [];
          return {
            data: list.map((c: any) => ({
              chainId: c.chain_id || c.chainId || '',
              title: c.title || '',
              status: c.status || 'active',
            })),
          };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'ChainList', id: `coordinator:${agentInstanceId}` },
        'ChainList',
      ],
    }),
    createTaskChain: build.mutation<any, { title: string; description?: string; kind?: string; coordinatorAgentId?: string }>({
      queryFn: async ({ title, description, kind, coordinatorAgentId }) => {
        try {
          const data = await cookieMutation('/task-chains', 'POST', { title, description: description || '', kind: kind || 'team_work', coordinator_agent_id: coordinatorAgentId || '' });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: ['ChainList'],
    }),
    updateTaskChain: build.mutation<any, { chainId: string; title?: string; description?: string; status?: string }>({
      queryFn: async ({ chainId, title, description, status }) => {
        try {
          const body: any = {};
          if (title !== undefined) body.title = title;
          if (description !== undefined) body.description = description;
          if (status !== undefined) body.status = status;
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }, 'ChainList'],
    }),
    // Explicit self-heal: promote actionable tasks, set current-tasks, nudge idle
    // agents. Coordinator/owner only (enforced hub-side). Invalidates the chain so
    // the freshly-healed statuses/pointers render.
    reconcileTaskChain: build.mutation<any, { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/reconcile`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }, { type: 'ChainTasks', id: chainId }],
    }),
    updateTaskDetail: build.mutation<any, { chainId: string; taskId: string; title?: string; description?: string; assigneeRef?: any; reviewerRefs?: any[]; dependsOn?: string[] }>({
      queryFn: async ({ chainId, taskId, title, description, assigneeRef, reviewerRefs, dependsOn }) => {
        try {
          const body: any = {};
          if (title !== undefined) body.title = title;
          if (description !== undefined) body.description = description;
          if (assigneeRef !== undefined) body.assignee_ref = assigneeRef;
          if (reviewerRefs !== undefined) body.reviewer_refs = reviewerRefs;
          if (dependsOn !== undefined) body.depends_on = dependsOn;
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    cancelTaskDetail: build.mutation<any, { chainId: string; taskId: string }>({
      queryFn: async ({ chainId, taskId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/cancel`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    // CT-3: set a task's priority (P0/P1/P2). The hub recomputes current-task
    // selection so raising priority can preempt a busy assignee.
    updateTaskPriority: build.mutation<any, { chainId: string; taskId: string; priority: string }>({
      queryFn: async ({ chainId, taskId, priority }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`, 'PATCH', { priority });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    setInstanceCurrentTask: build.mutation<any, { chainId: string; taskId: string; agentInstanceId: string }>({
      queryFn: async ({ chainId, taskId, agentInstanceId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/current-task`, 'POST', { agent_instance_id: agentInstanceId });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId, agentInstanceId }) => [
        ...preciseTaskTags(taskId, chainId),
        ...(agentInstanceId ? [{ type: 'AgentInstances' as const, id: agentInstanceId }] : []),
      ],
    }),
    addChainMember: build.mutation<any, { chainId: string; agentInstanceId: string; role?: string }>({
      queryFn: async ({ chainId, agentInstanceId, role }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/members`, 'POST', { agent_instance_id: agentInstanceId, role: role || 'worker' });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }],
    }),
    removeChainMember: build.mutation<any, { chainId: string; agentInstanceId: string }>({
      queryFn: async ({ chainId, agentInstanceId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/members/${encodeURIComponent(agentInstanceId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
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
    createTask: build.mutation<any, { chainId: string; title: string; description?: string; status?: string; agentToken?: string; assigneeRef?: any; reviewerRefs?: any[]; dependsOn?: string[] }>({
      queryFn: async ({ chainId, title, description, assigneeRef, reviewerRefs, dependsOn }) => {
        try {
          const body: any = { title, description: description || '' };
          if (assigneeRef !== undefined) body.assignee_ref = assigneeRef;
          if (reviewerRefs !== undefined) body.reviewer_refs = reviewerRefs;
          if (dependsOn !== undefined) body.depends_on = dependsOn;
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks`, 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => chainId ? [{ type: 'Chain' as const, id: chainId }, { type: 'ChainTasks' as const, id: chainId }] : [],
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
      queryFn: async ({ taskId, chainId, body }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/comments`, 'POST', { body });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [...preciseTaskTags(taskId, chainId, true), { type: 'Chain' as const, id: chainId }],
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
      queryFn: async ({ taskId, chainId, status }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/status`, 'POST', { status });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [...preciseTaskTags(taskId, chainId), { type: 'Chain' as const, id: chainId }],
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
      queryFn: async ({ taskId, chainId, result, approved, comment = '' }) => {
        try {
          const isApproved = approved ?? (result === 'lgtm');
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/vote`, 'POST', { vote: isApproved ? 'lgtm' : 'ngtm', comment });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [...preciseTaskTags(taskId, chainId), { type: 'Chain' as const, id: chainId }],
    }),
    nudgeTask: build.mutation<any, { taskId: string; chainId: string; body?: string; message?: string; interrupt?: boolean; agentToken?: string }>({
      queryFn: async ({ taskId, chainId, body, message }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/nudge`, 'POST', { message: body ?? message ?? '' });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
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
  useFetchChainTaskCommentsQuery,
  useLazyFetchChainTaskCommentsQuery,
  useListChainsByCoordinatorQuery,
  useCreateTaskChainMutation,
  useUpdateTaskChainMutation,
  useReconcileTaskChainMutation,
  useUpdateTaskDetailMutation,
  useCancelTaskDetailMutation,
  useUpdateTaskPriorityMutation,
  useSetInstanceCurrentTaskMutation,
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
