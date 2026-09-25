import { apiErrorText, cookieJsonFetch, cookieJsonFetchEnvelope, cookieMutation } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';
import { encryptVaultText, decryptVaultText, isVaultArmored } from '../../utils/vaultContent';

export type IssueStatus = 'new' | 'fixed' | 'obsolete';
export type IssueScopeType = 'global' | 'project' | 'agent' | 'bridge' | 'agent_id' | 'bridge_id';

export interface Issue {
  id: string;
  issueId: string;
  issue_id: string;
  ownerUserId: string;
  owner_user_id: string;
  title: string;
  description: string;
  descriptionPreview?: string;
  description_preview?: string;
  createdBy: string;
  created_by: string;
  status: IssueStatus;
  scopeType: IssueScopeType;
  scope_type: IssueScopeType;
  targetId: string;
  target_id: string;
  chainId: string;
  chain_id: string;
  createdAt: string;
  created_at: string;
  updatedAt: string;
  updated_at: string;
  closedAt: string;
  closed_at: string;
  voteCount: number;
  vote_count: number;
  commentCount: number;
  comment_count: number;
  hasVoted: boolean;
  has_voted: boolean;
  comments?: IssueComment[];
}

export interface IssueComment {
  id: string;
  commentId: string;
  comment_id: string;
  issueId: string;
  issue_id: string;
  ownerUserId: string;
  owner_user_id: string;
  authorId: string;
  author_id: string;
  authorName: string;
  author_name: string;
  body: string;
  createdAt: string;
  created_at: string;
  updatedAt: string;
  updated_at: string;
}

export interface IssueVote {
  issueId: string;
  issue_id: string;
  voterId: string;
  voter_id: string;
  voterName: string;
  voter_name: string;
  ownerUserId: string;
  owner_user_id: string;
  createdAt: string;
  created_at: string;
}

export type IssueListFilter = {
  status?: string;
  scope?: string;
  scopeType?: string;
  targetId?: string;
  chainId?: string;
  q?: string;
  query?: string;
  voterId?: string;
  limit?: number;
  offset?: number;
};

export type ListIssuesQueryArg = IssueListFilter | void;

export type IssuePage = {
  items: Issue[];
  has_more: boolean;
  limit: number;
};

export function issueListPath(arg: IssueListFilter | void | null): string {
  const params = new URLSearchParams();
  if (arg) {
    if (arg.status) params.set('status', arg.status);
    const scope = arg.scope || arg.scopeType;
    if (scope) params.set('scope', scope);
    if (arg.targetId) params.set('target_id', arg.targetId);
    if (arg.chainId) params.set('chain_id', arg.chainId);
    const q = arg.q || arg.query;
    if (q) params.set('q', q);
    if (arg.voterId) params.set('voter_id', arg.voterId);
    if (arg.limit) params.set('limit', String(arg.limit));
    if (arg.offset) params.set('offset', String(arg.offset));
  }
  const queryString = params.toString();
  return `/issues${queryString ? `?${queryString}` : ''}`;
}

