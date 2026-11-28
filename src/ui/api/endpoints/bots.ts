import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieJsonFetchEnvelope, cookieMutation, customQueryError } from '../cookieFetch';

export type BotStatus = 'ready' | 'working' | 'starting' | 'sleeping' | 'waiting_for_machine' | 'new';
export interface BotView {
  bot_id: string;
  display_name: string;
  status: BotStatus;
  status_detail: string;
  telegram: { configured: boolean; bot_username: string; binding: null | { state: string; display: string; connected_at: string } };
  whatsapp: BotWhatsApp;
  placement_revision: number;
  advanced: { conversation_id?: string; agent_instance_id: string; bridge_id: string; bridge_label: string; provider: string; model: string; runtime_status: string };
}
export interface BotPlacementCandidate { bridge_id: string; provider: string; model: string; tier: 'preferred' | 'allowed' }
export interface BotPlacement { placement_revision: number; candidates: BotPlacementCandidate[] }
export interface BotPlacementOptions { bridges: { bridge_id: string; label: string; online: boolean; bot_capable: boolean; providers: { provider: string; label: string; models: string[] }[] }[] }
export interface TelegramPairing { pairing_url: string; expires_at: string }
export interface BotWhatsApp {
  configured: boolean;
  /** Effective whatsapp_enabled entitlement; WhatsApp is invite-only. Absent on older hubs. */
  enabled?: boolean;
  phone_display: string;
  binding: null | { state: string; display: string; connected_at: string };
  window_open: boolean;
  reengage_sent: boolean;
  reengage_error: '' | 'template_unavailable' | 'send_failed';
  held_replies: { message_id: string; body: string; created_at: string }[];
}
export interface WhatsAppPairing { pairing_url: string; pairing_text: string; phone_display: string; expires_at: string }
export interface BotMessage { message_id: string; direction: string; body: string; body_purged: boolean; send_state: string; created_at: string; read_at: string; replied_at: string }
export interface BotAttachment { attachment_id: string; artifact_id: string; name: string; mime: string; size: number; kind: string; state: string }
export interface UnifiedBotMessage extends BotMessage { binding_id: string; provider: 'telegram' | 'whatsapp' | 'web'; attachments?: BotAttachment[]; metadata?: { action_ids: string[] } }
export interface BotMessagePage { messages: UnifiedBotMessage[]; next_cursor: string }
export interface BotDelivery { delivery_id: string; state: string; round: number; waiting_reason: string; finish_reason: string; created_at: string; finished_at: string; attempts: { attempt_id: string; bridge_id: string; state: string; report: Record<string, unknown> }[] }

export interface AgentWrite { write_id: string; seq: number; actor_agent_instance_id: string; actor_agent_id: string; actor_display_name: string; resource_kind: 'project' | 'memory' | 'agent'; resource_id: string; action: 'create' | 'update' | 'archive' | 'unarchive'; fields: string[]; created_at: string }

