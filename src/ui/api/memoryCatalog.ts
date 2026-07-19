export function memoryTargetSummary(record: any) {
  if (record.target) return String(record.target);
  const targetAgentId = String(record.target_agent_id || record.targetAgentId || '').trim();
  const targetProjectId = String(record.target_project_id || record.targetProjectId || '').trim();
  const parts = [] as string[];
  if (targetAgentId) parts.push(`agent ${targetAgentId}`);
  if (targetProjectId) parts.push(`project ${targetProjectId}`);
  return parts.length ? parts.join(' · ') : 'global';
}

export function normalizeMemory(record: any) {
  return {
    id: record.memory_id || record.memoryId || '',
    memoryId: record.memory_id || record.memoryId || '',
    proposalId: record.proposal_id || record.proposalId || '',
    targetAgentId: record.target_agent_id || record.targetAgentId || '',
    targetProjectId: record.target_project_id || record.targetProjectId || '',
    target: memoryTargetSummary(record),
    type: record.type || record.memory_type || 'fact',
    title: record.title || '',
    body: record.body || '',
    status: record.status || 'pending',
    reason: record.reason || '',
    evidence: record.evidence || '',
    metadataJson: record.metadata_json || record.metadataJson || '',
    sourceTaskId: record.source_task_id || record.sourceTaskId || '',
    version: Number(record.version || 0),
    createdUnixMs: Number(record.created_unix_ms || record.createdUnixMs || 0),
    updatedUnixMs: Number(record.updated_unix_ms || record.updatedUnixMs || 0),
  };
}

export function normalizeHistory(event: any) {
  return {
    eventId: event.event_id || event.eventId || '',
    memoryId: event.memory_id || event.memoryId || '',
    proposalId: event.proposal_id || event.proposalId || '',
    targetAgentId: event.target_agent_id || event.targetAgentId || '',
    targetProjectId: event.target_project_id || event.targetProjectId || '',
    target: memoryTargetSummary(event),
    type: event.type || event.memory_type || 'fact',
    title: event.title || '',
    body: event.body || '',
    status: event.status || '',
    reason: event.reason || '',
    evidence: event.evidence || '',
    author: event.author || '',
    sourceTaskId: event.source_task_id || event.sourceTaskId || '',
    createdUnixMs: Number(event.created_unix_ms || event.createdUnixMs || 0),
  };
}

export function sortMemoryRecords(records: any[]) {
  return [...(records || [])].sort((left, right) => (right.updatedUnixMs || right.createdUnixMs || 0) - (left.updatedUnixMs || left.createdUnixMs || 0));
}

function includesText(value: any, needle: string) {
  return String(value || '').toLowerCase().includes(needle);
}

function hasTargeting(record: any) {
  return Boolean(record.targetAgentId || record.targetProjectId);
}

export function matchesMemoryFilters(record: any, filters: any) {
  const targetAgentIdFilter = String(filters?.targetAgentId || '').trim().toLowerCase();
  if (targetAgentIdFilter && String(record.targetAgentId || '').trim().toLowerCase() !== targetAgentIdFilter) return false;

  const targetProjectIdFilter = String(filters?.targetProjectId || '').trim().toLowerCase();
  if (targetProjectIdFilter && String(record.targetProjectId || '').trim().toLowerCase() !== targetProjectIdFilter) return false;

  const typeFilter = String(filters?.type || '').trim().toLowerCase();
  if (typeFilter && String(record.type || '').trim().toLowerCase() !== typeFilter) return false;

  const statusFilter = String(filters?.status || '').trim().toLowerCase();
  if (statusFilter && String(record.status || '').trim().toLowerCase() !== statusFilter) return false;

  if (filters?.pendingActiveOnly && !['pending', 'active'].includes(String(record.status || '').trim().toLowerCase())) return false;

  if (filters?.targeting === 'targeted' && !hasTargeting(record)) return false;
  if (filters?.targeting === 'untargeted' && hasTargeting(record)) return false;

  const search = String(filters?.search || '').trim().toLowerCase();
  if (!search) return true;
  return [
    record.memoryId,
    record.proposalId,
    record.title,
    record.body,
    record.target,
    record.targetAgentId,
    record.targetProjectId,
    record.type,
    record.status,
    record.reason,
    record.evidence,
    record.metadataJson,
    record.sourceTaskId,
  ].some((value) => includesText(value, search));
}
