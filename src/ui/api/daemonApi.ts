const DEFAULT_TIMEOUT_MS = 5000;

type RequestOptions = {
  method?: string;
  body?: unknown;
  headers?: Record<string, string>;
  timeoutMs?: number;
};

type SessionRequest = {
  daemonUrl: string;
  userId: string;
  clientInstanceId: string;
  clientToken: string;
};

type AgentRequest = {
  daemonUrl: string;
  clientInstanceId: string;
  clientToken: string;
  agentInstanceId: string;
};

type UserRpcRequest = {
  daemonUrl: string;
  clientInstanceId: string;
  clientToken: string;
};

export type ProjectAnchor = {
  type: string;
  value: string;
  note: string;
};

export type Project = {
  projectId: string;
  name: string;
  description: string;
  anchors: ProjectAnchor[];
  createdUnixMs: number;
  updatedUnixMs: number;
  order: number;
};

type TaskAgentRequest = {
  daemonUrl: string;
  agentToken: string;
};

async function requestJson(url: string, { method = 'GET', body, headers, timeoutMs = DEFAULT_TIMEOUT_MS }: RequestOptions = {}): Promise<any> {

  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method,
      headers: { 
        'Content-Type': 'application/json',
        ...headers
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      throw new Error(data?.message || `Daemon request failed with ${response.status}`);
    }
    return data;
  } finally {
    window.clearTimeout(timeout);
  }
}


function joinUrl(baseUrl: string, path: string) {
  return `${baseUrl.replace(/\/$/, '')}${path}`;
}

export async function registerUserClient({ daemonUrl, userId, clientInstanceId, clientToken }: SessionRequest) {
  return requestJson(joinUrl(daemonUrl, '/user-client/register'), {
    method: 'POST',
    body: {
      user_id: userId,
      client_instance_id: clientInstanceId,
      client_token: clientToken || '',
    },
  });
}

export async function listAgentTemplates({ daemonUrl }: { daemonUrl: string }) {
  const data = await requestJson(joinUrl(daemonUrl, '/agents/templates'));
  return data.templates ?? [];
}

export async function saveAgentTemplate({ daemonUrl, template }: { daemonUrl: string; template: any }) {
  return requestJson(joinUrl(daemonUrl, template?.update ? '/agents/templates/update' : '/agents/templates/create'), {
    method: 'POST',
    body: template || {},
  });
}

export async function showAgentTemplate({ daemonUrl, templateId }: { daemonUrl: string; templateId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/templates/show'), {
    method: 'POST',
    body: { template_id: templateId },
  });
}

export async function archiveAgentTemplate({ daemonUrl, templateId }: { daemonUrl: string; templateId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/templates/archive'), {
    method: 'POST',
    body: { template_id: templateId },
  });
}

export async function listKnownAgents({ daemonUrl, projectId = '' }: { daemonUrl: string; projectId?: string }) {
  const path = projectId ? `/agents?project_id=${encodeURIComponent(projectId)}` : '/agents';
  const data = await requestJson(joinUrl(daemonUrl, path));
  return data.agents ?? data.records ?? [];
}

export async function listAgentProviders({ daemonUrl }: { daemonUrl: string }) {
  const data = await requestJson(joinUrl(daemonUrl, '/agents/providers'));
  return data.providers ?? [];
}

export async function startAgent({ daemonUrl, agentInstanceId = '', provider, templateId, projectId, alias, displayName, modelTier }: { daemonUrl: string; agentInstanceId?: string; provider: string; templateId?: string; projectId?: string; alias?: string; displayName?: string; modelTier?: string }) {
  const body: any = {
    agent: provider || '',
    provider_profile: provider || '',
    template_id: templateId || '',
    project_id: projectId || '',
    alias: alias || displayName || '',
    display_name: displayName || alias || '',
    model_tier: modelTier || 'normal',
  };
  if (agentInstanceId) body.agent_instance_id = agentInstanceId;
  return requestJson(joinUrl(daemonUrl, '/agents/start'), {
    method: 'POST',
    body,
    timeoutMs: 10000,
  });
}

