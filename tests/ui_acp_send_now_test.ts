// ACP delivery + batch Send now in the Conversation view (docs/acp-send-now.md).
//   - acpDelivery.ts: placement (transcript / above-composer Sending / turn-held queue),
//     causal transcript order, tray/batch view, status labels.
//   - chats.ts: GET/POST /chats/{cid}/send-now, incl. the 503 {outcome:"failed"} body.
//   - wsInvalidation.ts: messages_delivery refetches only the newest page + Send now state.
//   - QueuedMessages.tsx: left bubbles without timestamps, ONE batch action, a11y text.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_acp_send_now_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import {
  acpDeliveryLabel, noticeSendNowPhase, notifiedUnreadCount, orderTranscript, parseAcpDelivery, parseSendNowState, placementFor, sendNowErrorText,
  sendNowTooltip, trayView, unreadUserRows, type AcpDelivery, type SendNowBatch,
} from '../src/ui/components/chat/acpDelivery.ts';
import type { ChatMessage } from '../src/ui/components/chat/types.ts';
import { SEND_NOW_AGENT_NOTIFIED_AT_FIELD, agentNotifiedUnixMs } from '../src/ui/api/agentNotified.ts';

const T0 = Date.parse('2026-11-23T17:00:00Z');
const iso = (sec: number) => new Date(T0 + sec * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

function delivery(over: Record<string, unknown>): AcpDelivery {
  const parsed = parseAcpDelivery({ status: 'sent', state: 'sent', hold_reason: '', tray_eligible: false, mode: '',
    launch_epoch: 'ep1', turn_id: '', batch_id: '', error: '', delivered_at: '', agent_read_at: '', updated_at: '', ...over });
  assert.ok(parsed);
  return parsed;
}

const held = (over: Record<string, unknown> = {}) => delivery({ status: 'queued', state: 'queued', hold_reason: 'turn_active', tray_eligible: true, ...over });

function user(id: string, sec: number, d: AcpDelivery | null, over: Partial<ChatMessage> = {}): ChatMessage {
  return { key: id, messageId: id, body: `body ${id}`, isUser: true, createdUnixMs: T0 + sec * 1000, deliveredUnixMs: 0,
    readUnixMs: 0, deliveryFailedUnixMs: 0, deliveryError: '', sending: false, authorLabel: 'you', acpDelivery: d, ...over };
}
function agent(id: string, sec: number, inputIds: string[] = []): ChatMessage {
  return { key: id, messageId: id, body: `reply ${id}`, isUser: false, createdUnixMs: T0 + sec * 1000, deliveredUnixMs: 0,
    readUnixMs: 0, deliveryFailedUnixMs: 0, deliveryError: '', sending: false, authorLabel: 'agent',
    metadata: inputIds.length ? { acp: { input_ids: inputIds } } : {} };
}

test('parseAcpDelivery: only the documented statuses; PTY/legacy rows have none', () => {
  assert.equal(parseAcpDelivery(undefined), null);
  assert.equal(parseAcpDelivery({ status: 'waiting_for_connection' }), null, 'no invented offline status');
  const d = held({ delivered_at: iso(5), agent_read_at: '' });
  assert.equal(d.trayEligible, true);
  assert.equal(d.deliveredUnixMs, T0 + 5000);
  assert.equal(delivery({ tray_eligible: 'true' }).trayEligible, false, 'only a boolean true is eligible');
});

test('placement: tray only for authoritative turn-held rows; every other distinction', () => {
  const acp = true;
  assert.equal(placementFor(user('a', 0, held()), acp), 'queued', 'turn_active + tray_eligible');
  assert.equal(placementFor(user('a', 0, held({ state: 'dispatching' })), acp), 'queued', 'natural steer in flight stays in the group');
  // Idle send: the bridge says dispatch_pending; not queue/tray, still not delivered.
  assert.equal(placementFor(user('b', 0, delivery({ status: 'sent', state: 'queued', hold_reason: 'dispatch_pending' })), acp), 'sending');
  // Transport offline / vault blocked / not yet fetched: all just `sent` (Hub-persisted).
  assert.equal(placementFor(user('c', 0, delivery({ status: 'sent', state: 'sent' })), acp), 'sending');
  // Bridge prefetch/admission (legacy read_at) is not a read and not delivery.
  assert.equal(placementFor(user('d', 0, held(), { readUnixMs: T0 }), acp), 'queued', 'read_at ignored');
  // Delivery and actual read move it into the transcript; read can skip delivered.
  assert.equal(placementFor(user('e', 0, delivery({ status: 'delivered', state: 'delivered', mode: 'prompt' })), acp), 'transcript');
  assert.equal(placementFor(user('f', 0, delivery({ status: 'read', state: 'queued', hold_reason: 'turn_active', tray_eligible: false, agent_read_at: iso(3) })), acp), 'transcript');
  assert.equal(placementFor(user('g', 0, delivery({ status: 'not_delivered', state: 'discarded' })), acp), 'transcript');
  // Unrelated failure: the transcript shows the failure as today.
  assert.equal(placementFor(user('h', 0, delivery({}), { deliveryFailedUnixMs: T0 }), acp), 'transcript');
  // Optimistic ACP send (no server copy yet) waits above the composer; PTY does not.
  assert.equal(placementFor(user('local_1', 0, null, { sending: true }), true), 'sending');
  assert.equal(placementFor(user('local_1', 0, null, { sending: true }), false), 'transcript', 'PTY unchanged');
  assert.equal(placementFor(user('legacy', 0, null), true), 'transcript', 'pre-migration ACP rows unchanged');
  assert.equal(placementFor(agent('r', 0), true), 'transcript');
});

test('status labels: Sent -> Queued -> Delivered -> Read, never from read_at', () => {
  assert.equal(acpDeliveryLabel(delivery({})).label, 'Sent');
  assert.equal(acpDeliveryLabel(held()).label, 'Queued');
  assert.equal(acpDeliveryLabel(delivery({ status: 'delivered' })).label, 'Delivered');
  assert.equal(acpDeliveryLabel(delivery({ status: 'read' })).label, 'Read');
  assert.equal(acpDeliveryLabel(delivery({ status: 'not_delivered' })).label, 'Not delivered');
  for (const e of ['cancel_timeout', 'bridge_offline', 'agent_restarted', 'x']) assert.match(sendNowErrorText(e), /Still waiting|restarted/);
  assert.doesNotMatch(Object.values({ a: sendNowErrorText('bridge_offline') }).join(), /Waiting for connection/);
});

test('causal order: a held message sits where the agent got it, before the reply that answers it', () => {
  const rows = [
    user('u0', 0, delivery({ status: 'delivered', state: 'delivered', delivered_at: iso(0) })),
    agent('a0', 1),
    // Sent at 2s during the a0 turn, delivered at 9s when the turn ended.
    user('u1', 2, delivery({ status: 'delivered', state: 'delivered', delivered_at: iso(9) })),
    agent('a0b', 5), // more text of the first turn, a later segment
    agent('a1', 9, ['u1']), // same second as the delivery
  ];
  assert.deepEqual(orderTranscript(rows).map((r) => r.messageId), ['u0', 'a0', 'a0b', 'u1', 'a1']);
  // A reply that answers an input never precedes it, whatever the clock says.
  const skew = [agent('a2', 4, ['u2']), user('u2', 3, delivery({ status: 'read', state: 'delivered', delivered_at: iso(8), agent_read_at: iso(8) }))];
  assert.deepEqual(orderTranscript(skew).map((r) => r.messageId), ['u2', 'a2']);
  // Same second, no input_ids: the row created first goes first (idle send then reply).
  const idle = [agent('a3', 10), user('u3', 9, delivery({ status: 'delivered', state: 'delivered', delivered_at: iso(10) }))];
  assert.deepEqual(orderTranscript(idle).map((r) => r.messageId), ['u3', 'a3']);
  // Same second, held across a reply created earlier in that second: the reply first.
  const held2 = [user('u4', 12, delivery({ status: 'delivered', state: 'delivered', delivered_at: iso(12) })), agent('a4', 11)];
  assert.deepEqual(orderTranscript(held2).map((r) => r.messageId), ['a4', 'u4']);
  // PTY / legacy: untouched, same array.
  const pty = [user('p1', 3, null), agent('p2', 1)];
  assert.equal(orderTranscript(pty), pty);
});

test('tray view: FIFO snapshot batch, later arrivals separate, read/drain/retry exclusion', () => {
  const m1 = user('m1', 1, held());
  const m2 = user('m2', 2, held());
  const m3 = user('m3', 3, held());
  const sendingRow = user('s1', 4, delivery({ status: 'sent', state: 'queued', hold_reason: 'dispatch_pending' }));
  const batch = (state: string, ids: string[], error = ''): SendNowBatch => ({ batchId: 'b1', requestId: 'sn_1', launchEpoch: 'ep1', attempt: 1, state, error, messageIds: ids });

  let v = trayView([m2, sendingRow, m1], true, null);
  assert.equal(v.batchPhase, 'idle');
  assert.deepEqual(v.waiting.map((r) => r.messageId), ['m1', 'm2'], 'FIFO by created time');
  assert.deepEqual(v.sending.map((r) => r.messageId), ['s1'], 'not turn-held: no Send now');

  // Pending batch of m1,m2; m3 arrives later and is not part of it.
  v = trayView([m1, m2, m3], true, batch('sent', ['m1', 'm2']));
  assert.equal(v.batchPhase, 'pending');
  assert.deepEqual(v.batch.map((r) => r.messageId), ['m1', 'm2']);
  assert.deepEqual(v.waiting.map((r) => r.messageId), ['m3']);

  // The agent reads m1 during the pending batch: it leaves the tray on its own.
  const m1Read = user('m1', 1, delivery({ status: 'read', state: 'queued', hold_reason: 'turn_active', tray_eligible: false, agent_read_at: iso(5) }));
  v = trayView([m1Read, m2, m3], true, batch('dispatching', ['m1', 'm2']));
  assert.deepEqual(v.batch.map((r) => r.messageId), ['m2']);

  // Failed: Retry covers only members still waiting; m3 still waits separately.
  v = trayView([m1Read, m2, m3], true, batch('failed', ['m1', 'm2'], 'cancel_timeout'));
  assert.equal(v.batchPhase, 'failed');
  assert.equal(v.batchError, 'cancel_timeout');
  assert.deepEqual(v.batch.map((r) => r.messageId), ['m2']);
  assert.deepEqual(v.waiting.map((r) => r.messageId), ['m3']);

  // Partial drain / already delivered: every member left, so the batch is moot.
  v = trayView([m3], true, batch('failed', ['m1', 'm2'], 'bridge_offline'));
  assert.equal(v.batchPhase, 'idle');
  assert.deepEqual(v.waiting.map((r) => r.messageId), ['m3']);

  // Delivered / empty batches never hold the button.
  for (const state of ['delivered', 'empty']) assert.equal(trayView([m1], true, batch(state, ['m1'])).batchPhase, 'idle');
});

test('send-now state parsing and tooltip honesty', () => {
  const s = parseSendNowState({ conversation_id: 'c', runtime_transport: 'acp', launch_epoch: 'ep', steering_supported: null, batch: null });
  assert.equal(s.steeringSupported, null);
  assert.equal(s.batch, null);
  assert.equal(parseSendNowState({ steering_supported: false }).steeringSupported, false);
  assert.match(sendNowTooltip(true), /current turn/);
  assert.match(sendNowTooltip(false), /Stop the current turn/);
  assert.match(sendNowTooltip(null), /or the current turn stops first/);
  // The runtime's declared Send now capability (members / notice / none).
  assert.equal(s.sendNow, '');
  assert.equal(parseSendNowState({ send_now: 'members' }).sendNow, 'members');
  assert.equal(parseSendNowState({ send_now: 'notice' }).sendNow, 'notice');
  assert.equal(parseSendNowState({ send_now: 'bogus' }).sendNow, '');
  assert.match(sendNowTooltip(null, 'notice'), /read its messages now/);
  // When the agent was last notified (PTY unread tray); '' or junk = never.
  assert.equal(s.agentNotifiedUnixMs, 0);
  assert.equal(parseSendNowState({ agent_notified_at: '' }).agentNotifiedUnixMs, 0);
  assert.equal(parseSendNowState({ agent_notified_at: 'nope' }).agentNotifiedUnixMs, 0);
  assert.equal(parseSendNowState({ agent_notified_at: '2026-11-23T17:00:05Z' }).agentNotifiedUnixMs, Date.parse('2026-11-23T17:00:05Z'));
});

test('agent_notified_at: the TS mirror names the same field as the Odin contract', () => {
  const contract = readFileSync(new URL('../src/contracts/agent_notified.odin', import.meta.url), 'utf8');
  assert.match(contract, new RegExp(`SEND_NOW_AGENT_NOTIFIED_AT_FIELD :: "${SEND_NOW_AGENT_NOTIFIED_AT_FIELD}"`));
  assert.equal(agentNotifiedUnixMs({ [SEND_NOW_AGENT_NOTIFIED_AT_FIELD]: '2026-01-01T00:00:30Z' }), Date.parse('2026-01-01T00:00:30Z'));
  assert.equal(agentNotifiedUnixMs({}), 0, 'older hub');
  assert.equal(agentNotifiedUnixMs(null), 0);
});

test('notice Send now (PTY): unread rows count as notified when created at or before the last notice', () => {
  const rows = [user('p1', 1, null), user('p2', 2, null), user('p3', 3, null)];
  const created = (i: number) => rows[i].createdUnixMs;
  assert.equal(notifiedUnreadCount(rows, 0), 0, 'never notified');
  assert.equal(notifiedUnreadCount(rows, created(0) - 1), 0);
  assert.equal(notifiedUnreadCount(rows, created(1)), 2, 'inclusive');
  assert.equal(notifiedUnreadCount(rows, created(2) + 1000), 3);
});

test('notice Send now (PTY): unread user rows and the batch phase', () => {
  const rows = [
    user('p1', 1, null), user('p2', 2, null, { readUnixMs: T0 + 5000 }), user('p3', 3, null, { sending: true }),
    user('p4', 4, null, { deliveryFailedUnixMs: T0 }), agent('a1', 5), user('p5', 6, held()),
  ];
  assert.deepEqual(unreadUserRows(rows).map((r) => r.messageId), ['p1'], 'saved, unread, not ACP-tracked');
  const b = (state: string) => ({ batchId: 'b', requestId: 'r', launchEpoch: 'ep', attempt: 1, state, error: '', messageIds: [] });
  assert.equal(noticeSendNowPhase(null), 'idle');
  for (const state of ['pending', 'sent', 'dispatching']) assert.equal(noticeSendNowPhase(b(state)), 'pending');
  assert.equal(noticeSendNowPhase(b('failed')), 'failed');
  for (const state of ['delivered', 'empty']) assert.equal(noticeSendNowPhase(b(state)), 'idle');
  assert.match(sendNowErrorText('send_failed'), /terminal did not take it/);
  // A Send now the runtime held back names its reason (never "delivered").
  assert.match(sendNowErrorText('held'), /restarting/);
  assert.match(sendNowErrorText('agent_stopped'), /stopped/);
});

function fakeResponse(status: number, body: any) {
  const text = JSON.stringify(body);
  const res: any = { ok: status >= 200 && status < 300, status, headers: { get: () => 'application/json' },
    text: async () => text, json: async () => JSON.parse(text) };
  res.clone = () => fakeResponse(status, body);
  return res;
}

test('API: POST send-now keeps the 503 failed batch, 409 keeps its status; messages_delivery refetches only its conversation', async () => {
  const hits: Array<{ path: string; method: string; body: any }> = [];
  const prevFetch = (globalThis as any).fetch;
  let postReply: { status: number; body: any } = { status: 202, body: { data: { outcome: 'accepted', batch: null } } };
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    const method = String(init.method || 'GET');
    hits.push({ path: url.pathname, method, body: init.body ? JSON.parse(init.body) : null });
    if (url.pathname.endsWith('/send-now') && method === 'POST') return fakeResponse(postReply.status, postReply.body);
    if (url.pathname.endsWith('/send-now')) return fakeResponse(200, { data: { conversation_id: 'conv_1', runtime_transport: 'acp', launch_epoch: 'ep1', steering_supported: true, batch: null } });
    if (url.pathname.endsWith('/messages')) return fakeResponse(200, { data: [], page: {} });
    return fakeResponse(200, { data: {} });
  };
  try {
    const store = await makeVaultStore();
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { handleUserWsEvent, flushQueuedInvalidations, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
    resetQueuedInvalidations();
    await store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: 'conv_1' }));
    const state = await store.dispatch(chatEndpoints.endpoints.fetchSendNowState.initiate({ conversationId: 'conv_1' }));
    assert.equal(state.data.steeringSupported, true);
    assert.equal(state.data.launchEpoch, 'ep1');

    postReply = { status: 503, body: { data: { outcome: 'failed', batch: { batch_id: 'b1', request_id: 'sn_x', launch_epoch: 'ep1', attempt: 1, state: 'failed', error: 'bridge_offline', message_ids: ['msg_1'], excluded: [] } } } };
    const failed: any = await store.dispatch(chatEndpoints.endpoints.sendNow.initiate({ conversationId: 'conv_1', requestId: 'sn_x', launchEpoch: 'ep1', messageIds: ['msg_1'] }));
    assert.equal(failed.data.outcome, 'failed');
    assert.equal(failed.data.batch.error, 'bridge_offline');
    const post = hits.find((h) => h.method === 'POST')!;
    assert.deepEqual(post.body, { request_id: 'sn_x', launch_epoch: 'ep1', message_ids: ['msg_1'] });

    postReply = { status: 409, body: { error: { code: 'conflict', message: 'stale launch epoch' } } };
    const stale: any = await store.dispatch(chatEndpoints.endpoints.sendNow.initiate({ conversationId: 'conv_1', requestId: 'sn_y', launchEpoch: 'old', messageIds: [] }));
    assert.equal(stale.error.originalStatus, 409);

    await new Promise((r) => setTimeout(r, 30));
    hits.length = 0;
    handleUserWsEvent(store.dispatch, { type: 'chat_event', event: 'messages_delivery', conversation_id: 'conv_1',
      agent_instance_id: 'inst_1', message_ids: ['msg_1'], batch_id: 'b1', fetch_required: true });
    flushQueuedInvalidations();
    await new Promise((r) => setTimeout(r, 30));
    const paths = hits.map((h) => `${h.method} ${h.path}`).sort();
    assert.deepEqual(paths, ['GET /api/v1/chats/conv_1/messages', 'GET /api/v1/chats/conv_1/send-now'],
      'only the conversation newest page and its Send now state');
  } finally {
    (globalThis as any).fetch = prevFetch;
  }
});

