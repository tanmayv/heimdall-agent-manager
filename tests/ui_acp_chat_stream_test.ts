import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeVaultStore, installFetchCapture, installWindowShim } from './helpers/vaultEndpointHarness.ts';

const settle = (ms = 130) => new Promise((resolve) => setTimeout(resolve, ms));
const row = (revision: number, status = 'pending') => ({ message_id: 'msg_stream', conversation_id: 'chat_stream', sender_agent_instance_id: 'inst_stream', body: `snapshot ${revision}`, message_status: status, metadata: { acp: { revision } } });

test('serialized throttled fetch preserves a final event arriving during a fetch', async () => {
  const { createAssistantFetchQueue } = await import('../src/ui/api/acpChatStream.ts');
  let finish!: () => void;
  const started: number[] = [];
  const queue = createAssistantFetchQueue(async () => {
    started.push(Date.now());
    if (started.length === 1) await new Promise<void>((resolve) => { finish = resolve; });
  });
  queue.enqueue('chat', 'msg', 1);
  await settle(10);
  for (let revision = 2; revision <= 50; revision++) queue.enqueue('chat', 'msg', revision);
  assert.equal(started.length, 1);
  finish();
  await settle();
  assert.equal(started.length, 2, 'a final event requires a fresh request after the in-flight one');
  assert.ok(started[1] - started[0] >= 95);
  queue.enqueue('chat', 'msg', 49);
  await settle();
  assert.equal(started.length, 2, 'older events do not fetch');
  queue.clear();
});

test('snapshot upserts reject older revisions and terminal regression', async () => {
  const { upsertAssistantSnapshot } = await import('../src/ui/api/acpChatStream.ts');
  const rows: any[] = [];
  upsertAssistantSnapshot(rows, row(1));
  upsertAssistantSnapshot(rows, row(3, 'complete'));
  upsertAssistantSnapshot(rows, row(2));
  upsertAssistantSnapshot(rows, row(4));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].body, 'snapshot 3');
  assert.equal(rows[0].message_status, 'complete');
  upsertAssistantSnapshot(rows, { ...row(1), message_id: 'msg_older', created_at: '2026-11-18T00:00:00Z' });
  upsertAssistantSnapshot(rows, { ...row(1), message_id: 'msg_newer', created_at: '2026-11-18T01:00:00Z' });
  assert.ok(rows.findIndex((r) => r.message_id === 'msg_newer') < rows.findIndex((r) => r.message_id === 'msg_older'));
});

test('a stale list response cannot hide a newer streamed row or regress its revision', async () => {
  installWindowShim();
  const store = await makeVaultStore();
  const net = installFetchCapture();
  const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const arg = { conversationId: 'chat_stream', limit: 30 };
  const old = { ...row(1), message_id: 'msg_old', created_at: '2026-11-18T00:00:00Z' };
  net.setNextResponse({ data: [old] });
  const sub = store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate(arg));
  await sub.unwrap();
  const final = { ...row(5, 'complete'), created_at: '2026-11-18T01:00:00Z' };
  net.setNextResponse({ data: final });
  await store.dispatch(chatEndpoints.endpoints.fetchConversationMessage.initiate({ conversationId: arg.conversationId, messageId: final.message_id }, { subscribe: false, forceRefetch: true })).unwrap();
  net.setNextResponse({ data: [old] });
  await sub.refetch().unwrap();
  let data: any = chatEndpoints.endpoints.fetchConversationMessages.select(arg)(store.getState()).data;
  assert.deepEqual(data.messages.map((r: any) => r.message_id), ['msg_stream', 'msg_old']);
  net.setNextResponse({ data: [{ ...final, ...row(2) }, old] });
  await sub.refetch().unwrap();
  data = chatEndpoints.endpoints.fetchConversationMessages.select(arg)(store.getState()).data;
  assert.equal(data.messages[0].message_status, 'complete');
  assert.equal(data.messages[0].metadata.acp.revision, 5);
  sub.unsubscribe();
  store.dispatch(heimdallApi.util.resetApiState());
});

test('real WS and cookie endpoint fetch one sealed snapshot by ID and patch the loaded page', async () => {
  installWindowShim();
  const store = await makeVaultStore();
  const net = installFetchCapture();
  const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const ws = await import('../src/ui/api/wsInvalidation.ts');
  const arg = { conversationId: 'chat_stream', limit: 30 };
  net.setNextResponse({ data: [row(1)] });
  const sub = store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate(arg));
  await sub.unwrap();
  net.reset();
  const final = row(10, 'complete');
  final.body = 'vault:v2:sealed-snapshot';
  net.setNextResponse({ data: final });
  for (let revision = 2; revision <= 10; revision++) ws.handleUserWsEvent(store.dispatch, { type: 'chat_event', event: 'chat_updated', conversation_id: 'chat_stream', message_id: 'msg_stream', fetch_id: 'msg_stream', fetch_kind: 'chat_message', fetch_required: true, revision, message_status: revision === 10 ? 'complete' : 'pending' });
  await settle(230);
  const requests = net.requests.filter((r) => r.url.includes('/messages/msg_stream'));
  assert.equal(requests.length, 1, 'the burst coalesces without fetching a list page');
  assert.equal(requests[0].method, 'GET');
  const data: any = chatEndpoints.endpoints.fetchConversationMessages.select(arg)(store.getState()).data;
  assert.equal(data.messages.length, 1);
  assert.equal(data.messages[0].body, final.body);
  assert.equal(data.messages[0].message_status, 'complete');
  ws.resetQueuedInvalidations();
  sub.unsubscribe();
  store.dispatch(heimdallApi.util.resetApiState());
});