export async function showAgent({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/show'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
  });
}

export async function createAgent({ daemonUrl, agentInstanceId, displayName, providerProfile, templateId, projectId, modelTier }: { daemonUrl: string; agentInstanceId?: string; displayName?: string; providerProfile?: string; templateId?: string; projectId?: string; modelTier?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/create'), {
    method: 'POST',
    body: {
      agent_instance_id: agentInstanceId || '',
      display_name: displayName || '',
      provider_profile: providerProfile || '',
      template_id: templateId || '',
      project_id: projectId || '',
      model_tier: modelTier || 'normal',
    },
  });
}

export async function updateAgent({ daemonUrl, agentRecordId, agentInstanceId, displayName, templateId, providerProfile, projectId, runDir, modelTier }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string; displayName?: string; templateId?: string; providerProfile?: string; projectId?: string; runDir?: string; modelTier?: string }) {
  const body: any = { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' };
  if (displayName !== undefined) body.display_name = displayName;
  if (templateId !== undefined) body.template_id = templateId;
  if (providerProfile !== undefined) body.provider_profile = providerProfile;
  if (projectId !== undefined) body.project_id = projectId;
  if (runDir !== undefined) body.run_dir = runDir;
  if (modelTier !== undefined) body.model_tier = modelTier;
  return requestJson(joinUrl(daemonUrl, '/agents/update'), {
    method: 'POST',
    body,
  });
}

export async function archiveAgent({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/archive'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
  });
}

export async function stopAgent({ daemonUrl, agentInstanceId }: { daemonUrl: string; agentInstanceId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/stop'), {
    method: 'POST',
    body: { agent_instance_id: agentInstanceId },
  });
}

export async function associateAgentWithProject({ daemonUrl, agentRecordId, agentInstanceId, projectId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string; projectId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/associate'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '', project_id: projectId },
  });
}

export async function disassociateAgentFromProject({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/disassociate'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
  });
}

export async function fetchChat({ daemonUrl, clientToken, agentInstanceId, limit = 50, cursor = 0 }: Partial<AgentRequest> & { limit?: number; cursor?: number }) {
  let path = `/chats/${encodeURIComponent(agentInstanceId || '')}/messages?limit=${limit}`;
  if (cursor > 0) {
    path += `&cursor=${cursor}`;
  }
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
  });
}


export async function sendToAgent({ daemonUrl, clientInstanceId, clientToken, agentInstanceId, body, interrupt }: AgentRequest & { body: string; interrupt?: boolean }) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'send_to_agent',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      agent_instance_id: agentInstanceId,
      body,
      interrupt,
    },
  });
}

export async function markChatRead({ daemonUrl, clientInstanceId, clientToken, agentInstanceId }: AgentRequest) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'mark_read',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      agent_instance_id: agentInstanceId,
    },
  });
}