test('QueuedMessages: left bubbles without time, one batch action, honest states', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT'];
  const previous = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
  try {
    const { QueuedMessages } = await import('../src/ui/components/chat/QueuedMessages.tsx');
    const root = createRoot(dom.window.document.getElementById('root')!);
    const q = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
    const all = (sel: string) => [...dom.window.document.querySelectorAll(sel)] as HTMLElement[];
    const sent: string[][] = [];
    let retried = 0;
    const els = new Map<string, HTMLElement | null>();
    const rows = [user('m2', 2, held()), user('m1', 1, held()), user('s1', 3, delivery({ status: 'sent', state: 'sent' }))];
    const render = async (batch: SendNowBatch | null, localError = '') => {
      await act(async () => root.render(React.createElement(QueuedMessages, {
        view: trayView(rows, true, batch), tooltip: 'tip', localError,
        onSendNow: (ids: string[]) => sent.push(ids), onRetry: () => { retried += 1; },
        renderBody: (m: ChatMessage) => React.createElement('p', null, m.body), bubbleRef: (k: string, el: HTMLElement | null) => els.set(k, el),
      })));
    };
    await render(null);
    assert.equal(all('time').length, 0, 'no timestamps above the composer');
    assert.equal(all('[data-debug-id="conversation-queued-send-now"]').length, 1, 'exactly one Send now');
    assert.equal(q('conversation-queued-title')!.textContent, 'After this turn');
    assert.equal(q('conversation-queued-sending-title')!.textContent, 'Sending');
    assert.ok(!dom.window.document.body.textContent!.includes('Waiting for connection'));
    assert.equal(all('[data-queued-item]').map((e) => e.getAttribute('data-queued-item')).join(), 's1,m1,m2');
    assert.ok(all('[data-queued-item]').every((li) => li.className.includes('justify-start')), 'left aligned');
    assert.ok(els.get('m1') && els.get('m1')!.hasAttribute('data-queued-bubble'), 'bubble registered as animation origin');
    const button = q('conversation-queued-send-now')!;
    assert.equal(button.getAttribute('aria-label'), 'Send all 2 waiting messages now');
    await act(async () => button.click());
    assert.deepEqual(sent, [['m1', 'm2']], 'FIFO snapshot of the waiting messages only');
    assert.match(q('conversation-queued-status')!.textContent!, /2 messages will be sent after this turn/);

    await render({ batchId: 'b', requestId: 'r', launchEpoch: 'e', attempt: 1, state: 'pending', error: '', messageIds: ['m1', 'm2'] });
    const pendingBtn = q('conversation-queued-send-now')!;
    assert.equal(pendingBtn.textContent!.trim(), 'Sending…');
    assert.ok((pendingBtn as HTMLButtonElement).disabled, 'no double submit while pending');

    await render({ batchId: 'b', requestId: 'r', launchEpoch: 'e', attempt: 1, state: 'failed', error: 'cancel_timeout', messageIds: ['m1', 'm2'] });
    assert.match(q('conversation-queued-title')!.textContent!, /Not sent yet/);
    await act(async () => q('conversation-queued-retry')!.click());
    assert.equal(retried, 1);
    assert.match(q('conversation-queued-status')!.textContent!, /Couldn't stop the current turn in time/);

    await render(null, sendNowErrorText('stale_epoch'));
    assert.match(q('conversation-queued-title')!.textContent!, /Not sent yet/);
    assert.equal(all('[data-debug-id="conversation-queued-send-now"]').length, 1, 'a new Send now is offered');
    await act(async () => root.unmount());
  } finally {
    Object.assign(globalThis, previous);
  }
});
