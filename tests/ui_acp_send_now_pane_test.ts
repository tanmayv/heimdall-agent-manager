import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import context from '../src/ui/store/composerContextSlice.ts';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { vaultCacheInvalidationMiddleware } from '../src/ui/api/vaultCacheInvalidation.ts';
import { flushQueuedInvalidations, handleUserWsEvent, resetQueuedInvalidations } from '../src/ui/api/wsInvalidation.ts';
import { AgentChatPane } from '../src/ui/components/workbench/AgentChatPane.tsx';
import { ShortcutProvider } from '../src/ui/services/shortcuts/ShortcutContext.tsx';
import { unlockVault, clearActiveKey } from './helpers/vaultEndpointHarness.ts';

// ACP batch Send now in the real Conversation pane (docs/acp-send-now.md), against a fake
// Hub: turn-held rows wait above the composer and never in the transcript; a new ACP send
// stays above the composer until the agent gets it; a delivered/read row enters the
// transcript once, with the send animation only when this mount saw it waiting; reloads
// and refetches never replay it or duplicate it; Send now posts ONE FIFO snapshot with the
// instance epoch; PTY conversations keep their transcript and get a memberless Send now.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_acp_send_now_pane_test.ts

const at = (sec: number) => new Date(Date.parse('2026-11-23T17:00:00Z') + sec * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const acp = (status: string, over: Record<string, unknown> = {}) => ({
  status, state: status === 'queued' ? 'queued' : status === 'sent' ? 'sent' : 'delivered', hold_reason: status === 'queued' ? 'turn_active' : '',
  tray_eligible: status === 'queued', mode: '', launch_epoch: 'ep1', turn_id: '', batch_id: '', error: '', delivered_at: '', agent_read_at: '', updated_at: '', ...over,
});
const userRow = (id: string, sec: number, delivery: any, extra: Record<string, unknown> = {}) => ({
  message_id: id, conversation_id: 'workerchat', direction: 'user_to_agent', body: `text ${id}`, created_at: at(sec),
  delivered_at: '', read_at: at(sec), message_type: 'text', message_status: 'complete', metadata: {}, ...(delivery ? { acp_delivery: delivery } : {}), ...extra,
});
const agentRow = (id: string, sec: number, inputIds: string[] = []) => ({
  message_id: id, conversation_id: 'workerchat', direction: 'agent_to_user', body: `reply ${id}`, created_at: at(sec), delivered_at: '', read_at: '',
  message_type: 'text', message_status: 'complete', metadata: inputIds.length ? { acp: { input_ids: inputIds } } : {}, sender_agent_instance_id: 'worker',
});

type Hub = { transport: 'acp' | 'pty'; messages: any[]; posts: Array<{ path: string; body: any }>; sendNowReply: { status: number; body: any }; gets?: string[];
  configuration?: { operations: any[]; response?: { status: number; body: any } | 'network' };
  /** /me/experiments rows; omitted keeps the flags unloaded (the old settings modal). */
  experiments?: Array<{ key: string; enabled: boolean }>;
  /** providers[].acp_availability for claude on provider-status (T6 panel); omitted = older hub. */
  acpAvailability?: any;
  /** When set, POSTs under /bridges/ (the panel's ACP fixes) are recorded here and answered 202. */
  bridgePosts?: Array<{ path: string; body: any }>;
  /** GET send-now agent_notified_at (PTY: when the bridge typed the unread notice); omitted = ''. */
  notifiedAt?: string };

async function fixture(hub: Hub, run: (ctx: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/#/conversations/worker', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  const install = (name: string, value: any) => { saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name)); Object.defineProperty(globalThis, name, { value, configurable: true, writable: true }); };
  class RO { observe() {} unobserve() {} disconnect() {} }
  const frames = new Set<ReturnType<typeof setTimeout>>();
  dom.window.requestAnimationFrame = (cb: FrameRequestCallback) => { const t = setTimeout(() => { frames.delete(t); cb(Date.now()); }, 1); frames.add(t); return t as any; };
  dom.window.cancelAnimationFrame = (id: any) => { clearTimeout(id); frames.delete(id); };
  dom.window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }) as any;
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  dom.window.HTMLElement.prototype.scrollTo = () => {};
  for (const [k, v] of Object.entries({ window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, Element: dom.window.Element,
    navigator: dom.window.navigator, localStorage: dom.window.localStorage, sessionStorage: dom.window.sessionStorage, ResizeObserver: RO,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true })) install(k, v);
  const reducers: any = { composerContext: context };
  const modules: Record<string, string> = { chat: 'chatSlice', vault: 'vaultSlice', tasks: 'taskSlice', memory: 'memorySlice', projects: 'projectSlice',
    home: 'homeSlice', chainView: 'chainViewSlice', attention: 'attentionSlice', cards: 'cardsSlice', toasts: 'toastSlice', notifications: 'notificationsSlice',
    workspaceLayout: 'workspaceLayoutSlice', auxPanes: 'auxPanesSlice', workspaceChrome: 'workspaceChromeSlice', inputPreferences: 'inputPreferencesSlice',
    searchTitle: 'searchTitleSlice', agentActivity: 'agentActivitySlice', toolActivity: 'toolActivitySlice', deviceVault: 'deviceVaultSlice', shells: 'shellSlice', theme: 'themeSlice' };
  for (const [key, file] of Object.entries(modules)) reducers[key] = (await import('../src/ui/store/' + file + '.ts')).default;
  const store = configureStore({ reducer: { ...reducers, [heimdallApi.reducerPath]: heimdallApi.reducer },
    enhancers: (g: any) => g({ autoBatch: false }),
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(vaultCacheInvalidationMiddleware, heimdallApi.middleware) });
  await unlockVault(store, '63'.repeat(32));
  const previousFetch = globalThis.fetch;
  const respond = (status: number, body: any) => ({ ok: status >= 200 && status < 300, status, headers: { get: () => 'application/json' },
    text: async () => JSON.stringify(body), json: async () => body, clone() { return respond(status, body); } }) as any;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const url = new URL(String(input), 'http://localhost'); const path = url.pathname;
    const method = String(init.method || 'GET');
    if (method === 'GET') hub.gets?.push(path);
    if (method === 'POST' && path.endsWith('/reconfigurations') && hub.configuration) {
      const body = JSON.parse(init.body);
      hub.posts.push({ path, body });
      if (hub.configuration.response === 'network') throw new TypeError('Network connection lost');
      if (hub.configuration.response) return respond(hub.configuration.response.status, hub.configuration.response.body);
      const operation = { operation_id: `operation-${hub.posts.length}`, idempotency_key: body.idempotency_key,
        phase: 'prepared', revision: 1, source: {}, destination: { ...body }, source_stopped: false, destination_committed: false };
      hub.configuration.operations = [operation];
      return respond(202, { data: operation });
    }
    if (method === 'POST' && hub.bridgePosts && path.includes('/bridges/')) {
      hub.bridgePosts.push({ path, body: init.body ? JSON.parse(init.body) : {} });
      if (!path.endsWith('/providers/discover')) return respond(202, { data: { command_id: 'cmd_1' } });
    }
    if (method === 'POST' && path.endsWith('/send-now')) { hub.posts.push({ path, body: JSON.parse(init.body) }); return respond(hub.sendNowReply.status, hub.sendNowReply.body); }
    if (method === 'POST' && path.endsWith('/messages')) {
      const body = JSON.parse(init.body);
      hub.posts.push({ path, body });
      const row = userRow('msg_new', 30, hub.transport === 'acp' ? acp('sent') : null, { body: body.body });
      hub.messages.push(row);
      return respond(201, { data: row });
    }
    let data: any = {};
    if (path.endsWith('/me/experiments') && hub.experiments) data = { experiments: hub.experiments };
    else if (path.includes('/chats/by-instance/')) data = { conversation_id: 'workerchat', agent_instance_id: 'worker', agent_id: 'worker-identity', runtime_status: 'running' };
    else if (path.endsWith('/messages')) data = [...hub.messages].reverse();
    else if (path.endsWith('/send-now')) data = { conversation_id: 'workerchat', runtime_transport: hub.transport, send_now: hub.transport === 'acp' ? 'members' : 'notice', launch_epoch: 'ep1', steering_supported: false,
      agent_notified_at: hub.notifiedAt ?? '', batch: hub.posts.some((p) => p.path.endsWith('/send-now')) ? hub.sendNowReply.body?.data?.batch ?? null : null };
    else if (/\/agent-instances\/[^/]+$/.test(path)) data = { agent_instance_id: 'worker', agent_id: 'identity', provider: 'claude', model: 'opus', bridge_id: 'b',
      runtime_status: 'running', runtime_transport: hub.transport, launch_epoch: 'ep1', configuration_revision: 7 };
    else if (path.endsWith('/reconfigurations')) data = { operations: hub.configuration?.operations || [] };
    else if (path.endsWith('/provider-status') || path.endsWith('/providers/discover')) data = { providers: [
      { provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'opus', state: 'active' }],
        ...(hub.acpAvailability ? { acp_availability: hub.acpAvailability } : {}) },
      ...(hub.configuration ? [{ provider: 'codex', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'smart', state: 'active' }] }] : []),
    ] };
    else if (path.endsWith('/bridges')) data = [{ bridge_id: 'b', status: 'online', runtime_connected: true, reconfiguration_supported: Boolean(hub.configuration) }];
    else if (path.endsWith('/agents/live') || path.endsWith('/tasks')) data = [];
    else if (path.endsWith('/attention')) data = { items: [] };
    return respond(200, { data });
  }) as any;
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  const wait = async (fn: () => boolean, label = '') => { for (let i = 0; i < 200; i++) { if (fn()) return; await act(async () => { await new Promise(r => setTimeout(r, 10)); }); } assert.ok(fn(), label); };
  const transcriptIds = () => [...dom.window.document.querySelectorAll('[data-debug-id^="conversation-thread-message-"]')]
    .map((el) => el.getAttribute('data-debug-id')!).filter((id) => /^conversation-thread-message-[^-]+$/.test(id)).map((id) => id.slice('conversation-thread-message-'.length));
  const queuedIds = () => [...dom.window.document.querySelectorAll('[data-debug-id^="conversation-queued-item-"]')].map((el) => el.getAttribute('data-debug-id')!.slice('conversation-queued-item-'.length));
  const mount = async () => act(async () => root.render(React.createElement(Provider, { store, children: React.createElement(ShortcutProvider, {
    children: React.createElement(React.StrictMode, null, React.createElement(AgentChatPane, { agentInstanceId: 'worker', paneId: 'test-pane', isMobile: false } as any)) }) })));
  const delivery = async (ids: string[]) => {
    handleUserWsEvent(store.dispatch, { type: 'chat_event', event: 'messages_delivery', conversation_id: 'workerchat', agent_instance_id: 'worker', message_ids: ids, batch_id: '', fetch_required: true });
    flushQueuedInvalidations();
  };
  resetQueuedInvalidations();
  try {
    await mount();
    await wait(() => Boolean(q('conversation-composer-card')), 'composer rendered');
    await run({ dom, store, q, wait, transcriptIds, queuedIds, delivery, root, mount });
  } finally {
    await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); await new Promise(r => setTimeout(r, 60)); });
    globalThis.fetch = previousFetch; await clearActiveKey();
    for (const frame of frames) clearTimeout(frame);
    dom.window.close(); for (const [name, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete (globalThis as any)[name]; }
  }
}