export async function listTaskChains({ daemonUrl, clientToken, createdAfter, createdBefore, limit = 100, offset = 0 }: Omit<UserRpcRequest, 'clientInstanceId'> & { createdAfter?: number; createdBefore?: number; limit?: number; offset?: number }) {
  let path = `/task-chains?limit=${limit}&offset=${offset}`;
  if (createdAfter && createdAfter > 0) path += `&created_after=${createdAfter}`;
  if (createdBefore && createdBefore > 0) path += `&created_before=${createdBefore}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTaskChain({ daemonUrl, clientToken, chainId }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string }) {
  const path = `/task-chains/${encodeURIComponent(chainId)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function listChainTasks({ daemonUrl, clientToken, chainId }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string }) {
  const path = `/task-chains/${encodeURIComponent(chainId)}/tasks`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTask({ daemonUrl, clientToken, taskId }: Omit<UserRpcRequest, 'clientInstanceId'> & { taskId: string }) {
  const path = `/tasks/${encodeURIComponent(taskId)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTaskComments({ daemonUrl, clientToken, taskId, unresolved = false }: Omit<UserRpcRequest, 'clientInstanceId'> & { taskId: string; unresolved?: boolean }) {
  const path = `/tasks/${encodeURIComponent(taskId)}/comments?unresolved=${unresolved}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function listTasks({ daemonUrl, clientToken, chainId = '', createdAfter = 0, createdBefore = 0, limit = 50, offset = 0 }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId?: string; createdAfter?: number; createdBefore?: number; limit?: number; offset?: number }) {
  let path = `/tasks?limit=${limit}&offset=${offset}`;
  if (chainId) path += `&chain_id=${encodeURIComponent(chainId)}`;
  if (createdAfter > 0) path += `&created_after=${createdAfter}`;
  if (createdBefore > 0) path += `&created_before=${createdBefore}`;

  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}


export async function fetchTaskLog({ daemonUrl, clientInstanceId, clientToken, taskId }: UserRpcRequest & { taskId: string }) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'task_log',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      task_id: taskId,
    },
  });
}

function taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action, agentPath, body }: any) {
  if (agentToken) {
    return requestJson(joinUrl(daemonUrl, agentPath), { method: 'POST', body: { agent_token: agentToken, ...body } });
  }
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), { method: 'POST', body: { action, client_instance_id: clientInstanceId, client_token: clientToken, ...body } });
}

export async function createTask({ daemonUrl, agentToken, clientInstanceId, clientToken, ...task }: Partial<TaskAgentRequest & UserRpcRequest> & Record<string, any>) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_create', agentPath: '/tasks/create', body: task });
}

export async function createTaskChain({ daemonUrl, agentToken, clientInstanceId, clientToken, ...chain }: Partial<TaskAgentRequest & UserRpcRequest> & Record<string, any>) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_chain_create', agentPath: '/task-chains/create', body: chain });
}

export async function addTaskComment({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, body }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; body: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_comment', agentPath: '/tasks/comment', body: { task_id: taskId, chain_id: chainId || '', body } });
}

export async function updateTaskStatus({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, status, body }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; status: string; body: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_status', agentPath: '/tasks/status', body: { task_id: taskId, chain_id: chainId || '', status, body } });
}

export async function updateTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, title, description }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; title?: string; description?: string }) {
  const body: any = { task_id: taskId, chain_id: chainId || '' };
  if (title !== undefined) body.title = title;
  if (description !== undefined) body.description = description;
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_update', agentPath: '/tasks/update', body });
}

export async function assignTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, agentInstanceId }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; agentInstanceId: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_assign', agentPath: '/tasks/assign', body: { task_id: taskId, chain_id: chainId || '', agent_instance_id: agentInstanceId } });
}

export async function addTaskParticipant({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, agentInstanceId, role }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; agentInstanceId: string; role: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_participant', agentPath: '/tasks/participant', body: { task_id: taskId, chain_id: chainId || '', agent_instance_id: agentInstanceId, role } });
}

export async function removeTaskParticipant({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, agentInstanceId, role }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; agentInstanceId: string; role: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_participant_remove', agentPath: '/tasks/participant/remove', body: { task_id: taskId, chain_id: chainId || '', agent_instance_id: agentInstanceId, role } });
}

export async function voteTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, approved, comment }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; approved: boolean; comment: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_review_vote', agentPath: '/tasks/vote', body: { task_id: taskId, chain_id: chainId || '', result: approved ? 'lgtm' : 'ngtm', comment } });
}

export async function nudgeTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, body, interrupt }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; body: string; interrupt?: boolean }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_nudge', agentPath: '/tasks/nudge', body: { task_id: taskId, chain_id: chainId || '', body, interrupt: Boolean(interrupt) } });
}

export async function resolveTaskComment({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, commentId }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; commentId: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_comment_resolve', agentPath: '/tasks/comment-resolve', body: { task_id: taskId, chain_id: chainId || '', comment_id: commentId } });
}

