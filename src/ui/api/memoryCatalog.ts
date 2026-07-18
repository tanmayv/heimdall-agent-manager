export function memoryTargetSummary(record: any) {
  if (record.target) return String(record.target);
  const targetTeamKind = String(record.target_team_kind || record.targetTeamKind || '').trim();
  const targetRole = String(record.target_role || record.targetRole || '').trim();
  const targetProjectId = String(record.target_project_id || record.targetProjectId || '').trim();
  const parts = [] as string[];
  if (targetTeamKind) parts.push(`team kind ${targetTeamKind}`);
  if (targetRole) parts.push(`role ${targetRole}`);
  if (targetProjectId) parts.push(`project ${targetProjectId}`);
  return parts.length ? parts.join(' · ') : 'global';
}

export function normalizeMemory(record: any) {
  return {
    id: record.memory_id || record.memoryId || '',
    memoryId: record.memory_id || record.memoryId || '',
    proposalId: record.proposal_id || record.proposalId || '',
    targetTeamKind: record.target_team_kind || record.targetTeamKind || '',
    targetRole: record.target_role || record.targetRole || '',
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
    targetTeamKind: event.target_team_kind || event.targetTeamKind || '',
    targetRole: event.target_role || event.targetRole || '',
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
  return Boolean(record.targetTeamKind || record.targetRole || record.targetProjectId);
}

export function matchesMemoryFilters(record: any, filters: any) {
  const targetTeamKindFilter = String(filters?.targetTeamKind || '').trim().toLowerCase();
  if (targetTeamKindFilter && String(record.targetTeamKind || '').trim().toLowerCase() !== targetTeamKindFilter) return false;

  const targetRoleFilter = String(filters?.targetRole || '').trim().toLowerCase();
  if (targetRoleFilter && String(record.targetRole || '').trim().toLowerCase() !== targetRoleFilter) return false;

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
    record.targetTeamKind,
    record.targetRole,
    record.targetProjectId,
    record.type,
    record.status,
    record.reason,
    record.evidence,
    record.metadataJson,
    record.sourceTaskId,
  ].some((value) => includesText(value, search));
}