async function stageConfiguration({ q, wait }: any) {
  await wait(() => Boolean(q('conversation-runtime-menu-btn')), 'runtime settings available');
  await act(async () => q('conversation-runtime-menu-btn')!.click());
  await wait(() => Boolean(q('conversation-provider-option-codex')) && !q('conversation-provider-option-codex')!.disabled, 'provider choices loaded');
  await act(async () => q('conversation-provider-option-codex')!.click());
  await wait(() => Boolean(q('conversation-runtime-modal-apply-btn')) && !q('conversation-runtime-modal-apply-btn')!.disabled, 'staged change can apply');
}

test('AgentChatPane Apply starts a new intent after an accepted operation fails before commit', async () => {
  const hub: Hub = { transport: 'acp', messages: [], posts: [], sendNowReply: { status: 202, body: {} }, configuration: { operations: [] } };
  await fixture(hub, async (env) => {
    const { q, wait, store } = env;
    await stageConfiguration(env);
    await act(async () => q('conversation-runtime-modal-apply-btn')!.click());
    await wait(() => hub.posts.length === 1 && hub.configuration!.operations.length === 1, 'first operation accepted');
    const operation = hub.configuration!.operations[0];
    hub.configuration!.operations = [{ ...operation, phase: 'failed', revision: 2, failure_code: 'preflight_failed', failure_message: 'Preflight failed' }];
    await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'InstanceReconfigurations', id: 'worker' }])); });
    await wait(() => Boolean(q('conversation-reconfigure-apply-btn')) && !q('conversation-reconfigure-apply-btn')!.disabled, 'pre-commit failure permits applying again');
    await act(async () => q('conversation-reconfigure-apply-btn')!.click());
    await wait(() => hub.posts.length === 2, 'second attempt posted');
    const [first, second] = hub.posts.map(post => post.body);
    assert.equal(first.expected_revision, 7);
    assert.equal(second.expected_revision, 7, 'no destination commit changed the revision');
    assert.notEqual(first.idempotency_key, second.idempotency_key, 'accepted operation retires its intent key');
    assert.deepEqual({ ...first, idempotency_key: '' }, { ...second, idempotency_key: '' }, 'same destination is a new explicit attempt');
  });
});