export async function updateTaskChain({ daemonUrl, agentToken, clientInstanceId, clientToken, chainId, title, description, coordinatorAgentInstanceId, defaultReviewerAgentInstanceId, finalSummary }: Partial<TaskAgentRequest & UserRpcRequest> & { chainId: string; title?: string; description?: string; coordinatorAgentInstanceId?: string; defaultReviewerAgentInstanceId?: string; finalSummary?: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_chain_update', agentPath: '/task-chains/update', body: { chain_id: chainId, title: title || '', description: description || '', coordinator_agent_instance_id: coordinatorAgentInstanceId || '', default_reviewer_agent_instance_id: defaultReviewerAgentInstanceId || '', final_summary: finalSummary || '' } });
}

export async function updateTaskChainStatus({ daemonUrl, agentToken, clientInstanceId, clientToken, chainId, status, finalSummary }: Partial<TaskAgentRequest & UserRpcRequest> & { chainId: string; status: string; finalSummary?: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_chain_status', agentPath: '/task-chains/status', body: { chain_id: chainId, status, final_summary: finalSummary || '' } });
}

function userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action, body = {} }: UserRpcRequest & { action: string; body?: Record<string, any> }) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: { action, client_instance_id: clientInstanceId, client_token: clientToken, ...body },
  });
}

export async function listMemory({ daemonUrl, clientInstanceId, clientToken, subjectAgent, scope, type, status, includeAllStatuses = true }: UserRpcRequest & { subjectAgent?: string; scope?: string; type?: string; status?: string; includeAllStatuses?: boolean }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_list', body: { subject_agent: subjectAgent || '', scope: scope || '', type: type || '', status: status || '', include_all_statuses: includeAllStatuses } });
}

export async function showMemory({ daemonUrl, clientInstanceId, clientToken, memoryId }: UserRpcRequest & { memoryId: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_show', body: { memory_id: memoryId } });
}

export async function memoryHistory({ daemonUrl, clientInstanceId, clientToken, memoryId }: UserRpcRequest & { memoryId: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_history', body: { memory_id: memoryId } });
}

export async function proposeMemory({ daemonUrl, clientInstanceId, clientToken, proposalAction, ...body }: UserRpcRequest & { proposalAction: 'new' | 'edit' | 'archive' | 'rollback' } & Record<string, any>) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: `memory_propose_${proposalAction}`, body });
}