export function normalizeIssue(record: any): Issue {
  const issueId = String(record?.issue_id || record?.issueId || record?.id || '');
  return {
    id: issueId,
    issueId,
    issue_id: issueId,
    ownerUserId: String(record?.owner_user_id || record?.ownerUserId || ''),
    owner_user_id: String(record?.owner_user_id || record?.ownerUserId || ''),
    title: String(record?.title || ''),
    description: String(record?.description || ''),
    descriptionPreview: String(record?.description_preview || record?.descriptionPreview || record?.description || ''),
    description_preview: String(record?.description_preview || record?.descriptionPreview || record?.description || ''),
    createdBy: String(record?.created_by || record?.createdBy || ''),
    created_by: String(record?.created_by || record?.createdBy || ''),
    status: (String(record?.status || 'new').toLowerCase() as IssueStatus) || 'new',
    scopeType: (String(record?.scope_type || record?.scopeType || 'global') as IssueScopeType) || 'global',
    scope_type: (String(record?.scope_type || record?.scopeType || 'global') as IssueScopeType) || 'global',
    targetId: String(record?.target_id || record?.targetId || ''),
    target_id: String(record?.target_id || record?.targetId || ''),
    chainId: String(record?.chain_id || record?.chainId || ''),
    chain_id: String(record?.chain_id || record?.chainId || ''),
    createdAt: String(record?.created_at || record?.createdAt || ''),
    created_at: String(record?.created_at || record?.createdAt || ''),
    updatedAt: String(record?.updated_at || record?.updatedAt || ''),
    updated_at: String(record?.updated_at || record?.updatedAt || ''),
    closedAt: String(record?.closed_at || record?.closedAt || ''),
    closed_at: String(record?.closed_at || record?.closedAt || ''),
    voteCount: Number(record?.vote_count ?? record?.voteCount ?? 0),
    vote_count: Number(record?.vote_count ?? record?.voteCount ?? 0),
    commentCount: Number(record?.comment_count ?? record?.commentCount ?? 0),
    comment_count: Number(record?.comment_count ?? record?.commentCount ?? 0),
    hasVoted: Boolean(record?.has_voted ?? record?.hasVoted),
    has_voted: Boolean(record?.has_voted ?? record?.hasVoted),
    comments: Array.isArray(record?.comments) ? record.comments.map(normalizeIssueComment) : undefined,
  };
}

export function normalizeIssueComment(record: any): IssueComment {
  const commentId = String(record?.comment_id || record?.commentId || record?.id || '');
  const issueId = String(record?.issue_id || record?.issueId || '');
  return {
    id: commentId,
    commentId,
    comment_id: commentId,
    issueId,
    issue_id: issueId,
    ownerUserId: String(record?.owner_user_id || record?.ownerUserId || ''),
    owner_user_id: String(record?.owner_user_id || record?.ownerUserId || ''),
    authorId: String(record?.author_id || record?.authorId || ''),
    author_id: String(record?.author_id || record?.authorId || ''),
    authorName: String(record?.author_name || record?.authorName || ''),
    author_name: String(record?.author_name || record?.authorName || ''),
    body: String(record?.body || ''),
    createdAt: String(record?.created_at || record?.createdAt || ''),
    created_at: String(record?.created_at || record?.createdAt || ''),
    updatedAt: String(record?.updated_at || record?.updatedAt || ''),
    updated_at: String(record?.updated_at || record?.updatedAt || ''),
  };
}

export function normalizeIssueVote(record: any): IssueVote {
  const issueId = String(record?.issue_id || record?.issueId || '');
  const voterId = String(record?.voter_id || record?.voterId || '');
  return {
    issueId,
    issue_id: issueId,
    voterId,
    voter_id: voterId,
    voterName: String(record?.voter_name || record?.voterName || ''),
    voter_name: String(record?.voter_name || record?.voterName || ''),
    ownerUserId: String(record?.owner_user_id || record?.ownerUserId || ''),
    owner_user_id: String(record?.owner_user_id || record?.ownerUserId || ''),
    createdAt: String(record?.created_at || record?.createdAt || ''),
    created_at: String(record?.created_at || record?.createdAt || ''),
  };
}

export async function fetchIssuePage(
  args: IssueListFilter & { signal?: AbortSignal },
): Promise<IssuePage> {
  const { signal, ...arg } = args;
  const body = await cookieJsonFetchEnvelope(issueListPath(arg), { signal });
  const data = body?.data ?? body;
  const page = body?.page ?? {};
  const rawItems = Array.isArray(data) ? data : data?.items || [];
  return {
    items: rawItems.map(normalizeIssue),
    has_more: Boolean(page?.has_more),
    limit: Number(page?.limit || 50),
  };
}

