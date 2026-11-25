import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
export type EventWebhook = { webhook_id: string; name: string; dedupe_header: string; enabled: boolean; created_at: string; updated_at: string; last_received_at: string };
export type WebhookSecret = { webhook: EventWebhook; token: string };
const path = (id: string) => '/webhooks/' + encodeURIComponent(id);
export const listWebhooks = () => cookieJsonFetch('/webhooks') as Promise<EventWebhook[]>;
// Secrets deliberately bypass RTK Query: never retain a token in the Redux cache.
export const createWebhook = (name: string, dedupe_header = 'Idempotency-Key') => cookieMutation('/webhooks', 'POST', { name, dedupe_header }) as Promise<WebhookSecret>;
export const rotateWebhook = (id: string) => cookieMutation(path(id) + '/rotate', 'POST') as Promise<WebhookSecret>;
export const setWebhookEnabled = (id: string, enabled: boolean) => cookieMutation(path(id), 'PATCH', { enabled }) as Promise<EventWebhook>;

export const setWebhookDedupeHeader = (id: string, dedupe_header: string) => cookieMutation(path(id), 'PATCH', { dedupe_header }) as Promise<EventWebhook>;
