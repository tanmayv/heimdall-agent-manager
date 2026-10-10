import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation, apiErrorText } from '../cookieFetch';
export type ConversationLaunchPreferences = { agent_id: string; project_id: string; bridge_id: string; favorite_agent_ids: string[]; pinned_agent_ids: string[] };
const tag = { type: 'Preferences' as const, id: 'CONVERSATION_LAUNCH' };
export const conversationLaunchApi = heimdallApi.injectEndpoints({ endpoints: build => ({
  getConversationLaunchPreferences: build.query<ConversationLaunchPreferences, void>({
    queryFn: async () => { try { return { data: await cookieJsonFetch('/me/conversation-launch') }; } catch (e) { return { error: { status: 'CUSTOM_ERROR', error: apiErrorText(e) } }; } },
    providesTags: [tag],
  }),
  saveConversationLaunchSelection: build.mutation<ConversationLaunchPreferences, { field: 'agent_id' | 'project_id' | 'bridge_id'; value: string }>({
    queryFn: async ({ field, value }) => { try { return { data: await cookieMutation('/me/conversation-launch', 'PATCH', { [field]: value }) }; } catch (e) { return { error: { status: 'CUSTOM_ERROR', error: apiErrorText(e) } }; } },
    invalidatesTags: [tag],
  }),
  setAgentFavorite: build.mutation<ConversationLaunchPreferences, { agentId: string; favorite: boolean }>({
    queryFn: async ({ agentId, favorite }) => { try { return { data: await cookieMutation(`/agents/${encodeURIComponent(agentId)}/favorite`, 'PUT', { favorite }) }; } catch (e) { return { error: { status: 'CUSTOM_ERROR', error: apiErrorText(e) } }; } },
    invalidatesTags: [tag],
  }),
}) });
export const { useGetConversationLaunchPreferencesQuery, useSaveConversationLaunchSelectionMutation, useSetAgentFavoriteMutation } = conversationLaunchApi;