export function issueErrorText(err: unknown, fallback = 'Something went wrong'): string {
  return apiErrorText(err, fallback);
}

export type CreateIssueInput = {
  title: string;
  description?: string;
  createdBy?: string;
  created_by?: string;
  scopeType?: string;
  scope_type?: string;
  targetId?: string;
  target_id?: string;
  chainId?: string;
  chain_id?: string;
};

export type UpdateIssueInput = {
  issueId: string;
  title?: string;
  description?: string;
  status?: string;
  scopeType?: string;
  scope_type?: string;
  targetId?: string;
  target_id?: string;
  chainId?: string;
  chain_id?: string;
};

export type DeleteIssueInput = {
  issueId: string;
};

export type ListIssueCommentsArg = {
  issueId: string;
};

export type CreateIssueCommentInput = {
  issueId: string;
  body: string;
  authorId?: string;
  author_id?: string;
  authorName?: string;
  author_name?: string;
};

export type DeleteIssueCommentInput = {
  issueId: string;
  commentId: string;
};

export type VoteIssueInput = {
  issueId: string;
  voterId?: string;
  voter_id?: string;
  voterName?: string;
  voter_name?: string;
};

export type UnvoteIssueInput = {
  issueId: string;
  voterId?: string;
  voter_id?: string;
};