async function request<T>(path: string, method?: string, body?: unknown, envelope = false) {
  try { return { data: await (method ? cookieMutation(path, method, body) : (envelope ? cookieJsonFetchEnvelope(path) : cookieJsonFetch(path))) as T }; }
  catch (error) { return { error: customQueryError(error) }; }
}
const root = '/bots/me';
export interface BotWebConversation {
  enabled: boolean;
  generation: number;
  agent_instance_id: string;
  conversation_id: string;
  bot_id: string;
}
export const botsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getAgentWrites: build.query<{ items: AgentWrite[]; next_cursor: string }, string | void>({
      async queryFn(cursor) {
        const result = await request<{ data: AgentWrite[]; page?: { next_cursor?: string } }>(
          '/me/agent-writes?limit=20' + (cursor ? '&cursor=' + encodeURIComponent(cursor) : ''), undefined, undefined, true);
        if ('error' in result) return { error: result.error! };
        return { data: { items: result.data.data, next_cursor: result.data.page?.next_cursor ?? '' } };
      },
      providesTags: ['Bot'],
    }),
    getBot: build.query<BotView, void>({ queryFn: () => request(root), providesTags: ['Bot'] }),
    getBotWebConversation: build.query<BotWebConversation, void>({
      queryFn: () => request(root + '/web-conversation'),
      providesTags: ['Bot'],
    }),
    putBotWebConversation: build.mutation<BotWebConversation, { enabled: boolean; expected_generation: number }>({
      queryFn: (body) => request(root + '/web-conversation', 'PUT', body),
      invalidatesTags: ['Bot'],
    }),
    createBot: build.mutation<BotView, void>({ queryFn: () => request(root, 'POST', {}), invalidatesTags: ['Bot'] }),
    deleteBot: build.mutation<{ deleted: boolean }, void>({ queryFn: () => request(root, 'DELETE'), invalidatesTags: ['Bot'] }),
    getBotPlacement: build.query<BotPlacement, void>({ queryFn: () => request(root + '/placement'), providesTags: ['Bot'] }),
    putBotPlacement: build.mutation<BotPlacement, { expected_revision: number; candidates: BotPlacementCandidate[] }>({ queryFn: (body) => request(root + '/placement', 'PUT', body), invalidatesTags: ['Bot'] }),
    getBotPlacementOptions: build.query<BotPlacementOptions, void>({ queryFn: () => request(root + '/placement/options'), providesTags: ['Bot'] }),
    createTelegramPairing: build.mutation<TelegramPairing, void>({ queryFn: () => request(root + '/channels/telegram/pairing', 'POST', {}), invalidatesTags: ['Bot'] }),
    disconnectTelegram: build.mutation<{ disconnected: boolean }, void>({ queryFn: () => request(root + '/channels/telegram', 'DELETE'), invalidatesTags: ['Bot'] }),
    createWhatsAppPairing: build.mutation<WhatsAppPairing, void>({ queryFn: () => request(root + '/channels/whatsapp/pairing', 'POST', {}), invalidatesTags: ['Bot'] }),
    disconnectWhatsApp: build.mutation<{ disconnected: boolean }, void>({ queryFn: () => request(root + '/channels/whatsapp', 'DELETE'), invalidatesTags: ['Bot'] }),
    getUnifiedBotMessages: build.query<BotMessagePage, { limit?: number; cursor?: string } | void>({
      queryFn: (args) => {
        const page = args || {};
        return request(root + '/messages?limit=' + (page.limit ?? 50) + (page.cursor ? '&cursor=' + encodeURIComponent(page.cursor) : ''));
      },
      providesTags: ['Bot'],
    }),
    getUnifiedBotMessagesById: build.query<BotMessagePage, readonly string[]>({
      queryFn: (ids) => request(root + '/messages?message_ids=' + encodeURIComponent(JSON.stringify(ids))),
      providesTags: ['Bot'],
    }),
    sendBotWebMessage: build.mutation<{ message_id: string; created: boolean }, { text: string; idempotency_key: string; artifact_ids?: string[] }>({
      queryFn: (body) => request(root + '/channels/web/messages', 'POST', body), invalidatesTags: ['Bot'],
    }),
    getBotMessages: build.query<{ messages: BotMessage[] }, number | void>({ queryFn: (limit = 50) => request(root + '/channels/telegram/messages?limit=' + limit), providesTags: ['Bot'] }),
    getBotDeliveries: build.query<{ deliveries: BotDelivery[] }, number | void>({ queryFn: (limit = 20) => request(root + '/deliveries?limit=' + limit), providesTags: ['Bot'] }),
  }),
});
export const { useGetBotWebConversationQuery, usePutBotWebConversationMutation } = botsApi;
export const { useGetUnifiedBotMessagesQuery, useSendBotWebMessageMutation, useGetAgentWritesQuery, useGetBotQuery, useCreateBotMutation, useDeleteBotMutation, useGetBotPlacementQuery, usePutBotPlacementMutation, useGetBotPlacementOptionsQuery, useCreateWhatsAppPairingMutation, useDisconnectWhatsAppMutation, useCreateTelegramPairingMutation, useDisconnectTelegramMutation, useGetBotMessagesQuery, useGetBotDeliveriesQuery } = botsApi;