for (const [failure, reuse] of [['network', true], [503, true], [409, false]] as const) {
  test(`AgentChatPane Apply ${failure} failure ${reuse ? 'retains uncertain' : 'retires rejected'} intent key`, async () => {
    const hub: Hub = { transport: 'acp', messages: [], posts: [], sendNowReply: { status: 202, body: {} }, configuration: { operations: [],
      response: failure === 'network' ? 'network' : { status: failure, body: { error: { code: 'conflict', message: 'Configuration request failed' } } },
    } };
    await fixture(hub, async (env) => {
      const { q, wait } = env;
      await stageConfiguration(env);
      await act(async () => q('conversation-runtime-modal-apply-btn')!.click());
      await wait(() => hub.posts.length === 1 && Boolean(q('conversation-reconfigure-apply-btn')) && !q('conversation-reconfigure-apply-btn')!.disabled, 'failed request can be explicitly retried');
      assert.equal(hub.posts.length, 1, 'no automatic retry');
      hub.configuration!.response = undefined;
      await act(async () => q('conversation-reconfigure-apply-btn')!.click());
      await wait(() => hub.posts.length === 2, 'user retry posted');
      const [first, second] = hub.posts.map(post => post.body);
      assert.equal(first.expected_revision, 7);
      assert.equal(second.expected_revision, 7);
      assert.equal(first.idempotency_key === second.idempotency_key, reuse);
    });
  });
}

