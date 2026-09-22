import * as daemonApi from '../daemonApi';
export type ExperimentFlag = { key: string; enabled: boolean };
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';

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
    fetchAgentDefaults: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken || !session?.daemonUrl) return { defaults: [] };
        const data = await daemonApi.fetchAgentDefaults(auth(session));
        const defaults = data?.defaults || data?.records || [];
        return { defaults };
      }),
      providesTags: [{ type: 'Preferences' as const, id: 'AGENT_DEFAULTS' }],
    }),
    saveAgentDefault: build.mutation<any, { use: string; agentId: string }>({
      queryFn: withSessionQuery(async ({ use, agentId }, { session }) => {
        return daemonApi.setAgentDefault({ ...auth(session), use, agentId });
      }),
      invalidatesTags: [{ type: 'Preferences' as const, id: 'AGENT_DEFAULTS' }, { type: 'Agents' as const, id: 'LIST' }],
    }),
    fetchAgentTemplate: build.query<any, { templateId: string }>({
      queryFn: withSessionQuery(async ({ templateId }, { session }) => {
        if (!session?.daemonUrl || !templateId) return { template: null };
        const data = await daemonApi.showAgentTemplate({ daemonUrl: session.daemonUrl, templateId });
        return { template: data?.template || null };
      }),
      providesTags: (_result, _error, { templateId }) => [{ type: 'AgentTemplate' as const, id: templateId }],
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
    fetchExperiments: build.query<{ flags: ExperimentFlag[] }, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/me/experiments');
          if (!Array.isArray(data?.experiments)) {
            return { error: { status: 'CUSTOM_ERROR', error: `Unexpected experiments response shape (got ${JSON.stringify(data)?.slice(0, 100)})` } as any };
          }
          const raw: Array<{ key: string; enabled: boolean }> = data.experiments;
          return { data: { flags: raw.map((f: any) => ({ key: String(f.key || ''), enabled: Boolean(f.enabled) })) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Experiments' as const, id: 'ALL' }],
    }),
    setExperiment: build.mutation<any, { key: string; enabled: boolean }>({
      queryFn: async ({ key, enabled }) => {
        try {
          const data = await cookieMutation(`/me/experiments/${encodeURIComponent(key)}`, 'PUT', { enabled });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Experiments' as const, id: 'ALL' }],
    }),
  }),
});

export type LspServerConfig = {
  config_id: string;
  bridge_id: string;
  language: string;
  cmd: string;
  args: string;
  file_extensions: string;
  root_markers: string;
  dir_prefix: string;
  created_at: string;
  updated_at: string;
};

export const lspApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listLspServerConfigs: build.query<{ configs: LspServerConfig[] }, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/lsp-servers`);
          return { data: { configs: Array.isArray(data?.configs) ? data.configs : [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
    upsertLspServerConfig: build.mutation<{ config: LspServerConfig }, {
      bridgeId: string;
      language: string;
      cmd: string;
      args?: string;
      fileExtensions?: string;
      rootMarkers?: string;
      dirPrefix?: string;
    }>({
      queryFn: async ({ bridgeId, language, cmd, args = '', fileExtensions = '', rootMarkers = '', dirPrefix = '' }) => {
        try {
          const normalizedPrefix = dirPrefix.replace(/\/+$/, '');
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/lsp-servers`, 'POST', {
            language,
            cmd,
            args,
            file_extensions: fileExtensions,
            root_markers: rootMarkers,
            dir_prefix: normalizedPrefix,
          });
          return { data: { config: data?.config } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
    deleteLspServerConfig: build.mutation<void, { bridgeId: string; configId: string }>({
      queryFn: async ({ bridgeId, configId }) => {
        try {
          await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/lsp-servers/${encodeURIComponent(configId)}`, 'DELETE');
          return { data: undefined };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
  }),
});

export const {
  useListLspServerConfigsQuery,
  useUpsertLspServerConfigMutation,
  useDeleteLspServerConfigMutation,
} = lspApi;

export const {
  useFetchPreferencesQuery,
  useSavePreferenceMutation,
  useFetchAgentDefaultsQuery,
  useSaveAgentDefaultMutation,
  useFetchSettingsCatalogQuery,
  useFetchAgentTemplateQuery,
  useLazyFetchAgentTemplateQuery,
  useFetchExperimentsQuery,
  useSetExperimentMutation,
} = settingsApi;
