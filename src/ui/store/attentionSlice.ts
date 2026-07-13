import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';

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

function normalizeApproval(record: any): ChatApproval {
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

function normalizeMergeDecision(record: any): MergeDecision {
  const preview = record.preview || {};
  return {
    chainId: record.chain_id || '',
    workspaceId: record.workspace_id || '',
    projectId: record.project_id || '',
    vcsKind: record.vcs_kind || '',
    branchOrChange: record.branch_or_change || '',
    baseRef: record.base_ref || '',
    path: record.path || '',
    preview: {
      canFastForward: Boolean(preview.can_fast_forward),
      summary: preview.summary || '',
      conflicts: preview.conflicts || [],
      commands: preview.commands || [],
    },
  };
}

function auth(state: any) {
  const { session } = state.chat;
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

export const refreshChatApprovals = createAsyncThunk('attention/refreshChatApprovals', async (_, { getState }) => {
  const state = getState() as any;
  if (!state.chat.session.clientToken) return { approvals: [] };
  const data = await daemonApi.listPendingChatApprovals(auth(state));
  return { approvals: (data.approvals || []).map(normalizeApproval) };
});

export const answerChatApproval = createAsyncThunk('attention/answerChatApproval', async (payload: { approvalId: string; reply: string }, { dispatch, getState }) => {
  const state = getState() as any;
  const result = await daemonApi.answerChatApproval({ ...auth(state), approvalId: payload.approvalId, reply: payload.reply });
  await (dispatch as any)(refreshChatApprovals());
  return result;
});

export const dismissChatApproval = createAsyncThunk('attention/dismissChatApproval', async (payload: { approvalId: string; reason?: string; notify?: boolean }, { dispatch, getState }) => {
  const state = getState() as any;
  const result = await daemonApi.dismissChatApproval({ ...auth(state), approvalId: payload.approvalId, reason: payload.reason, notify: payload.notify });
  await (dispatch as any)(refreshChatApprovals());
  return result;
});

export const refreshMergeDecisions = createAsyncThunk('attention/refreshMergeDecisions', async (_, { getState }) => {
  const state = getState() as any;
  if (!state.chat.session.clientToken) return { mergeDecisions: [] };
  const data = await daemonApi.fetchAttention({ daemonUrl: state.chat.session.daemonUrl, clientToken: state.chat.session.clientToken });
  return { mergeDecisions: (data.merge_decisions || []).map(normalizeMergeDecision) };
});

export const executeMergeViaChain = createAsyncThunk(
  'attention/executeMergeViaChain',
  async (payload: { chainId: string; instructions: string; target?: string }, { dispatch, getState }) => {
    const state = getState() as any;
    const { session } = state.chat;
    const result = await daemonApi.executeWorkspaceMerge({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
      chainId: payload.chainId,
      target: payload.target,
      mode: 'chain',
      instructions: payload.instructions,
    });
    await dispatch(refreshMergeDecisions());
    return result;
  }
);

const initialState = {
  chatApprovalsById: {} as Record<string, ChatApproval>,
  chatApprovalIds: [] as string[],
  mergeDecisionsById: {} as Record<string, MergeDecision>,
  mergeDecisionIds: [] as string[],
  loading: false,
  error: '',
  lastEventAt: 0,
};

const attentionSlice = createSlice({
  name: 'attention',
  initialState,
  reducers: {
    chatApprovalEventReceived(state: any, action) {
      const event = action.payload || {};
      const raw = event.approval;
      if (!raw) return;
      const approval = normalizeApproval(raw);
      if (!approval.approvalId) return;
      state.lastEventAt = Date.now();
      if (event.event === 'chat_approval_created') {
        state.chatApprovalsById[approval.approvalId] = approval;
        if (!state.chatApprovalIds.includes(approval.approvalId)) {
          state.chatApprovalIds = [approval.approvalId, ...state.chatApprovalIds];
        }
        return;
      }
      // Any terminal event drops the card from the active list.
      delete state.chatApprovalsById[approval.approvalId];
      state.chatApprovalIds = state.chatApprovalIds.filter((id: string) => id !== approval.approvalId);
    },
    tickChatApprovalExpiry(state: any) {
      const now = Date.now();
      const kept: string[] = [];
      for (const id of state.chatApprovalIds) {
        const approval = state.chatApprovalsById[id];
        if (approval && approval.expiresAtUnixMs > now && approval.state === 'open') {
          kept.push(id);
        } else {
          delete state.chatApprovalsById[id];
        }
      }
      if (kept.length !== state.chatApprovalIds.length) {
        state.chatApprovalIds = kept;
      }
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(refreshChatApprovals.pending, (state: any) => {
        state.loading = true;
        state.error = '';
      })
      .addCase(refreshChatApprovals.fulfilled, (state: any, action) => {
        state.loading = false;
        const approvals: ChatApproval[] = action.payload.approvals || [];
        const byId: Record<string, ChatApproval> = {};
        const ids: string[] = [];
        for (const approval of approvals) {
          if (approval.state !== 'open') continue;
          byId[approval.approvalId] = approval;
          ids.push(approval.approvalId);
        }
        ids.sort((a, b) => (byId[a].expiresAtUnixMs || 0) - (byId[b].expiresAtUnixMs || 0));
        state.chatApprovalsById = byId;
        state.chatApprovalIds = ids;
      })
      .addCase(refreshChatApprovals.rejected, (state: any, action) => {
        state.loading = false;
        state.error = action.error.message || 'Failed to load chat approvals';
      })
      .addCase(answerChatApproval.rejected, (state: any, action) => {
        state.error = action.error.message || 'Failed to answer approval';
      })
      .addCase(dismissChatApproval.rejected, (state: any, action) => {
        state.error = action.error.message || 'Failed to dismiss approval';
      })
      .addCase(refreshMergeDecisions.pending, (state: any) => {
        state.loading = true;
        state.error = '';
      })
      .addCase(refreshMergeDecisions.fulfilled, (state: any, action) => {
        state.loading = false;
        const decisions: MergeDecision[] = action.payload.mergeDecisions || [];
        const byId: Record<string, MergeDecision> = {};
        const ids: string[] = [];
        for (const decision of decisions) {
          byId[decision.chainId] = decision;
          ids.push(decision.chainId);
        }
        state.mergeDecisionsById = byId;
        state.mergeDecisionIds = ids;
      })
      .addCase(refreshMergeDecisions.rejected, (state: any, action) => {
        state.loading = false;
        state.error = action.error.message || 'Failed to load merge decisions';
      })
      .addCase(executeMergeViaChain.rejected, (state: any, action) => {
        state.error = action.error.message || 'Failed to execute merge via chain';
      });
  },
});

export const { chatApprovalEventReceived, tickChatApprovalExpiry } = attentionSlice.actions;
export default attentionSlice.reducer;