test('ACP pane: turn-held rows wait above the composer; Send now posts one FIFO snapshot; delivery moves each row in once', async () => {
  const hub: Hub = { transport: 'acp', posts: [], sendNowReply: { status: 202, body: { data: { outcome: 'accepted', batch: {
    batch_id: 'b1', request_id: 'x', launch_epoch: 'ep1', attempt: 1, state: 'sent', error: '', message_ids: ['msg_m1', 'msg_m2'], excluded: [] } } } },
  messages: [
    userRow('msg_u0', 0, acp('delivered', { delivered_at: at(0), mode: 'prompt' })),
    agentRow('msg_a0', 1, ['msg_u0']),
    // read_at (bridge admission) is set on both: it must not read as Read or delivery.
    userRow('msg_m1', 2, acp('queued')),
    userRow('msg_m2', 3, acp('queued')),
    // Hub-persisted only (bridge offline or not fetched yet): Sending, no Send now.
    userRow('msg_s1', 4, acp('sent')),
  ] };
  await fixture(hub, async ({ q, wait, transcriptIds, queuedIds, delivery, dom }) => {
    await wait(() => queuedIds().length === 3, 'queued area rendered');
    assert.deepEqual(transcriptIds(), ['msg_u0', 'msg_a0']);
    assert.deepEqual(queuedIds(), ['msg_s1', 'msg_m1', 'msg_m2'], 'Sending group, then the turn-held FIFO');
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id="conversation-queued-send-now"]').length, 1);
    assert.equal(q('conversation-queued')!.querySelectorAll('time').length, 0, 'no timestamps above the composer');
    assert.ok(!dom.window.document.body.textContent!.includes('Waiting for connection'));
    assert.match(q('conversation-thread-message-msg_u0-status')?.textContent || '', /Delivered/);

    await act(async () => q('conversation-queued-send-now')!.click());
    await wait(() => hub.posts.length === 1, 'send-now posted');
    const post = hub.posts[0];
    assert.equal(post.path, '/api/v1/chats/workerchat/send-now');
    assert.equal(post.body.launch_epoch, 'ep1');
    assert.deepEqual(post.body.message_ids, ['msg_m1', 'msg_m2'], 'one FIFO snapshot, the Sending row excluded');
    assert.match(post.body.request_id, /^sn_/);
    await wait(() => (q('conversation-queued-send-now')?.textContent || '').includes('Sending'), 'pending state shown');

    // A later arrival during the batch waits separately.
    hub.messages.push(userRow('msg_m3', 6, acp('queued')));
    // The agent gets m1 (cancel + prompt) and actually reads m2 (read skips delivered).
    hub.messages[2] = userRow('msg_m1', 2, acp('delivered', { delivered_at: at(8), mode: 'prompt', batch_id: 'b1' }));
    hub.messages[3] = userRow('msg_m2', 3, acp('read', { state: 'queued', hold_reason: 'turn_active', agent_read_at: at(8), batch_id: 'b1' }));
    await delivery(['msg_m1', 'msg_m2', 'msg_m3']);
    await wait(() => transcriptIds().includes('msg_m2'), 'delivered rows entered the transcript');
    assert.deepEqual(transcriptIds(), ['msg_u0', 'msg_a0', 'msg_m1', 'msg_m2']);
    assert.deepEqual(queuedIds(), ['msg_s1', 'msg_m3']);
    assert.equal(q('conversation-thread-message-msg_m2')!.getAttribute('data-chat-pin-row'), 'true', 'the newest member plays the send animation');
    assert.match(q('conversation-thread-message-msg_m2-status')?.textContent || '', /Read/);
    assert.match(q('conversation-thread-message-msg_m1-status')?.textContent || '', /Delivered/);

    // The reply is placed after the inputs it answers; a refetch never duplicates.
    hub.messages.push(agentRow('msg_a1', 8, ['msg_m1', 'msg_m2']));
    await delivery([]);
    await wait(() => transcriptIds().includes('msg_a1'), 'reply arrives');
    assert.deepEqual(transcriptIds(), ['msg_u0', 'msg_a0', 'msg_m1', 'msg_m2', 'msg_a1']);

  });
});

