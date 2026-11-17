import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation, customQueryError } from '../cookieFetch';

export type BotStatus = 'ready' | 'working' | 'starting' | 'sleeping' | 'waiting_for_machine' | 'new';
export interface BotView {
  bot_id: string;
  display_name: string;
  status: BotStatus;
  status_detail: string;
  telegram: { configured: boolean; bot_username: string; binding: null | { state: string; display: string; connected_at: string } };
  placement_revision: number;
  advanced: { agent_instance_id: string; bridge_id: string; bridge_label: string; provider: string; model: string; runtime_status: string };
}
export interface BotPlacementCandidate { bridge_id: string; provider: string; model: string; tier: 'preferred' | 'allowed' }
export interface BotPlacement { placement_revision: number; candidates: BotPlacementCandidate[] }
export interface BotPlacementOptions { bridges: { bridge_id: string; label: string; online: boolean; bot_capable: boolean; providers: { provider: string; label: string; models: string[] }[] }[] }
export interface TelegramPairing { pairing_url: string; expires_at: string }
export interface BotMessage { message_id: string; direction: string; body: string; body_purged: boolean; send_state: string; created_at: string; read_at: string; replied_at: string }
export interface BotDelivery { delivery_id: string; state: string; round: number; waiting_reason: string; finish_reason: string; created_at: string; finished_at: string; attempts: { attempt_id: string; bridge_id: string; state: string; report: Record<string, unknown> }[] }

async function request<T>(path: string, method?: string, body?: unknown) {
  try { return { data: await (method ? cookieMutation(path, method, body) : cookieJsonFetch(path)) as T }; }
  catch (error) { return { error: customQueryError(error) }; }
}
const root = '/bots/me';
export const botsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getBot: build.query<BotView, void>({ queryFn: () => request(root), providesTags: ['Bot'] }),
    createBot: build.mutation<BotView, void>({ queryFn: () => request(root, 'POST', {}), invalidatesTags: ['Bot'] }),
    deleteBot: build.mutation<{ deleted: boolean }, void>({ queryFn: () => request(root, 'DELETE'), invalidatesTags: ['Bot'] }),
    getBotPlacement: build.query<BotPlacement, void>({ queryFn: () => request(root + '/placement'), providesTags: ['Bot'] }),
    putBotPlacement: build.mutation<BotPlacement, { expected_revision: number; candidates: BotPlacementCandidate[] }>({ queryFn: (body) => request(root + '/placement', 'PUT', body), invalidatesTags: ['Bot'] }),
    getBotPlacementOptions: build.query<BotPlacementOptions, void>({ queryFn: () => request(root + '/placement/options'), providesTags: ['Bot'] }),
    createTelegramPairing: build.mutation<TelegramPairing, void>({ queryFn: () => request(root + '/channels/telegram/pairing', 'POST', {}), invalidatesTags: ['Bot'] }),
    disconnectTelegram: build.mutation<{ disconnected: boolean }, void>({ queryFn: () => request(root + '/channels/telegram', 'DELETE'), invalidatesTags: ['Bot'] }),
    getBotMessages: build.query<{ messages: BotMessage[] }, number | void>({ queryFn: (limit = 50) => request(root + '/channels/telegram/messages?limit=' + limit), providesTags: ['Bot'] }),
    getBotDeliveries: build.query<{ deliveries: BotDelivery[] }, number | void>({ queryFn: (limit = 20) => request(root + '/deliveries?limit=' + limit), providesTags: ['Bot'] }),
  }),
});
export const { useGetBotQuery, useCreateBotMutation, useDeleteBotMutation, useGetBotPlacementQuery, usePutBotPlacementMutation, useGetBotPlacementOptionsQuery, useCreateTelegramPairingMutation, useDisconnectTelegramMutation, useGetBotMessagesQuery, useGetBotDeliveriesQuery } = botsApi;
