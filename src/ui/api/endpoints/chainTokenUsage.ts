import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch } from '../cookieFetch';

export const chainTokenUsageApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // Per-agent + chain-total token usage (T10) of a Bridge-owned chain. Raw hub
    // payload; normalized by components/taskchain/chainTokenUsageModel.ts.
    // Refreshed by the instance token_usage_changed event (wsInvalidation.ts).
    getTaskChainTokenUsage: build.query<unknown, { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          return { data: await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/token-usage`) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [{ type: 'ChainTokenUsage' as const, id: chainId }],
    }),
  }),
});

export const { useGetTaskChainTokenUsageQuery } = chainTokenUsageApi;