test('ACP pane: a new send stays above the composer until the agent gets it, then enters once', async () => {
  const hub: Hub = { transport: 'acp', posts: [], sendNowReply: { status: 200, body: { data: { outcome: 'empty', batch: null } } },
    messages: [userRow('msg_u0', 0, acp('delivered', { delivered_at: at(0) })), agentRow('msg_a0', 1, ['msg_u0'])] };
  await fixture(hub, async ({ q, wait, transcriptIds, queuedIds, delivery }) => {
    await wait(() => transcriptIds().length === 2, 'history rendered');
    const { Simulate } = await import('react-dom/test-utils');
    await act(async () => Simulate.change(q('conversation-composer-input')!, { target: { value: 'new message' } } as any));
    await wait(() => !(q('conversation-composer-send-btn') as HTMLButtonElement)?.disabled, 'send enabled');
    await act(async () => q('conversation-composer-send-btn')!.click());
    await wait(() => hub.posts.some((p) => p.path.endsWith('/messages')), 'message posted');
    await wait(() => queuedIds().length === 1, 'the send waits above the composer');
    assert.deepEqual(transcriptIds(), ['msg_u0', 'msg_a0'], 'a Hub save is not delivery');
    assert.ok(q('conversation-queued-sending-title'), 'labelled Sending');
    assert.equal(q('conversation-queued-send-now'), null, 'not turn-held: no Send now');

    // Idle agent: dispatch_pending, then delivered.
    hub.messages[2] = { ...hub.messages[2], acp_delivery: acp('sent', { state: 'queued', hold_reason: 'dispatch_pending' }) };
    await delivery(['msg_new']);
    await act(async () => { await new Promise(r => setTimeout(r, 40)); });
    assert.equal(queuedIds().length, 1, 'dispatch_pending still waits, and is not turn-held');
    assert.equal(q('conversation-queued-send-now'), null);
    hub.messages[2] = { ...hub.messages[2], acp_delivery: acp('delivered', { delivered_at: at(31), mode: 'prompt' }) };
    await delivery(['msg_new']);
    await wait(() => transcriptIds().includes('msg_new'), 'delivered send enters the transcript');
    assert.equal(queuedIds().length, 0);
    assert.equal(transcriptIds().filter((id) => id === 'msg_new').length, 1, 'exactly once');
    const row = q('conversation-thread-message-msg_new')!;
    assert.equal(row.getAttribute('data-chat-pin-row'), 'true', 'send animation from the waiting bubble');
  });
});

test('ACP pane: a reload shows delivered history in place and never replays the animation', async () => {
  const hub: Hub = { transport: 'acp', posts: [], sendNowReply: { status: 200, body: {} }, messages: [
    userRow('msg_u0', 0, acp('delivered', { delivered_at: at(0) })), agentRow('msg_a0', 1),
    userRow('msg_m1', 2, acp('read', { agent_read_at: at(5) })), agentRow('msg_a1', 5, ['msg_m1']),
  ] };
  await fixture(hub, async ({ q, wait, transcriptIds, queuedIds }) => {
    await wait(() => transcriptIds().length === 4, 'history rendered');
    assert.deepEqual(transcriptIds(), ['msg_u0', 'msg_a0', 'msg_m1', 'msg_a1']);
    assert.equal(queuedIds().length, 0);
    assert.equal(q('conversation-queued'), null);
    assert.equal(q('conversation-thread-message-msg_m1')!.getAttribute('data-chat-pin-row'), null, 'no animation on load');
  });
});

test('PTY pane: transcript unchanged; Send now asks the agent to read its unread messages (no members)', async () => {
  const hub: Hub = { transport: 'pty', posts: [], sendNowReply: { status: 200, body: { data: { outcome: 'delivered', batch: {
    batch_id: 'b1', request_id: 'x', launch_epoch: 'ep1', attempt: 1, state: 'delivered', error: '', message_ids: [], excluded: [] } } } },
    messages: [userRow('msg_p0', 0, null), agentRow('msg_pa', 1), userRow('msg_p1', 2, null, { read_at: '' }), userRow('msg_p2', 3, null, { read_at: '' })],
  };
  await fixture(hub, async ({ q, wait, transcriptIds, queuedIds }) => {
    await wait(() => transcriptIds().length === 4, 'history rendered');
    assert.equal(queuedIds().length, 0, 'unread PTY rows stay in the transcript');
    assert.match(q('conversation-thread-message-msg_p0-status')?.textContent || '', /Read/, 'legacy read_at semantics kept');
    await wait(() => Boolean(q('conversation-queued-send-now')), 'Send now offered by the runtime capability');
    assert.match(q('conversation-queued-title')!.textContent || '', /Waiting for the current turn/, 'never notified yet');
    assert.match(q('conversation-queued-status')!.textContent || '', /2 messages waiting for the current turn/);
    await act(async () => q('conversation-queued-send-now')!.click());
    await wait(() => hub.posts.some((p) => p.path.endsWith('/send-now')), 'send-now posted');
    const post = hub.posts.find((p) => p.path.endsWith('/send-now'))!;
    assert.deepEqual(post.body.message_ids, [], 'no members for a notice runtime');
    assert.equal(post.body.launch_epoch, 'ep1');
    assert.ok(post.body.request_id, 'one request id per click');
  });
});

