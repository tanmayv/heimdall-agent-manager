import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';

export type CurrentUserToken = {
  token_id?: string;
  tokenId?: string;
  owner_user_id?: string;
  ownerUserId?: string;
  label?: string;
  status?: string;
  created_at?: string;
  createdAt?: string;
  updated_at?: string;
  updatedAt?: string;
  last_used_at?: string;
  lastUsedAt?: string;
  expires_at?: string;
  expiresAt?: string;
  revoked_at?: string;
  revokedAt?: string;
  created_from?: string;
  createdFrom?: string;
  device_label?: string;
  deviceLabel?: string;
};

function tokenId(token: CurrentUserToken): string {
  return String(token?.token_id || token?.tokenId || '');
}

export const userTokensApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    fetchCurrentUser: build.query<any, void>({
      queryFn: async () => {
        try {
          const user = await cookieJsonFetch('/me');
          return { data: { user } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: [{ type: 'UserTokens' as const, id: 'ME' }],
    }),
    listCurrentUserTokens: build.query<any, void>({
      queryFn: async () => {
        try {
          const rows = await cookieJsonFetch('/me/tokens');
          return { data: { tokens: Array.isArray(rows) ? rows : [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: (result) => [
        { type: 'UserTokens' as const, id: 'LIST' },
        ...((result?.tokens || []).map((token: CurrentUserToken) => ({ type: 'UserTokens' as const, id: tokenId(token) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    issueCurrentUserToken: build.mutation<any, { label?: string; expiresAt?: string }>({
      queryFn: async ({ label = '', expiresAt = '' }) => {
        try {
          const payload: any = { label: label.trim() || 'Electron app' };
          if (expiresAt.trim()) payload.expires_at = expiresAt.trim();
          const data = await cookieMutation('/me/tokens', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      invalidatesTags: [{ type: 'UserTokens' as const, id: 'LIST' }],
    }),
    revokeCurrentUserToken: build.mutation<any, { tokenId: string }>({
      queryFn: async ({ tokenId }) => {
        if (!tokenId) return { error: { status: 'CUSTOM_ERROR', error: 'Missing token id' } as any };
        try {
          const data = await cookieMutation(`/me/tokens/${encodeURIComponent(tokenId)}/revoke`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      invalidatesTags: (_r, _e, { tokenId }) => [{ type: 'UserTokens' as const, id: 'LIST' }, { type: 'UserTokens' as const, id: tokenId }],
    }),
  }),
});

export const {
  useFetchCurrentUserQuery,
  useListCurrentUserTokensQuery,
  useIssueCurrentUserTokenMutation,
  useRevokeCurrentUserTokenMutation,
} = userTokensApi;
