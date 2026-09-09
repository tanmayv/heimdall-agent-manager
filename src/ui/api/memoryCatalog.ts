// memoryScopeList reads a targeting dimension as a string[] from either the wire
// arrays (agent_ids/...) or already-camelCased arrays (agentIds/...). Empty or
// missing => [] (applies to all).
export function memoryScopeList(record: any, snake: string, camel: string): string[] {
  const raw = record?.[snake] ?? record?.[camel];
  if (Array.isArray(raw)) return raw.map((v: any) => String(v || '').trim()).filter(Boolean);
  // Tolerate a stray scalar/CSV during transition, but the canonical shape is an array.
  const single = String(raw || '').trim();
  return single ? single.split(',').map((v) => v.trim()).filter(Boolean) : [];
}

function summarizeDimension(label: string, ids: string[]): string {
  if (ids.length === 0) return '';
  if (ids.length === 1) return `${label} ${ids[0]}`;
  return `${label} ${ids[0]} +${ids.length - 1}`;
}

export function memoryTargetSummary(record: any) {
  if (record.target) return String(record.target);
  const agentIds = memoryScopeList(record, 'agent_ids', 'agentIds');
  const projectIds = memoryScopeList(record, 'project_ids', 'projectIds');
  const templateIds = memoryScopeList(record, 'template_ids', 'templateIds');
  const bridgeIds = memoryScopeList(record, 'bridge_ids', 'bridgeIds');
  const parts = [
    summarizeDimension('agent', agentIds),
    summarizeDimension('project', projectIds),
    summarizeDimension('template', templateIds),
    summarizeDimension('bridge', bridgeIds),
  ].filter(Boolean);
  return parts.length ? parts.join(' · ') : 'global';
}

export function normalizeMemory(record: any) {
  const agentIds = memoryScopeList(record, 'agent_ids', 'agentIds');
  const projectIds = memoryScopeList(record, 'project_ids', 'projectIds');
  const templateIds = memoryScopeList(record, 'template_ids', 'templateIds');
  const bridgeIds = memoryScopeList(record, 'bridge_ids', 'bridgeIds');
  return {
    id: record.memory_id || record.memoryId || '',
    memoryId: record.memory_id || record.memoryId || '',
    proposalId: record.proposal_id || record.proposalId || '',
    agentIds,
    projectIds,
    templateIds,
    bridgeIds,
    // Convenience first-element accessors: the memory UI is single-value today
    // (multi-select redesign pending). Components read these until then.
    targetAgentId: agentIds[0] || '',
    targetProjectId: projectIds[0] || '',
    targetTemplateId: templateIds[0] || '',
    targetBridgeId: bridgeIds[0] || '',
    target: memoryTargetSummary(record),
    type: record.type || record.memory_type || 'fact',
    title: record.title || '',
    description: record.description || '',
    body: record.body || record.body_preview || record.bodyPreview || '',
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
  const agentIds = memoryScopeList(event, 'agent_ids', 'agentIds');
  const projectIds = memoryScopeList(event, 'project_ids', 'projectIds');
  const templateIds = memoryScopeList(event, 'template_ids', 'templateIds');
  const bridgeIds = memoryScopeList(event, 'bridge_ids', 'bridgeIds');
  return {
    eventId: event.event_id || event.eventId || '',
    memoryId: event.memory_id || event.memoryId || '',
    proposalId: event.proposal_id || event.proposalId || '',
    agentIds,
    projectIds,
    templateIds,
    bridgeIds,
    targetAgentId: agentIds[0] || '',
    targetProjectId: projectIds[0] || '',
    targetTemplateId: templateIds[0] || '',
    targetBridgeId: bridgeIds[0] || '',
    target: memoryTargetSummary(event),
    type: event.type || event.memory_type || 'fact',
    title: event.title || '',
    description: event.description || '',
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
  return Boolean(record.targetAgentId || record.targetProjectId || record.targetTemplateId || record.targetBridgeId);
}

export function matchesMemoryFilters(record: any, filters: any) {
  const targetAgentIdFilter = String(filters?.targetAgentId || '').trim().toLowerCase();
  if (targetAgentIdFilter && String(record.targetAgentId || '').trim().toLowerCase() !== targetAgentIdFilter) return false;

  const targetProjectIdFilter = String(filters?.targetProjectId || '').trim().toLowerCase();
  if (targetProjectIdFilter && String(record.targetProjectId || '').trim().toLowerCase() !== targetProjectIdFilter) return false;

  const targetTemplateIdFilter = String(filters?.targetTemplateId || '').trim().toLowerCase();
  if (targetTemplateIdFilter && String(record.targetTemplateId || '').trim().toLowerCase() !== targetTemplateIdFilter) return false;

  const targetBridgeIdFilter = String(filters?.targetBridgeId || '').trim().toLowerCase();
  if (targetBridgeIdFilter && String(record.targetBridgeId || '').trim().toLowerCase() !== targetBridgeIdFilter) return false;

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
    record.targetTemplateId,
    record.targetBridgeId,
    record.type,
    record.status,
    record.reason,
    record.evidence,
    record.metadataJson,
    record.sourceTaskId,
  ].some((value) => includesText(value, search));
}