export const issuesApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listIssues: build.query<{ items: Issue[]; has_more: boolean }, ListIssuesQueryArg>({
      queryFn: async (arg) => {
        try {
          const res = await cookieJsonFetchEnvelope(issueListPath(arg));
          const data = res?.data ?? res;
          const page = res?.page ?? {};
          const rawItems = Array.isArray(data) ? data : data?.items || [];
          const items = rawItems.map(normalizeIssue);
          return { data: { items, has_more: Boolean(page?.has_more) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (result) => [
        { type: 'Issue' as const, id: 'ALL' },
        ...((result?.items || []).map((iss: Issue) => ({ type: 'Issue' as const, id: iss.id }))),
      ],
    }),

    getIssue: build.query<Issue | null, { issueId: string } | string>({
      queryFn: async (arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        if (!issueId) return { data: null };
        try {
          const res = await cookieJsonFetch(`/issues/${encodeURIComponent(issueId)}`);
          const record = res?.issue || res?.record || res;
          return { data: record ? normalizeIssue(record) : null };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => [
        { type: 'Issue' as const, id: typeof arg === 'string' ? arg : arg?.issueId },
      ],
    }),

    createIssue: build.mutation<Issue, CreateIssueInput>({
      queryFn: async (payload, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const rawKeyHex = state?.vault?.rawVaultKeyHex;

          let title = payload.title;
          let description = payload.description || '';

          if (isUnlocked && rawKeyHex) {
            if (!isVaultArmored(title)) {
              title = await encryptVaultText(title, rawKeyHex);
            }
            if (description && !isVaultArmored(description)) {
              description = await encryptVaultText(description, rawKeyHex);
            }
          }

          const body = {
            title,
            description,
            created_by: payload.created_by || payload.createdBy,
            scope_type: payload.scope_type || payload.scopeType || 'global',
            target_id: payload.target_id || payload.targetId || '',
            chain_id: payload.chain_id || payload.chainId || '',
          };
          const data = await cookieMutation('/issues', 'POST', body);
          return { data: normalizeIssue(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Issue' as const, id: 'ALL' }],
    }),

    updateIssue: build.mutation<Issue, UpdateIssueInput>({
      queryFn: async ({ issueId, ...payload }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const rawKeyHex = state?.vault?.rawVaultKeyHex;

          const body: Record<string, any> = {};
          if (payload.title !== undefined) {
            body.title =
              isUnlocked && rawKeyHex && !isVaultArmored(payload.title)
                ? await encryptVaultText(payload.title, rawKeyHex)
                : payload.title;
          }
          if (payload.description !== undefined) {
            body.description =
              isUnlocked && rawKeyHex && payload.description && !isVaultArmored(payload.description)
                ? await encryptVaultText(payload.description, rawKeyHex)
                : payload.description;
          }
          if (payload.status !== undefined) body.status = payload.status;
          const scope = payload.scope_type || payload.scopeType;
          if (scope !== undefined) body.scope_type = scope;
          const target = payload.target_id || payload.targetId;
          if (target !== undefined) body.target_id = target;
          const chain = payload.chain_id || payload.chainId;
          if (chain !== undefined) body.chain_id = chain;

          const data = await cookieMutation(`/issues/${encodeURIComponent(issueId)}`, 'PATCH', body);
          return { data: normalizeIssue(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { issueId }) => [
        { type: 'Issue' as const, id: 'ALL' },
        { type: 'Issue' as const, id: issueId },
      ],
    }),

    deleteIssue: build.mutation<{ deleted: boolean }, DeleteIssueInput | string>({
      queryFn: async (arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        try {
          const data = await cookieMutation(`/issues/${encodeURIComponent(issueId)}`, 'DELETE');
          return { data: { deleted: Boolean(data?.deleted ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        return [
          { type: 'Issue' as const, id: 'ALL' },
          { type: 'Issue' as const, id: issueId },
        ];
      },
    }),

    listIssueComments: build.query<IssueComment[], ListIssueCommentsArg | string>({
      queryFn: async (arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        if (!issueId) return { data: [] };
        try {
          const res = await cookieJsonFetch(`/issues/${encodeURIComponent(issueId)}/comments`);
          const rawItems = Array.isArray(res) ? res : res?.items || res?.comments || [];
          return { data: rawItems.map(normalizeIssueComment) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        return [
          { type: 'IssueComments' as const, id: issueId },
        ];
      },
    }),

    addIssueComment: build.mutation<IssueComment, CreateIssueCommentInput>({
      queryFn: async ({ issueId, ...payload }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const rawKeyHex = state?.vault?.rawVaultKeyHex;

          let bodyText = payload.body;
          if (isUnlocked && rawKeyHex && bodyText && !isVaultArmored(bodyText)) {
            bodyText = await encryptVaultText(bodyText, rawKeyHex);
          }

          const body = {
            body: bodyText,
            author_id: payload.author_id || payload.authorId,
            author_name: payload.author_name || payload.authorName,
          };
          const data = await cookieMutation(`/issues/${encodeURIComponent(issueId)}/comments`, 'POST', body);
          return { data: normalizeIssueComment(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { issueId }) => [
        { type: 'IssueComments' as const, id: issueId },
        { type: 'Issue' as const, id: issueId },
        { type: 'Issue' as const, id: 'ALL' },
      ],
    }),

    deleteIssueComment: build.mutation<{ deleted: boolean }, DeleteIssueCommentInput>({
      queryFn: async ({ issueId, commentId }) => {
        try {
          const data = await cookieMutation(`/issues/${encodeURIComponent(issueId)}/comments/${encodeURIComponent(commentId)}`, 'DELETE');
          return { data: { deleted: Boolean(data?.deleted ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { issueId }) => [
        { type: 'IssueComments' as const, id: issueId },
        { type: 'Issue' as const, id: issueId },
        { type: 'Issue' as const, id: 'ALL' },
      ],
    }),

    listIssueVotes: build.query<IssueVote[], { issueId: string } | string>({
      queryFn: async (arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        if (!issueId) return { data: [] };
        try {
          const res = await cookieJsonFetch(`/issues/${encodeURIComponent(issueId)}/votes`);
          const rawItems = Array.isArray(res) ? res : res?.items || res?.votes || [];
          return { data: rawItems.map(normalizeIssueVote) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        return [{ type: 'Issue' as const, id: `${issueId}:votes` }];
      },
    }),

    voteIssue: build.mutation<{ voted: boolean }, VoteIssueInput | string>({
      queryFn: async (arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        const payload = typeof arg === 'string' ? {} : {
          voter_id: arg?.voter_id || arg?.voterId,
          voter_name: arg?.voter_name || arg?.voterName,
        };
        try {
          const data = await cookieMutation(`/issues/${encodeURIComponent(issueId)}/vote`, 'POST', payload);
          return { data: { voted: Boolean(data?.voted ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        return [
          { type: 'Issue' as const, id: issueId },
          { type: 'Issue' as const, id: `${issueId}:votes` },
          { type: 'Issue' as const, id: 'ALL' },
        ];
      },
    }),

    unvoteIssue: build.mutation<{ unvoted: boolean }, UnvoteIssueInput | string>({
      queryFn: async (arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        const payload = typeof arg === 'string' ? {} : {
          voter_id: arg?.voter_id || arg?.voterId,
        };
        try {
          const data = await cookieMutation(`/issues/${encodeURIComponent(issueId)}/unvote`, 'POST', payload);
          return { data: { unvoted: Boolean(data?.unvoted ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, arg) => {
        const issueId = typeof arg === 'string' ? arg : arg?.issueId;
        return [
          { type: 'Issue' as const, id: issueId },
          { type: 'Issue' as const, id: `${issueId}:votes` },
          { type: 'Issue' as const, id: 'ALL' },
        ];
      },
    }),
  }),
});

export const {
  useListIssuesQuery,
  useGetIssueQuery,
  useCreateIssueMutation,
  useUpdateIssueMutation,
  useDeleteIssueMutation,
  useListIssueCommentsQuery,
  useAddIssueCommentMutation,
  useDeleteIssueCommentMutation,
  useListIssueVotesQuery,
  useVoteIssueMutation,
  useUnvoteIssueMutation,
} = issuesApi;

/**
 * Encrypt issue fields (title, description) if vault is unlocked using rawKeyHex.
 */
export async function encryptIssueFields<T extends { title?: string; description?: string }>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, rawKeyHex);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, rawKeyHex);
  }
  return res;
}

/**
 * Encrypt comment body if vault is unlocked using rawKeyHex.
 */
export async function encryptCommentFields<T extends { body: string }>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex || !payload.body) return { ...payload };
  const res = { ...payload };
  if (!isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, rawKeyHex);
  }
  return res;
}

/**
 * Decrypt issue fields (title, description, description_preview, comments) using rawKeyHex.
 */
export async function decryptIssueRecord(
  issue: Issue,
  rawKeyHex?: string | null,
): Promise<Issue> {
  if (!rawKeyHex) return issue;
  let title = issue.title;
  let description = issue.description;
  let descriptionPreview = issue.descriptionPreview || issue.description_preview;

  if (isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, rawKeyHex);
    } catch {}
  }
  if (isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, rawKeyHex);
    } catch {}
  }
  if (descriptionPreview && isVaultArmored(descriptionPreview)) {
    try {
      descriptionPreview = await decryptVaultText(descriptionPreview, rawKeyHex);
    } catch {}
  }

  let comments = issue.comments;
  if (Array.isArray(comments)) {
    comments = await Promise.all(
      comments.map(async (c) => {
        if (isVaultArmored(c.body)) {
          try {
            return { ...c, body: await decryptVaultText(c.body, rawKeyHex) };
          } catch {
            return c;
          }
        }
        return c;
      }),
    );
  }

  return {
    ...issue,
    title,
    description,
    descriptionPreview,
    description_preview: descriptionPreview,
    comments,
  };
}

/**
 * Decrypt comment record body using rawKeyHex.
 */
export async function decryptCommentRecord(
  comment: IssueComment,
  rawKeyHex?: string | null,
): Promise<IssueComment> {
  if (!rawKeyHex || !isVaultArmored(comment.body)) return comment;
  return {
    ...comment,
    body: await decryptVaultText(comment.body, rawKeyHex),
  };
}

