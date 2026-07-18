import * as daemonApi from '../daemonApi';
import { ChatApproval, normalizeApproval, normalizeFederationPeerBlock, normalizeMergeDecision, sortApprovals } from '../attentionCatalog';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

function approvalTagId(approval: any, fallback = '') {
  return String(approval?.approvalId || approval?.approval_id || approval?.id || fallback || '');
}

function mergeDecisionTagId(decision: any, fallback = '') {
  return String(decision?.chainId || decision?.chain_id || fallback || '');
}

function openNonExpiredApprovals(records: any[]) {
  const now = Date.now();
  return sortApprovals((records || [])
    .map(normalizeApproval)
    .filter((approval: ChatApproval) => approval.state === 'open' && (!approval.expiresAtUnixMs || approval.expiresAtUnixMs > now)));
}

export const attentionApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listChatApprovals: build.query<any, void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken) return { approvals: [] };
        const data = await daemonApi.listPendingChatApprovals(auth(session));
        return { approvals: openNonExpiredApprovals(data.approvals || []) };
      }),
      providesTags: (result) => [
        { type: 'ChatApprovals' as const, id: 'ALL' },
        { type: 'Attention' as const, id: 'ALL' },
        ...((result?.approvals || []).map((approval: any) => ({ type: 'ChatApprovals' as const, id: approvalTagId(approval) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchAttention: build.query<any, void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken) return { mergeDecisions: [], federationPeerBlocks: [], raw: null };
        const data = await daemonApi.fetchAttention(auth(session));
        return {
          mergeDecisions: (data.merge_decisions || []).map(normalizeMergeDecision),
          federationPeerBlocks: (data.blocked || []).filter((row: any) => (row?.kind || '') === 'federation_peer_block').map(normalizeFederationPeerBlock),
          raw: data,
        };
      }),
      providesTags: (result) => [
        { type: 'Attention' as const, id: 'ALL' },
        { type: 'MergeDecisions' as const, id: 'ALL' },
        ...((result?.mergeDecisions || []).map((decision: any) => ({ type: 'MergeDecisions' as const, id: mergeDecisionTagId(decision) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    answerChatApproval: build.mutation<any, { approvalId: string; reply: string }>({
      queryFn: withSessionQuery(async (payload, { session }) => {
        if (!session?.clientToken) throw new Error('Not authenticated');
        return daemonApi.answerChatApproval({ ...auth(session), approvalId: payload.approvalId, reply: payload.reply });
      }),
      invalidatesTags: (_result, _error, payload) => [
        { type: 'ChatApprovals' as const, id: 'ALL' },
        { type: 'ChatApprovals' as const, id: payload.approvalId },
        { type: 'Attention' as const, id: 'ALL' },
      ],
    }),
    dismissChatApproval: build.mutation<any, { approvalId: string; reason?: string; notify?: boolean }>({
      queryFn: withSessionQuery(async (payload, { session }) => {
        if (!session?.clientToken) throw new Error('Not authenticated');
        return daemonApi.dismissChatApproval({ ...auth(session), approvalId: payload.approvalId, reason: payload.reason, notify: payload.notify });
      }),
      invalidatesTags: (_result, _error, payload) => [
        { type: 'ChatApprovals' as const, id: 'ALL' },
        { type: 'ChatApprovals' as const, id: payload.approvalId },
        { type: 'Attention' as const, id: 'ALL' },
      ],
    }),
    executeMergeViaChain: build.mutation<any, { chainId: string; instructions: string; target?: string }>({
      queryFn: withSessionQuery(async (payload, { session }) => {
        if (!session?.clientToken) throw new Error('Not authenticated');
        return daemonApi.executeWorkspaceMerge({
          ...auth(session),
          chainId: payload.chainId,
          target: payload.target,
          mode: 'chain',
          instructions: payload.instructions,
        });
      }),
      invalidatesTags: (_result, _error, payload) => [
        { type: 'MergeDecisions' as const, id: 'ALL' },
        { type: 'MergeDecisions' as const, id: payload.chainId },
        { type: 'Attention' as const, id: 'ALL' },
        { type: 'Workspace' as const, id: payload.chainId },
      ],
    }),
  }),
});

export function patchChatApprovalCachesFromWs(dispatch: any, payload: any) {
  const raw = payload?.approval || null;
  const approvalId = String(raw?.approval_id || raw?.approvalId || payload?.approval_id || payload?.approvalId || '');
  if (raw && approvalId) {
    const approval = normalizeApproval(raw);
    dispatch(attentionApi.util.updateQueryData('listChatApprovals', undefined, (draft: any) => {
      const rows = draft?.approvals || (draft.approvals = []);
      const existingIndex = rows.findIndex((item: any) => item.approvalId === approvalId);
      const isOpen = approval.state === 'open' && (!approval.expiresAtUnixMs || approval.expiresAtUnixMs > Date.now());
      if (isOpen && String(payload?.event || '') === 'chat_approval_created') {
        if (existingIndex >= 0) rows[existingIndex] = approval;
        else rows.push(approval);
        draft.approvals = sortApprovals(rows);
      } else if (existingIndex >= 0) {
        rows.splice(existingIndex, 1);
      }
    }));
  }
  dispatch(heimdallApi.util.invalidateTags([
    { type: 'ChatApprovals', id: 'ALL' },
    { type: 'Attention', id: 'ALL' },
    ...(approvalId ? [{ type: 'ChatApprovals' as const, id: approvalId }] : []),
  ]));
}

export function patchMergeDecisionCachesFromWs(dispatch: any, payload: any) {
  const chainId = String(payload?.chain_id || payload?.chainId || '');
  if (chainId) {
    const decision = normalizeMergeDecision(payload);
    dispatch(attentionApi.util.updateQueryData('fetchAttention', undefined, (draft: any) => {
      if (!draft) return;
      const rows = draft.mergeDecisions || (draft.mergeDecisions = []);
      const index = rows.findIndex((item: any) => item.chainId === chainId);
      if (index >= 0) rows[index] = { ...rows[index], ...decision };
      else rows.unshift(decision);
    }));
  }
  dispatch(heimdallApi.util.invalidateTags([
    { type: 'MergeDecisions', id: 'ALL' },
    { type: 'Attention', id: 'ALL' },
    ...(chainId ? [{ type: 'MergeDecisions' as const, id: chainId }, { type: 'Workspace' as const, id: chainId }] : []),
  ]));
}

export const {
  useListChatApprovalsQuery,
  useFetchAttentionQuery,
  useAnswerChatApprovalMutation,
  useDismissChatApprovalMutation,
  useExecuteMergeViaChainMutation,
} = attentionApi;
