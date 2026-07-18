export type MultiQuestionPrompt = {
  prompt: string;
  options: string[];
  freeForm: boolean;
};

export type ChatApproval = {
  approvalId: string;
  messageId: string;
  chainId: string;
  userId: string;
  agentInstanceId: string;
  kind: string;
  title: string;
  body: string;
  optionsJson: string;
  suggestedReplies: string[];
  multiQuestions: MultiQuestionPrompt[];
  freeForm: boolean;
  expiresAtUnixMs: number;
  state: string;
  createdUnixMs: number;
  raw: any;
};

export type MergeDecision = {
  chainId: string;
  workspaceId: string;
  projectId: string;
  vcsKind: string;
  branchOrChange: string;
  baseRef: string;
  path: string;
  preview: {
    canFastForward: boolean;
    summary: string;
    conflicts: string[];
    commands: string[];
  };
};

export type FederationPeerBlock = {
  key: string;
  kind: string;
  taskId: string;
  chainId: string;
  taskTitle: string;
  chainTitle: string;
  peerId: string;
  peerDaemonId: string;
  peerStatus: string;
  proxyAgentInstanceId: string;
  reviewerRole: string;
};

function optionText(item: any): string {
  if (typeof item === 'string') return item;
  if (item && typeof item === 'object') return String(item.label || item.value || item.text || item.title || JSON.stringify(item));
  return String(item ?? '');
}

function parseSuggestedReplies(optionsJson: string): string[] {
  if (!optionsJson) return [];
  try {
    const parsed = JSON.parse(optionsJson);
    if (!Array.isArray(parsed)) return [];
    return parsed.map(optionText).filter(Boolean);
  } catch (_err) {
    return [];
  }
}

function parseMultiQuestions(optionsJson: string): MultiQuestionPrompt[] {
  if (!optionsJson) return [];
  try {
    const parsed = JSON.parse(optionsJson);
    if (!Array.isArray(parsed)) return [];
    return parsed.map((item: any) => {
      if (typeof item === 'string') return { prompt: item, options: [], freeForm: true };
      const rawOptions = Array.isArray(item?.options) ? item.options : (Array.isArray(item?.suggested_replies) ? item.suggested_replies : []);
      return {
        prompt: String(item?.question || item?.prompt || item?.text || item?.body || item?.title || '').trim(),
        options: rawOptions.map(optionText).filter(Boolean),
        freeForm: Boolean(item?.free_form ?? item?.freeForm ?? rawOptions.length === 0),
      };
    }).filter((question) => question.prompt);
  } catch (_err) {
    return [];
  }
}

export function normalizeApproval(record: any): ChatApproval {
  const optionsJson: string = record.options_json || record.optionsJson || '';
  const kind = record.kind || '';
  return {
    approvalId: record.approval_id || record.approvalId || '',
    messageId: record.message_id || record.messageId || '',
    chainId: record.chain_id || record.chainId || '',
    userId: record.user_id || record.userId || '',
    agentInstanceId: record.agent_instance_id || record.agentInstanceId || '',
    kind,
    title: record.title || '',
    body: record.body || '',
    optionsJson,
    suggestedReplies: kind === 'multi_question' ? [] : parseSuggestedReplies(optionsJson),
    multiQuestions: kind === 'multi_question' ? parseMultiQuestions(optionsJson) : [],
    freeForm: Boolean(record.free_form ?? record.freeForm),
    expiresAtUnixMs: Number(record.expires_at_unix_ms ?? record.expiresAtUnixMs ?? 0),
    state: record.state || 'open',
    createdUnixMs: Number(record.created_unix_ms ?? record.createdUnixMs ?? 0),
    raw: record,
  };
}

export function normalizeMergeDecision(record: any): MergeDecision {
  const preview = record.preview || {};
  return {
    chainId: record.chain_id || record.chainId || '',
    workspaceId: record.workspace_id || record.workspaceId || '',
    projectId: record.project_id || record.projectId || '',
    vcsKind: record.vcs_kind || record.vcsKind || '',
    branchOrChange: record.branch_or_change || record.branchOrChange || '',
    baseRef: record.base_ref || record.baseRef || '',
    path: record.path || '',
    preview: {
      canFastForward: Boolean(preview.can_fast_forward ?? preview.canFastForward),
      summary: preview.summary || '',
      conflicts: preview.conflicts || [],
      commands: preview.commands || [],
    },
  };
}

export function normalizeFederationPeerBlock(record: any): FederationPeerBlock {
  return {
    key: `${record.task_id || record.taskId || ''}:${record.proxy_agent_instance_id || record.proxyAgentInstanceId || ''}:${record.peer_id || record.peerId || ''}`,
    kind: String(record.kind || 'federation_peer_block'),
    taskId: String(record.task_id || record.taskId || ''),
    chainId: String(record.chain_id || record.chainId || ''),
    taskTitle: String(record.task_title || record.taskTitle || ''),
    chainTitle: String(record.chain_title || record.chainTitle || ''),
    peerId: String(record.peer_id || record.peerId || ''),
    peerDaemonId: String(record.peer_daemon_id || record.peerDaemonId || ''),
    peerStatus: String(record.peer_status || record.peerStatus || ''),
    proxyAgentInstanceId: String(record.proxy_agent_instance_id || record.proxyAgentInstanceId || ''),
    reviewerRole: String(record.reviewer_role || record.reviewerRole || ''),
  };
}

export function sortApprovals(approvals: ChatApproval[]) {
  return [...(approvals || [])].sort((a, b) => (a.expiresAtUnixMs || 0) - (b.expiresAtUnixMs || 0));
}