test('PTY pane: unread tray goes from waiting to notified (Interrupt) when the bridge typed the notice, and leaves once read', async () => {
  const hub: Hub = { transport: 'pty', posts: [], sendNowReply: { status: 200, body: { data: { outcome: 'delivered', batch: {
    batch_id: 'b1', request_id: 'x', launch_epoch: 'ep1', attempt: 1, state: 'delivered', error: '', message_ids: [], excluded: [] } } } },
    messages: [userRow('msg_p0', 0, null), agentRow('msg_pa', 1), userRow('msg_p1', 2, null, { read_at: '' }), userRow('msg_p2', 3, null, { read_at: '' })],
    notifiedAt: at(2), // the notice was typed for msg_p1 only
  };
  await fixture(hub, async ({ q, wait, delivery }) => {
    const state = () => q('conversation-unread')?.getAttribute('data-unread-state') ?? '';
    await wait(() => state() === 'waiting', 'msg_p2 is newer than the last notice');
    assert.match(q('conversation-queued-title')!.textContent || '', /Waiting for the current turn/);
    assert.ok(q('conversation-queued-send-now'), 'Send now while waiting');
    assert.equal(q('conversation-queued-interrupt'), null);
    // The bridge typed the notice for both (agent_notice_typed): messages_delivery refetches send-now.
    hub.notifiedAt = at(3);
    await delivery([]);
    await wait(() => state() === 'notified', 'notified after the typed notice');
    assert.match(q('conversation-queued-title')!.textContent || '', /Agent notified, not read yet/);
    assert.match(q('conversation-queued-status')!.textContent || '', /Agent notified, 2 messages not read yet/);
    assert.equal(q('conversation-queued-send-now'), null, 'no Send now once notified');
    const interrupt = q('conversation-queued-interrupt')!;
    assert.equal(interrupt.textContent, 'Interrupt');
    assert.equal(interrupt.getAttribute('aria-label'), "Interrupt the agent's current turn so it reads now");
    assert.equal(interrupt.getAttribute('title'), "Interrupt the agent's current turn so it reads now");
    // Interrupt is the same memberless Send now.
    await act(async () => interrupt.click());
    await wait(() => hub.posts.some((p) => p.path.endsWith('/send-now')), 'send-now posted');
    const post = hub.posts.find((p) => p.path.endsWith('/send-now'))!;
    assert.deepEqual(post.body.message_ids, []);
    assert.equal(post.body.launch_epoch, 'ep1');
    // The agent read them: they leave the tray as before.
    for (const m of hub.messages) if (m.direction === 'user_to_agent') m.read_at = at(4);
    await delivery([]);
    await wait(() => q('conversation-unread') === null, 'tray gone once read');
  });
});

test('ACP pane: a failed batch says so and Retry reuses its request_id for the members still waiting', async () => {
  const failedBatch = (requestId: string) => ({ batch_id: 'b9', request_id: requestId, launch_epoch: 'ep1', attempt: 1, state: 'failed',
    error: 'bridge_offline', message_ids: ['msg_m1', 'msg_m2'], excluded: [] });
  const hub: Hub = { transport: 'acp', posts: [], sendNowReply: { status: 503, body: null }, messages: [
    userRow('msg_m1', 2, acp('queued')), userRow('msg_m2', 3, acp('queued')),
  ] };
  await fixture(hub, async ({ q, wait, queuedIds }) => {
    await wait(() => queuedIds().length === 2, 'queued');
    // The fake Hub answers with the failed batch for whatever request_id it is given.
    const origPush = hub.posts.push.bind(hub.posts);
    hub.posts.push = (...items: any[]) => { for (const it of items) if (it.path.endsWith('/send-now')) hub.sendNowReply = { status: 503, body: { data: { outcome: 'failed', batch: failedBatch(it.body.request_id) } } }; return origPush(...items); };
    await act(async () => q('conversation-queued-send-now')!.click());
    await wait(() => Boolean(q('conversation-queued-retry')), 'Retry offered');
    await act(async () => { await new Promise(r => setTimeout(r, 60)); });
    assert.ok(q('conversation-queued-retry'), 'still offered after the Send now state refetch');
    assert.match(q('conversation-queued-title')!.textContent || '', /Not sent yet/);
    assert.match(q('conversation-queued-status')!.textContent || '', /bridge is offline\. Still waiting/);
    assert.deepEqual(queuedIds(), ['msg_m1', 'msg_m2'], 'nothing moved into the chat');
    await act(async () => q('conversation-queued-retry')!.click());
    await wait(() => hub.posts.length === 2, 'retry posted');
    assert.equal(hub.posts[1].body.request_id, hub.posts[0].body.request_id, 'same request_id');
    assert.deepEqual(hub.posts[1].body.message_ids, ['msg_m1', 'msg_m2']);
  });
});