export async function decideMemory({ daemonUrl, clientInstanceId, clientToken, proposalId, decision, reason }: UserRpcRequest & { proposalId: string; decision: 'approve' | 'reject'; reason?: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_decide', body: { proposal_id: proposalId, decision, reason: reason || '' } });
}

export async function testLaunch({ daemonUrl, provider, tier }: { daemonUrl: string; provider: string; tier: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/test-launch'), { method: 'POST', body: { provider, tier } });
}

export async function getTestStatus({ daemonUrl, testRunId }: { daemonUrl: string; testRunId: string }) {
  return requestJson(joinUrl(daemonUrl, `/agents/test-status?test_run_id=${encodeURIComponent(testRunId)}`));
}

export async function getTestHistory({ daemonUrl }: { daemonUrl: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/test-history'));
}

export function normalizeProject(project: any): Project {
  return {
    projectId: project.project_id || '',
    name: project.name || '',
    description: project.description || '',
    anchors: (project.anchors ?? []).map((anchor: any) => ({
      type: anchor.type || '',
      value: anchor.value || '',
      note: anchor.note || '',
    })),
    createdUnixMs: Number(project.created_unix_ms || 0),
    updatedUnixMs: Number(project.updated_unix_ms || 0),
    order: Number(project.order || 0),
  };
}

export async function listProjects({ daemonUrl, clientInstanceId, clientToken }: UserRpcRequest) {
  const data = await userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_list' });
  return { ...data, projects: (data.projects ?? []).map(normalizeProject) };
}

export async function showProject({ daemonUrl, clientInstanceId, clientToken, projectId }: UserRpcRequest & { projectId: string }) {
  const data = await userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_show', body: { project_id: projectId } });
  return { ...data, project: data.project ? normalizeProject(data.project) : null };
}

export async function createProject({ daemonUrl, clientInstanceId, clientToken, name, description, anchors }: UserRpcRequest & { name: string; description?: string; anchors?: ProjectAnchor[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_create', body: { name, description: description || '', anchors: anchors || [] } });
}

export async function updateProject({ daemonUrl, clientInstanceId, clientToken, projectId, name, description, anchors }: UserRpcRequest & { projectId: string; name?: string; description?: string; anchors?: ProjectAnchor[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_update', body: { project_id: projectId, name: name || '', description: description || '', anchors: anchors || [] } });
}

export async function reorderProjects({ daemonUrl, clientInstanceId, clientToken, projectIds }: UserRpcRequest & { projectIds: string[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_reorder', body: { project_ids: projectIds } });
}

export async function reorderAgents({ daemonUrl, clientInstanceId, clientToken, agentIds }: UserRpcRequest & { agentIds: string[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'agent_reorder', body: { agent_ids: agentIds } });
}

export async function fetchPreferences({ daemonUrl, clientToken }: { daemonUrl: string; clientToken: string }) {
  return requestJson(joinUrl(daemonUrl, '/preferences'), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
  });
}

export async function savePreference({ daemonUrl, clientToken, key, value, interrupt }: { daemonUrl: string; clientToken: string; key: string; value: string; interrupt: boolean }) {
  return requestJson(joinUrl(daemonUrl, '/preferences'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` },
    body: { key, value, interrupt }
  });
}

export async function resetPreference({ daemonUrl, clientToken, key }: { daemonUrl: string; clientToken: string; key: string }) {
  return requestJson(joinUrl(daemonUrl, `/preferences/${encodeURIComponent(key)}`), {
    method: 'DELETE',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
  });
}

export async function listUnreviewedTaskChains({ daemonUrl, clientToken, limit = 100, offset = 0 }: Omit<UserRpcRequest, 'clientInstanceId'> & { limit?: number; offset?: number }) {
  const path = `/task-chains?status=completed&evaluation=unreviewed&limit=${limit}&offset=${offset}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function evaluateTaskChain({ daemonUrl, agentToken, clientInstanceId, clientToken, chainId, evaluation }: Partial<TaskAgentRequest & UserRpcRequest> & { chainId: string; evaluation: string }) {
  return taskMutationRequest({
    daemonUrl,
    agentToken,
    clientInstanceId,
    clientToken,
    action: 'task_chain_evaluate',
    agentPath: '/task-chains/evaluate',
    body: {
      chain_id: chainId,
      evaluation,
    }
  });
}

export async function triggerMemoryAudit({
  daemonUrl,
  clientToken,
  timeRange,
  targetChains,
  auditorInstructions,
}: {
  daemonUrl: string;
  clientToken: string;
  timeRange?: string;
  targetChains?: string[];
  auditorInstructions?: string;
}) {
  const path = '/task-chains/audit';
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: {
      time_range: timeRange,
      target_chains: targetChains,
      auditor_instructions: auditorInstructions,
    }
  });
}

export async function testAgentConnectivity({ daemonUrl, clientToken, providers }: { daemonUrl: string; clientToken: string; providers?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/test-connectivity'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` },
    body: providers ? { providers } : undefined
  });
}

export async function fetchTaskChains({
  daemonUrl,
  clientToken,
  status,
  evaluation,
  limit = 100,
}: {
  daemonUrl: string;
  clientToken: string;
  status?: string;
  evaluation?: string;
  limit?: number;
}) {
  let path = `/task-chains?limit=${limit}`;
  if (status) path += `&status=${encodeURIComponent(status)}`;
  if (evaluation) path += `&evaluation=${encodeURIComponent(evaluation)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` },
  });
}
