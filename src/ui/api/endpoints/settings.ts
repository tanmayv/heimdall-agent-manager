import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

export const settingsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    fetchPreferences: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken) return { preferences: [] };
        const data = await daemonApi.fetchPreferences(auth(session));
        return { preferences: data?.preferences || [] };
      }),
      providesTags: (result) => [
        { type: 'Preferences' as const, id: 'ALL' },
        ...((result?.preferences || []).map((pref: any) => ({ type: 'Preferences' as const, id: String(pref.key || '') })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    savePreference: build.mutation<any, { key: string; value: string; interrupt?: boolean }>({
      queryFn: withSessionQuery(async ({ key, value, interrupt = false }, { session }) => {
        const data = await daemonApi.savePreference({ ...auth(session), key, value, interrupt });
        return { preference: data?.preference || data };
      }),
      invalidatesTags: (_result, _error, { key }) => [
        { type: 'Preferences' as const, id: 'ALL' },
        { type: 'Preferences' as const, id: key },
      ],
    }),
    fetchSettingsCatalog: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.daemonUrl) return { templates: [], providers: [] };
        const [templates, providers] = await Promise.all([
          daemonApi.listAgentTemplates({ daemonUrl: session.daemonUrl }).catch(() => []),
          daemonApi.listAgentProviders({ daemonUrl: session.daemonUrl }).catch(() => []),
        ]);
        return { templates, providers };
      }),
      providesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }, { type: 'Preferences' as const, id: 'CATALOG' }],
    }),
  }),
});

export const {
  useFetchPreferencesQuery,
  useSavePreferenceMutation,
  useFetchSettingsCatalogQuery,
} = settingsApi;