// Agent settings panel (agent_settings_panel experiment): the gear and the composer
// settings chip open the panel (a drawer at jsdom's 1024px) instead of the modal, the
// Runtime card shows this instance, and the staged-changes footer applies the draft.
test('Agent settings panel: flag on opens the panel from the gear and the composer chip; flag off keeps the modal', async () => {
  const hub: Hub = { transport: 'pty', messages: [], posts: [], sendNowReply: { status: 202, body: {} }, configuration: { operations: [] },
    experiments: [{ key: 'agent_settings_panel', enabled: true }] };
  await fixture(hub, async ({ q, wait, dom }) => {
    await wait(() => Boolean(q('conversation-agent-settings-btn')), 'gear rendered');
    const gear = q('conversation-agent-settings-btn')!;
    assert.equal(gear.getAttribute('aria-label'), 'Agent settings');
    assert.equal(gear.getAttribute('aria-expanded'), 'false');
    await act(async () => gear.click());
    await wait(() => Boolean(q('agent-panel-runtime')), 'panel with runtime section');
    assert.equal(q('agent-panel')!.getAttribute('data-mode'), 'drawer');
    assert.equal(q('conversation-runtime-modal'), null, 'no modal');
    assert.equal(gear.getAttribute('aria-expanded'), 'true');
    assert.equal(q('agent-panel-runtime-status')!.textContent, 'Running');
    assert.equal(q('agent-panel-runtime-provider')!.textContent, 'Claude Code');
    assert.equal(q('agent-panel-runtime-model')!.textContent, 'opus');
    assert.equal(q('agent-panel-runtime-transport')!.textContent, 'PTY');
    await act(async () => { dom.window.document.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    await wait(() => !q('agent-panel'), 'Esc closes the drawer');

    await act(async () => q('conversation-runtime-menu-btn')!.click());
    await wait(() => Boolean(q('agent-panel')), 'composer chip opens the panel');
    assert.equal(q('conversation-runtime-modal'), null);
    // T6: the Model section's provider radiogroup edits the draft (nothing applies on click).
    await wait(() => q('agent-panel-model-provider-codex')?.getAttribute('aria-disabled') !== 'true' && Boolean(q('agent-panel-model-provider-codex')), 'Model section loaded');
    await act(async () => q('agent-panel-model-provider-codex')!.click());
    assert.equal(q('agent-panel-model-provider-codex')!.getAttribute('aria-checked'), 'true');
    assert.equal(hub.posts.length, 0, 'picking a provider posts nothing');
    await wait(() => Boolean(q('agent-panel-apply-btn')) && !(q('agent-panel-apply-btn') as HTMLButtonElement).disabled, 'staged change can apply');
    await act(async () => q('agent-panel-apply-btn')!.click());
    await wait(() => hub.posts.length === 1, 'reconfiguration posted');
    assert.equal(hub.posts[0].body.provider, 'codex');
    assert.equal(hub.posts[0].body.expected_revision, 7);
    assert.ok(q('agent-panel'), 'the panel stays open to watch the restart');
  });

  const off: Hub = { transport: 'pty', messages: [], posts: [], sendNowReply: { status: 202, body: {} },
    experiments: [{ key: 'agent_settings_panel', enabled: false }] };
  await fixture(off, async ({ q, wait }) => {
    await wait(() => Boolean(q('conversation-runtime-menu-btn')), 'composer rendered');
    assert.equal(q('conversation-agent-settings-btn'), null, 'no gear with the flag off');
    await act(async () => q('conversation-runtime-menu-btn')!.click());
    await wait(() => Boolean(q('conversation-runtime-modal')), 'old modal opens');
    assert.equal(q('agent-panel'), null);
  });
});

test('Agent settings panel draft: connection and bypass stage, ACP gate blocks Apply, Apply sends the full destination', async () => {
  const hub: Hub = { transport: 'pty', messages: [], posts: [], sendNowReply: { status: 202, body: {} }, configuration: { operations: [] },
    experiments: [{ key: 'agent_settings_panel', enabled: true }],
    acpAvailability: { available: false, reason: 'adapter_missing', fix: 'install_adapter' } };
  await fixture(hub, async ({ q, wait }) => {
    await wait(() => Boolean(q('conversation-agent-settings-btn')), 'gear rendered');
    await act(async () => q('conversation-agent-settings-btn')!.click());
    for (const id of ['agent-panel-bridge', 'agent-panel-model', 'agent-panel-connection', 'agent-panel-permissions']) {
      await wait(() => Boolean(q(id)), `${id} rendered`);
    }
    await wait(() => Boolean(q('agent-panel-model-provider-claude')), 'provider rows loaded');
    assert.equal(q('agent-panel-apply-btn'), null, 'no staged change, no Apply');

    await act(async () => q('agent-panel-connection-acp')!.click());
    assert.equal(q('agent-panel-connection-acp')!.getAttribute('aria-checked'), 'true');
    await wait(() => Boolean(q('agent-panel-connection-acp-alert')), 'ACP alert');
    assert.equal(q('agent-panel-connection-acp-alert')!.getAttribute('role'), 'alert');
    assert.match(q('agent-panel-connection-acp-alert')!.textContent || '', /ACP adapter isn't installed on b\./);
    assert.ok(q('agent-panel-connection-fix-install_adapter'), 'Install adapter action from fix');
    assert.equal(q('agent-panel-apply-blocked')!.textContent, 'Fix the connection above before applying.');
    assert.equal((q('agent-panel-apply-btn') as HTMLButtonElement).disabled, true);
    assert.equal(q('conversation-reconfigure-apply-btn'), null, 'the open panel owns Apply: no second Apply in the composer');

    await act(async () => q('agent-panel-connection-pty')!.click());
    assert.equal(q('agent-panel-connection-acp-alert'), null);
    await act(async () => q('agent-panel-permissions-toggle')!.click());
    assert.equal(q('agent-panel-permissions-toggle')!.getAttribute('aria-checked'), 'false');
    assert.equal(hub.posts.length, 0, 'nothing applies on click');
    await wait(() => Boolean(q('agent-panel-apply-btn')) && !(q('agent-panel-apply-btn') as HTMLButtonElement).disabled, 'bypass change can apply');
    await act(async () => q('agent-panel-apply-btn')!.click());
    await wait(() => hub.posts.length === 1, 'reconfiguration posted');
    assert.equal(hub.posts[0].body.permission_mode, 'ask');
    assert.equal(hub.posts[0].body.runtime_transport, 'pty', 'the full destination is always sent');
    assert.equal(hub.posts[0].body.provider, 'claude');
    assert.equal(hub.posts[0].body.model, 'opus');
    assert.equal(hub.posts[0].body.apply, 'now');
    assert.ok('project_id' in hub.posts[0].body, 'project_id is always resent');
  });

  const ready: Hub = { transport: 'pty', messages: [], posts: [], sendNowReply: { status: 202, body: {} }, configuration: { operations: [] },
    experiments: [{ key: 'agent_settings_panel', enabled: true }], acpAvailability: { available: true, reason: 'ready', fix: null } };
  await fixture(ready, async ({ q, wait }) => {
    await wait(() => Boolean(q('conversation-agent-settings-btn')), 'gear rendered');
    await act(async () => q('conversation-agent-settings-btn')!.click());
    await wait(() => Boolean(q('agent-panel-model-provider-claude')), 'provider rows loaded');
    await act(async () => q('agent-panel-connection-acp')!.click());
    assert.equal(q('agent-panel-connection-acp-alert'), null, 'ready: no alert');
    await wait(() => Boolean(q('agent-panel-apply-btn')) && !(q('agent-panel-apply-btn') as HTMLButtonElement).disabled, 'ACP change can apply');
    await act(async () => q('agent-panel-apply-btn')!.click());
    await wait(() => ready.posts.length === 1, 'reconfiguration posted');
    assert.equal(ready.posts[0].body.runtime_transport, 'acp');
    assert.equal(ready.posts[0].body.permission_mode, 'yolo', 'unchanged bypass is resent');
  });
});

test('Agent settings panel: each ACP fix calls its existing endpoint on the draft bridge', async () => {
  const cases = [
    { availability: { available: false, reason: 'unsupported_bridge', fix: 'update_bridge' }, button: 'agent-panel-connection-fix-update_bridge',
      path: '/bridges/b/update', body: {} },
    { availability: { available: false, reason: 'adapter_missing', fix: 'install_adapter' }, button: 'agent-panel-connection-fix-install_adapter',
      path: '/bridges/b/providers/claude/acp-adapter', body: { action: 'install' } },
    // Provider discovery is the stage that records the adapter state acp_availability reads.
    { availability: { available: false, reason: 'not_checked', fix: 'check_now' }, button: 'agent-panel-connection-fix-check_now',
      path: '/bridges/b/providers/discover', body: { stage: 'providers' } },
  ];
  for (const c of cases) {
    const hub: Hub = { transport: 'pty', messages: [], posts: [], sendNowReply: { status: 202, body: {} }, configuration: { operations: [] },
      experiments: [{ key: 'agent_settings_panel', enabled: true }], acpAvailability: c.availability, bridgePosts: [] };
    await fixture(hub, async ({ q, wait }) => {
      await wait(() => Boolean(q('conversation-agent-settings-btn')), 'gear rendered');
      await act(async () => q('conversation-agent-settings-btn')!.click());
      await wait(() => Boolean(q('agent-panel-model-provider-claude')), 'provider rows loaded');
      await act(async () => q('agent-panel-connection-acp')!.click());
      await wait(() => Boolean(q(c.button)), `${c.availability.reason}: fix button`);
      await act(async () => q(c.button)!.click());
      await wait(() => hub.bridgePosts!.length > 0, `${c.availability.reason}: fix request sent`);
      assert.deepEqual(hub.bridgePosts!.map((p) => p.path.replace(/^\/api\/v1/, '')), [c.path], `${c.availability.reason}: one request, existing endpoint`);
      assert.deepEqual(hub.bridgePosts![0].body, c.body, `${c.availability.reason}: request body`);
      assert.equal(hub.posts.length, 0, 'a fix never reconfigures the instance');
    });
  }
});
