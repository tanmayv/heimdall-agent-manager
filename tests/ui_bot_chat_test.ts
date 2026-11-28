// REQ-WEB-4 / REQ-WEB-5: Bot sidebar entry and bot chat view.
// Run: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bot_chat_test.ts
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { configureStore } from '@reduxjs/toolkit';
import { FakeToolSocket, snapshot } from './helpers/toolStreamHarness.ts';
import toolActivity from '../src/ui/store/toolActivitySlice.ts';

// react-dom decides once, at import, whether a DOM exists; without one it ignores
// `input` events and controlled textareas never see typing. Install a DOM first.
const baseDom = new JSDOM('<!doctype html>', { url: 'https://hub.test/' });
for (const [key, value] of Object.entries({ window: baseDom.window, document: baseDom.window.document, navigator: baseDom.window.navigator })) {
  Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
}
const { default: React, act } = await import('react');
const { createRoot } = await import('react-dom/client');
const { Provider } = await import('react-redux');

const model = await import('../src/ui/components/bots/botChatModel.ts');
const { SidebarBot, BOT_CHAT_ROUTE } = await import('../src/ui/components/shell/SidebarBot.tsx');
const { default: BotChatPage } = await import('../src/ui/components/bots/BotChatPage.tsx');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { handleUserWsEvent, resyncAfterReconnect } = await import('../src/ui/api/wsInvalidation.ts');
const { default: vault } = await import('../src/ui/store/vaultSlice.ts');
const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');

type Msg = { message_id: string; binding_id: string; provider: 'telegram' | 'whatsapp' | 'web'; direction: string; body: string;
  metadata?: { action_ids: string[] }; attachments?: any[]; body_purged: boolean; send_state: string; created_at: string; read_at: string; replied_at: string };

function bot(overrides: Record<string, unknown> = {}) {
  return { bot_id: 'bot_a', display_name: 'Ninjy bot', status: 'ready', status_detail: '',
    telegram: { configured: true, bot_username: 'ninjy_test', binding: { state: 'active', display: '@alice', connected_at: '2026-11-18' } },
    whatsapp: { configured: true, phone_display: '15550100001', binding: null, window_open: false, reengage_sent: false, reengage_error: '', held_replies: [] },
    placement_revision: 3,
    advanced: { agent_instance_id: 'inst_bot', bridge_id: 'brg_a', bridge_label: 'Laptop', provider: 'claude', model: 'opus', runtime_status: 'idle' },
    ...overrides };
}
function msg(n: number, over: Partial<Msg> = {}): Msg {
  const t = `2026-11-20T08:${String(Math.floor(n / 60)).padStart(2, '0')}:${String(n % 60).padStart(2, '0')}Z`;
  return { message_id: 'bmsg_' + String(n).padStart(4, '0'), binding_id: 'bnd', provider: 'telegram', direction: n % 2 ? 'outbound' : 'inbound',
    body: 'message ' + n, body_purged: false, send_state: 'sent', created_at: t, read_at: t, replied_at: n % 2 ? '' : t, ...over };
}

/** In-memory hub: descending keyset pages, web intake, experiment and bot state. */
function hub(initial: Msg[] = []) {
  return {
    enabled: true as boolean,
    bot: bot() as any,
    rollout: { enabled: false, generation: 0, agent_instance_id: '', conversation_id: '', bot_id: '' },
    messages: [...initial],
    cards: new Map<string, string>(),
    sendStatus: 0,
    uploadStatus: 0,
    uploads: [] as any[],
    holdSend: null as null | { release: () => void },
    page(limit: number, cursor: string) {
      const desc = [...this.messages].sort((a, b) => model.compareBotMessages(b as any, a as any));
      let start = 0;
      if (cursor) {
        start = desc.findIndex((m) => m.message_id === cursor) + 1;
        if (start === 0) return null;
      }
      const slice = desc.slice(start, start + limit);
      const more = start + limit < desc.length;
      return { messages: slice, next_cursor: more ? slice[slice.length - 1].message_id : '' };
    },
  };
}

async function fixture(state: ReturnType<typeof hub>, view: 'sidebar' | 'chat', run: (h: any) => Promise<void>, width = 1280) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  Object.defineProperty(dom.window, 'innerWidth', { value: width, configurable: true });
  const sockets: FakeToolSocket[] = [];
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node,
    FileReader: dom.window.FileReader, navigator: dom.window.navigator, requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true,
    // The shared composer and list size themselves with ResizeObserver; jsdom has none.
    WebSocket: class extends FakeToolSocket { constructor(url: string) { super(url); sockets.push(this); } },
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} } })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  }
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options: any) { this.scrollTop = typeof options === 'object' ? options.top ?? 0 : 0; };
  const previousFetch = globalThis.fetch;
  const requests: { path: string; search: string; method: string; body?: any }[] = [];
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const url = new URL(String(input), 'https://hub.test');
    const path = url.pathname.replace('/api/v1', '');
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    requests.push({ path, search: url.search, method, body });
    if (path === '/artifacts' && method === 'POST') {
      if (state.uploadStatus) return Response.json({ error: { message: 'Upload unavailable' } }, { status: state.uploadStatus });
      const artifact = { artifact_id: 'art_upload_' + state.uploads.length, name: body.name, kind: body.kind, mime: body.mime };
      state.uploads.push(artifact);
      return Response.json({ data: artifact }, { status: 201 });
    }
    if (path.startsWith('/artifacts/')) {
      const artifact = state.uploads.find(a => path === '/artifacts/' + a.artifact_id);
      return Response.json({ data: artifact ?? { artifact_id: path.split('/').pop(), name: 'existing.txt', kind: 'file', mime: 'application/pdf' } });
    }
    const [, cardId, operation] = path.match(/^\/cards\/([^/]+)(?:\/(accept|discard))?$/) ?? [];
    if (cardId) {
      if (!state.cards.has(cardId)) return Response.json({ error: { message: 'Card unavailable' } }, { status: 404 });
      if (operation) state.cards.set(cardId, operation === 'accept' ? 'accepted' : 'discarded');
      return Response.json({ data: { card_id: cardId, status: state.cards.get(cardId), title: 'Confirm change', operations: [] } });
    }
    if (path === '/me/experiments') return Response.json({ data: { experiments: [{ key: 'bots', enabled: state.enabled }] } });
    if (!state.enabled && path.startsWith('/bots/')) return Response.json({ error: { code: 'forbidden', message: 'Experiment off' } }, { status: 403 });
    if (path === '/bots/me') return state.bot ? Response.json({ data: state.bot }) : Response.json({ error: { code: 'not_found', message: 'No bot' } }, { status: 404 });
    if (path === '/bots/me/web-conversation') {
      if (method === 'PUT') {
        if (body.expected_generation !== state.rollout.generation) return Response.json({ error: { message: 'Stale activation' } }, { status: 409 });
        state.rollout = { enabled: body.enabled, generation: state.rollout.generation + 1,
          agent_instance_id: 'inst_fresh_bot', conversation_id: 'chat_fresh_bot', bot_id: 'bot_a' };
      }
      return Response.json({ data: state.rollout });
    }
    if (path === '/bots/me/messages') {
      const ids = url.searchParams.get('message_ids');
      if (ids) {
        const requested = new Set<string>(JSON.parse(ids));
        return Response.json({ data: { messages: state.messages.filter(message => requested.has(message.message_id)), next_cursor: '' } });
      }
      const page = state.page(Number(url.searchParams.get('limit') || 50), url.searchParams.get('cursor') || '');
      return page ? Response.json({ data: page }) : Response.json({ error: { code: 'bad_request', message: 'Bad cursor' } }, { status: 400 });
    }
    if (path === '/bots/me/channels/web/messages' && method === 'POST') {
      await new Promise<void>((resolve) => { if (state.holdSend) state.holdSend.release = resolve; else resolve(); });
      if (state.sendStatus) return Response.json({ error: { code: 'unavailable', message: 'Hub unavailable' } }, { status: state.sendStatus });
      const existing = state.messages.find((m) => m.binding_id === 'web:' + body.idempotency_key);
      if (existing) return Response.json({ data: { message_id: existing.message_id, created: false } });
      const id = 'bmsg_web_' + state.messages.length;
      state.messages.push(msg(9000, { message_id: id, binding_id: 'web:' + body.idempotency_key, provider: 'web', direction: 'inbound', body: body.text, attachments: (body.artifact_ids ?? []).map((id: string) => ({ attachment_id: id, artifact_id: id, state: 'stored' })), read_at: '', replied_at: '', created_at: '2026-11-20T09:30:00Z' }));
      return Response.json({ data: { message_id: id, created: true } }, { status: 201 });
    }
    throw new Error('Unexpected request: ' + method + ' ' + path);
  }) as typeof fetch;
  const store = configureStore({ reducer: { auxPanes, vault, toolActivity, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (g) => g({ serializableCheck: false }).concat(heimdallApi.middleware), enhancers: (g) => g({ autoBatch: false }) });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const doc = dom.window.document;
  const settle = async () => { await act(async () => { await new Promise((r) => setTimeout(r, 25)); }); };
  const get = (id: string) => doc.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  const all = (sel: string) => [...doc.querySelectorAll(sel)] as HTMLElement[];
  const click = async (id: string) => { const el = get(id); assert.ok(el, id); await act(async () => el!.click()); await settle(); };
  const type = async (value: string) => {
    const input = get('bot-chat-input') as HTMLTextAreaElement;
    assert.ok(input, 'composer input');
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, 'value')!.set!;
    await act(async () => { setter.call(input, value); input.dispatchEvent(new dom.window.Event('input', { bubbles: true })); });
  };
  // Rows of the shared ChatMessageList (debugPrefix bot-chat): user rows are right-aligned.
  const rows = () => all('[data-debug-id="bot-chat-messages-container"] > .msg').map((row) => ({
    id: row.getAttribute('data-debug-id'), who: row.classList.contains('justify-end') ? 'user' : 'bot', text: row.querySelector('[data-chat-body]')?.textContent?.trim(),
    channel: row.querySelector('[data-debug-id="bot-chat-channel"]')?.textContent,
    state: (row.querySelector('[data-debug-id$="-status"]') ?? row.querySelector('[data-debug-id="bot-chat-message-state"]'))?.textContent ?? '' }));
  const element = view === 'sidebar'
    ? React.createElement(SidebarBot, { currentPath: '/home' })
    : React.createElement(BotChatPage);
  try {
    await act(async () => root.render(React.createElement(Provider, { store, children: element })));
    await settle(); await settle();
    await run({ dom, doc, store, requests, get, all, click, settle, type, rows, sockets });
  } finally {
    state.holdSend?.release?.();
    await act(async () => root.unmount());
    assert.ok(sockets.every(socket => socket.readyState === 3));
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
    dom.window.close();
    for (const [key, value] of saved) { if (value) Object.defineProperty(globalThis, key, value); else delete (globalThis as any)[key]; }
  }
}

// --- model -------------------------------------------------------------------

test('model: merge keeps rows a refreshed head pushed out and orders oldest first', () => {
  const empty = new Map();
  const first = model.mergeBotMessages(empty, [msg(3), msg(2)] as any);
  assert.notEqual(first, empty);
  assert.equal(model.mergeBotMessages(first, [msg(3)] as any), first, 'unchanged rows keep identity');
  const refreshed = model.mergeBotMessages(first, [msg(4), msg(3, { read_at: 'later' })] as any);
  assert.deepEqual(model.botTimeline(refreshed).map((m) => m.message_id), ['bmsg_0002', 'bmsg_0003', 'bmsg_0004']);
  assert.equal(refreshed.get('bmsg_0003')!.read_at, 'later');
  assert.equal(model.mergeBotMessages(refreshed, [msg(3, { read_at: '' })] as any), refreshed,
    'a delayed unread snapshot preserves the read timestamp and row identity');
  const tie = model.botTimeline(model.mergeBotMessages(empty, [msg(1, { message_id: 'b' }), msg(1, { message_id: 'a' })] as any));
  assert.deepEqual(tie.map((m) => m.message_id), ['a', 'b'], 'equal timestamps order by message id like the hub');
});

test('model: status, channels, composer checks, pending and queue notices', () => {
  assert.equal(model.isBotRunning('ready'), true);
  assert.equal(model.isBotRunning('starting'), true);
  assert.equal(model.isBotRunning('sleeping'), false);
  assert.equal(model.isBotRunning('waiting_for_machine'), false);
  assert.deepEqual(model.connectedBotChannels(bot() as any), ['Web', 'Telegram']);
  assert.deepEqual(model.connectedBotChannels(bot({ telegram: { binding: { state: 'revoked' } }, whatsapp: { binding: { state: 'active' } } }) as any), ['Web', 'WhatsApp']);
  assert.equal(model.checkBotComposerText('  \n'), 'empty');
  assert.equal(model.checkBotComposerText('hi'), null);
  assert.equal(model.checkBotComposerText('é'.repeat(8192)), null, '16384 bytes is allowed');
  assert.equal(model.checkBotComposerText('é'.repeat(8193)), 'too_long', 'limit is UTF-8 bytes, not characters');
  const a = model.newIdempotencyKey();
  assert.notEqual(a, model.newIdempotencyKey());
  assert.ok(a.length <= 200);
  const known = new Map([['bmsg_1', msg(1) as any]]);
  const pending = [{ key: 'k1', text: 'x', state: 'sent', message_id: 'bmsg_1', error: '' }, { key: 'k2', text: 'y', state: 'sending', message_id: '', error: '' }] as const;
  assert.deepEqual(model.visiblePendingSends(pending as any, known).map((p) => p.key), ['k2']);
  assert.equal(model.awaitingBotReply([], pending as any), true);
  assert.equal(model.awaitingBotReply([msg(2) as any], []), false, 'inbound already replied');
  assert.equal(model.awaitingBotReply([msg(2, { replied_at: '' }) as any], []), true);
  assert.equal(model.awaitingBotReply([msg(1) as any], [{ key: 'f', text: 'z', state: 'failed', message_id: '', error: 'x' }]), false);
  assert.match(model.botQueueNotice('starting', true)!.text, /queued/);
  assert.match(model.botQueueNotice('waiting_for_machine', false)!.text, /saved/);
  assert.equal(model.botQueueNotice('ready', true), null);
  assert.equal(model.botQueueNotice('sleeping', false), null);
  assert.match(model.botChatErrorText(403, 'x'), /not enabled/);
  assert.match(model.botChatErrorText(404, 'x'), /don't have a bot/);
  assert.equal(model.botChatErrorText(503, 'Hub unavailable'), 'Hub unavailable');
});

// --- sidebar gating ---------------------------------------------------------

test('sidebar: experiment off renders nothing and never requests the bot', async () => {
  const state = hub();
  state.enabled = false;
  await fixture(state, 'sidebar', async (h) => {
    assert.equal(h.get('sidebar-bot'), null);
    assert.equal(h.requests.filter((r: any) => r.path.startsWith('/bots')).length, 0);
  });
});

test('sidebar: an eligible owner can find the fresh bot opt-in without a legacy bot', async () => {
  const state = hub();
  state.bot = null;
  await fixture(state, 'sidebar', async (h) => { assert.equal(h.get('sidebar-bot-name')!.textContent, 'Bot'); });
});

test('sidebar: shows display name and bridge/provider placement with accessible running state, and opens the chat', async () => {
  const state = hub();
  await fixture(state, 'sidebar', async (h) => {
    assert.equal(h.get('sidebar-bot-name')!.textContent, 'Ninjy bot');
    assert.match(h.get('sidebar-bot-status')!.textContent!, /Running on/);
    assert.equal(h.get('sidebar-bot-placement')!.textContent, 'Laptop · Claude Code');
    assert.equal(h.get('sidebar-bot-status')!.querySelector('[role="img"]')!.getAttribute('aria-label'), 'Ready');
    const row = h.get('sidebar-bot-row') as HTMLAnchorElement;
    assert.equal(row.getAttribute('href'), '#' + BOT_CHAT_ROUTE);
    await h.click('sidebar-bot-row');
    assert.equal(h.dom.window.location.hash, '#/bot');
  });
  state.bot = bot({ status: 'sleeping', telegram: { configured: true, bot_username: '', binding: null } });
  await fixture(state, 'sidebar', async (h) => {
    assert.match(h.get('sidebar-bot-status')!.textContent!, /Stopped/);
    assert.equal(h.get('sidebar-bot-placement')!.textContent, 'Laptop · Claude Code');
  });
});

// --- chat view ----------------------------------------------------------------

test('chat: experiment off shows a clear notice and fetches no bot data', async () => {
  const state = hub();
  state.enabled = false;
  await fixture(state, 'chat', async (h) => {
    assert.match(h.get('bot-chat-disabled')!.textContent!, /not enabled/);
    assert.equal(h.requests.filter((r: any) => r.path.startsWith('/bots')).length, 0);
  });
});

test('chat: eligible owner without a legacy bot explicitly opts into an empty shared conversation', async () => {
  const state = hub();
  state.bot = null;
  await fixture(state, 'chat', async (h) => {
    assert.match(h.get('bot-web-activation')!.textContent!, /starts empty.*paired again/);
    assert.equal(h.requests.some((r: any) => r.method === 'PUT'), false);
    await h.click('bot-web-activate');
    assert.equal(h.dom.window.location.hash, '#/conversations/inst_fresh_bot');
    assert.deepEqual(h.requests.find((r: any) => r.method === 'PUT').body, { enabled: true, expected_generation: 0 });
    assert.equal(h.requests.some((r: any) => r.path.includes('/channels/web/messages')), false);
  });
});

test('chat: paused owner resumes the pinned conversation without reading or sending legacy history', async () => {
  const state = hub([msg(1)]);
  state.rollout = { enabled: false, generation: 2, agent_instance_id: 'inst_fresh_bot', conversation_id: 'chat_fresh_bot', bot_id: 'bot_a' };
  await fixture(state, 'chat', async (h) => {
    assert.match(h.get('bot-web-activation')!.textContent!, /messages are kept/);
    assert.equal(h.get('bot-chat-input'), null);
    await h.click('bot-web-activate');
    assert.equal(h.dom.window.location.hash, '#/conversations/inst_fresh_bot');
    assert.deepEqual(h.requests.find((r: any) => r.method === 'PUT').body, { enabled: true, expected_generation: 2 });
    assert.equal(h.requests.some((r: any) => r.path === '/bots/me/messages'), false);
  });
});

test('chat: unified history renders channel labels oldest-first and pages older messages', async () => {
  const state = hub(Array.from({ length: 120 }, (_, i) => msg(i + 1, { provider: (['telegram', 'whatsapp', 'web'] as const)[i % 3], ...(i === 1 || i === 21 ? { read_at: '', replied_at: '' } : {}) })));
  const displaced = state.messages[70];
  Object.assign(displaced, { direction: 'inbound', read_at: '', replied_at: '' });
  state.messages.push(msg(200, { message_id: 'bmsg_purged', body_purged: true, body: '', created_at: '2026-11-20T07:00:00Z' }));
  await fixture(state, 'chat', async (h) => {
    assert.equal(h.get('bot-chat-title')!.textContent, 'Ninjy bot');
    let rows = h.rows();
    assert.equal(rows.length, 50);
    assert.equal(rows[rows.length - 1].id, 'bot-chat-message-bmsg_0120', 'newest at bottom');
    assert.equal(rows[0].id, 'bot-chat-message-bmsg_0071');
    assert.deepEqual(new Set(rows.map((r: any) => r.channel)), new Set(['Telegram', 'WhatsApp', 'Web']));
    assert.equal(rows.find((r: any) => r.id === 'bot-chat-message-bmsg_0120')!.who, 'user', 'inbound is the owner');
    assert.equal(rows.find((r: any) => r.id === 'bot-chat-message-bmsg_0119')!.who, 'bot', 'outbound is the bot');
    assert.ok(h.get('bot-chat-load-older'));
    assert.match(rows.find((r: any) => r.id === 'bot-chat-message-bmsg_0120')!.state, /Read/);
    assert.ok(h.get('bot-chat-message-bmsg_0120-time')!.getAttribute('datetime'), 'every row carries its time');

    // The shared list's top sentinel (IntersectionObserver in a browser) loads the next
    // page with the oldest loaded id as cursor.
    await h.click('bot-chat-load-older');
    const older = h.requests.filter((r: any) => r.path === '/bots/me/messages' && r.search.includes('cursor='));
    assert.equal(older.length, 1);
    assert.match(older[0].search, /cursor=bmsg_0071/);
    rows = h.rows();
    assert.equal(rows.length, 100);
    assert.equal(rows[0].id, 'bot-chat-message-bmsg_0021');

    await h.click('bot-chat-load-older');
    rows = h.rows();
    assert.equal(rows.length, 121);
    assert.equal(rows[0].id, 'bot-chat-message-bmsg_purged');
    assert.match(rows[0].text!, /removed by retention/);
    assert.equal(h.get('bot-chat-load-older'), null, 'end of history');

    const status = (n: string) => h.rows().find((row: any) => row.id === 'bot-chat-message-bmsg_' + n)?.state;
    assert.equal(status('0002'), '✓ Queued');
    assert.equal(status('0022'), '✓ Queued');
    for (const message of state.messages) {
      if (message.message_id === 'bmsg_0002' || message.message_id === 'bmsg_0022') {
        message.read_at = '2026-11-20T09:00:00Z';
      }
    }
    await act(async () => handleUserWsEvent(h.store.dispatch, { type: 'bot_changed', payload: { bot_id: 'bot_a' } }));
    await h.settle(); await h.settle();
    assert.equal(status('0002'), '✓✓ Read');
    assert.equal(status('0022'), '✓✓ Read');
    assert.equal(h.requests.filter((r: any) => r.path === '/bots/me/messages' && r.search.includes('cursor=')).length, 4);

    state.messages.push(msg(122, { read_at: '', replied_at: '' }));
    await act(async () => handleUserWsEvent(h.store.dispatch, { type: 'bot_changed', payload: { bot_id: 'bot_a' } }));
    await h.settle(); await h.settle();
    assert.equal(status('0122'), '✓ Queued');
    assert.equal(status('0071'), '✓ Queued', 'the displaced row stays visible');
    assert.ok(h.requests.some((r: any) => new URLSearchParams(r.search).get('message_ids') === '["bmsg_0071"]'));

    displaced.read_at = '2026-11-20T09:01:00Z';
    await act(async () => handleUserWsEvent(h.store.dispatch, { type: 'bot_changed', payload: { bot_id: 'bot_a' } }));
    await h.settle(); await h.settle();
    assert.equal(status('0071'), '✓✓ Read', 'a retained row between page ranges still receives its receipt');
    assert.equal(status('0122'), '✓ Queued');
  });
});

test('chat: send shows the message immediately, the reply arrives live via bot_changed, retry reuses the key', async () => {
  const state = hub([msg(1, { direction: 'outbound', body: 'Hi, I am your bot' })]);
  state.bot = bot({ status: 'starting' });
  await fixture(state, 'chat', async (h) => {
    assert.equal(h.get('bot-chat-queue-notice')!.textContent, 'Your bot is starting…');
    assert.equal((h.get('bot-chat-composer-send-btn') as HTMLButtonElement).disabled, true, 'blank text cannot be sent');

    state.holdSend = { release: () => {} };
    await h.type('Book a table');
    await h.click('bot-chat-composer-send-btn');
    let rows = h.rows();
    const pendingRow = rows[rows.length - 1];
    assert.equal(pendingRow.text, 'Book a table', 'visible before the hub answers');
    assert.equal(pendingRow.who, 'user');
    assert.equal(pendingRow.state, '… Sending');
    const pendingKey = h.all('[data-debug-id="bot-chat-messages-container"] > .msg').pop()!.getAttribute('data-chat-pin-index');
    assert.ok(pendingKey !== null, 'the send pins like the coordinator chat');
    assert.equal((h.get('bot-chat-input') as HTMLTextAreaElement).value, '');
    assert.match(h.get('bot-chat-queue-notice')!.textContent!, /starting\. Your message is queued/);

    await act(async () => state.holdSend!.release());
    state.holdSend = null;
    await h.settle(); await h.settle();
    const post = h.requests.find((r: any) => r.method === 'POST')!;
    assert.equal(post.path, '/bots/me/channels/web/messages');
    assert.equal(post.body.text, 'Book a table');
    assert.ok(post.body.idempotency_key);
    rows = h.rows();
    assert.equal(rows.filter((r: any) => r.text === 'Book a table').length, 1, 'stored message replaces the pending bubble');
    assert.equal(rows[rows.length - 1].channel, 'Web');
    assert.equal(rows[rows.length - 1].state, '✓ Queued');
    assert.equal(h.get('bot-chat-scroll')!.querySelector('[data-chat-pin-row="true"] [data-chat-body]')!.textContent, 'Book a table',
      'the stored row keeps the send key, so the pin survives the ack');

    const inbound = state.messages[state.messages.length - 1];
    inbound.read_at = '2026-11-20T09:30:05Z';
    await act(async () => handleUserWsEvent(h.store.dispatch, { type: 'bot_changed', payload: { bot_id: 'bot_a' } }));
    await h.settle(); await h.settle();
    rows = h.rows();
    assert.equal(rows[rows.length - 1].state, '✓✓ Read');
    assert.equal(rows[rows.length - 1].text, 'Book a table');
    assert.equal(inbound.replied_at, '');

    inbound.replied_at = '2026-11-20T09:30:06Z';
    state.messages.push(msg(9001, { message_id: 'bmsg_reply', provider: 'web', direction: 'outbound', body: 'Done — **7pm**', created_at: '2026-11-20T09:30:06Z' }));
    state.bot = bot({ status: 'ready' });
    await act(async () => handleUserWsEvent(h.store.dispatch, { type: 'bot_changed', payload: { bot_id: 'bot_a' } }));
    await h.settle(); await h.settle();
    rows = h.rows();
    assert.equal(rows[rows.length - 1].id, 'bot-chat-message-bmsg_reply');
    assert.match(rows[rows.length - 1].text!, /Done — 7pm/);
    assert.equal(rows[rows.length - 2].state, '✓✓ Read', 'read inbound is no longer queued');
    assert.equal(h.get('bot-chat-queue-notice'), null);

    // A failed send keeps the text, explains the error and retries with the same key.
    state.sendStatus = 503;
    await h.type('Also wine');
    await h.click('bot-chat-composer-send-btn');
    assert.equal(h.get('bot-chat-send-error')!.textContent, 'Hub unavailable');
    rows = h.rows();
    assert.equal(rows[rows.length - 1].text, 'Also wine');
    state.sendStatus = 0;
    await h.click('bot-chat-retry');
    const posts = h.requests.filter((r: any) => r.method === 'POST');
    assert.equal(posts.length, 3);
    assert.equal(posts[2].body.idempotency_key, posts[1].body.idempotency_key);
    assert.notEqual(posts[1].body.idempotency_key, posts[0].body.idempotency_key);
    assert.equal(h.get('bot-chat-send-error'), null);
  });
});

test('chat: 403 on send and over-long text show clear messages; Cmd/Ctrl+Enter sends like the coordinator chat', async () => {
  const state = hub();
  await fixture(state, 'chat', async (h) => {
    assert.ok(h.get('bot-chat-empty'));
    state.sendStatus = 403;
    await h.type('hello');
    const input = h.get('bot-chat-input')!;
    await act(async () => input.dispatchEvent(new h.dom.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true })));
    await h.settle();
    assert.equal(h.requests.filter((r: any) => r.method === 'POST').length, 0, 'plain Enter is a newline');
    await act(async () => input.dispatchEvent(new h.dom.window.KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true })));
    await h.settle();
    assert.equal(h.requests.filter((r: any) => r.method === 'POST').length, 1);
    assert.match(h.get('bot-chat-send-error')!.textContent!, /not enabled for your account/);

    await h.type('x'.repeat(16385));
    await h.click('bot-chat-composer-send-btn');
    assert.match(h.get('bot-chat-composer-error')!.textContent!, /too long/);
    assert.equal(h.requests.filter((r: any) => r.method === 'POST').length, 1, 'refused locally');
    assert.equal((h.get('bot-chat-input') as HTMLTextAreaElement).value.length, 16385, 'text kept for editing');
  });
});

test('chat: waiting for a machine keeps the queued state visible', async () => {
  const state = hub([msg(2, { replied_at: '', read_at: '' })]);
  state.bot = bot({ status: 'waiting_for_machine', status_detail: 'no_bridge' });
  await fixture(state, 'chat', async (h) => {
    assert.match(h.get('bot-chat-queue-notice')!.textContent!, /Waiting for a machine/);
    assert.equal(h.get('bot-chat-status-detail')!.textContent, 'None of your machines is online.');
    assert.equal(h.rows()[0].state, '✓ Queued');
  });
});

test('chat header: one compact row with only the bot name (status lives in the sidebar and the notice)', async () => {
  const state = hub([msg(2, { replied_at: '', read_at: '' })]);
  state.bot = bot({ status: 'sleeping' });
  await fixture(state, 'chat', async (h) => {
    const header = h.get('bot-chat-header')!;
    assert.equal(header.textContent, 'Ninjy bot', 'name only');
    assert.equal(header.children.length, 1, 'no leading reserve when the shell passes none');
    assert.match(header.className, /\bh-12\b/, 'desktop chrome row height (TOP_CHROME_HEIGHT), like the agent chat header');
    assert.match(header.className, /\bwindow-drag\b/);
    assert.doesNotMatch(header.className, /flex-wrap|border-b/);
    for (const id of ['bot-chat-status', 'bot-chat-channels']) assert.equal(h.get(id), null, id + ' is gone from the header');
    assert.doesNotMatch(h.doc.body.textContent!, /Asleep|wakes on your next message|Stopped ·|Running ·/);
    assert.ok(h.get('bot-chat-queue-notice'), 'the in-chat waking/queued notice stays');
  });
});

test('composer: the shared morph composer with upload, voice and send controls', async () => {
  const state = hub([msg(1)]);
  await fixture(state, 'chat', async (h) => {
    const card = h.get('bot-chat-composer-card')!;
    assert.equal(card.getAttribute('data-composer-morph'), '', 'same MessageComposerMorphShell as the coordinator chat');
    assert.equal(card.getAttribute('data-expanded'), 'false');
    assert.ok(h.get('bot-chat-input')!.hasAttribute('data-composer-morph-field'));
    for (const id of ['bot-chat-runtime-menu-btn', 'bot-chat-request-pane-btn', 'bot-chat-tasks-btn', 'bot-chat-composer-morph-context']) {
      assert.equal(h.get(id), null, id + ' is not shown for the bot');
    }
    assert.ok(h.get('bot-chat-attach-btn'), 'upload control is shown');
    assert.ok(h.get('bot-chat-mic-btn'), 'voice recording control is shown (REQ-VOICE-4)');
    assert.equal(card.querySelectorAll('button').length, 3, 'upload, mic and send controls');
    assert.ok(h.get('bot-chat-composer-send-btn')!.hasAttribute('data-composer-morph-send'));
    await h.type('draft');
    assert.equal(card.getAttribute('data-expanded'), 'true', 'a draft holds it open');
  });
});

test('phone width (390px): chat and sidebar avoid fixed widths and let content wrap', async () => {
  const state = hub([msg(1, { body: 'https://example.test/' + 'a'.repeat(400) }), msg(2, { body: 'short' })]);
  await fixture(state, 'chat', async (h) => {
    const scroll = h.get('bot-chat-scroll')!;
    assert.match(scroll.className, /overflow-x-hidden/);
    const bubble = h.get('bot-chat-message-bmsg_0002')!.querySelector('[data-chat-body]')!;
    assert.match(bubble.className, /\[overflow-wrap:anywhere\]/);
    assert.match(bubble.parentElement!.className, /max-w-\[86%\]/, 'same user bubble as the coordinator chat');
    assert.match((h.get('bot-chat-input') as HTMLElement).className, /text-base/, '16px input avoids iOS focus zoom');
    assert.match(h.get('bot-chat-composer-shell')!.className, /ui-float-dock-pad/, 'mobile dock padding');
    const header = h.get('bot-chat-header')!;
    assert.match(header.className, /\bh-14\b/, 'mobile chrome row height (MOBILE_TOP_CHROME_HEIGHT)');
    assert.match(h.get('bot-chat-title')!.className, /\btruncate\b/, 'a long name truncates instead of wrapping');
  }, 390);
  for (const file of ['src/ui/components/bots/BotChatPage.tsx', 'src/ui/components/shell/SidebarBot.tsx']) {
    const source = readFileSync(new URL('../' + file, import.meta.url), 'utf8');
    assert.doesNotMatch(source, /\b(?:w|min-w)-\[\d+px\]/, file + ' has no fixed pixel widths');
  }
  const shell = readFileSync(new URL('../src/ui/components/shell/AppShell.tsx', import.meta.url), 'utf8');
  // /bot owns the top chrome row like the agent workspace: no shell spacer above
  // its header, its own full-width outlet, and the collapsed-sidebar reserve.
  assert.match(shell, /const showBrand = !\(isWorkspaceRoute \|\| path === BOT_CHAT_ROUTE\) \|\| !isEffectiveCollapsed;/);
  assert.match(shell, /const ownsTopChromeRow = isWorkspaceRoute \|\| path === BOT_CHAT_ROUTE;/);
  assert.match(shell, /\{!ownsTopChromeRow \? \(\s*<div\s+aria-hidden="true"\s+data-debug-id="shell-top-spacer"/);
  assert.match(shell, /if \(path === BOT_CHAT_ROUTE\) \{[\s\S]*?<BotChatPage headerLeading=\{workspaceLeading\} \/>[\s\S]*?\n  \}/);
  assert.equal(shell.match(/<BotChatPage\b/g)!.length, 1, 'mounted only by the dedicated outlet');
});


test('attachments: picker and paste upload once, send attachment-only, and persist chips in history', async () => {
 const state = hub();
 await fixture(state, 'chat', async h => {
  const file = new h.dom.window.File(['hello'], 'notes.pdf', { type: 'application/pdf' });
  let picked = false;
  const picker = h.get('bot-chat-upload-input') as HTMLInputElement;
  picker.click = () => { picked = true; };
  await h.click('bot-chat-attach-btn');
  assert.equal(picked, true);
  Object.defineProperty(picker, 'files', { configurable: true, value: [file] });
  await act(async () => picker.dispatchEvent(new h.dom.window.Event('change', { bubbles: true })));
  await h.settle(); await h.settle();
  assert.equal(state.uploads.length, 1);
  assert.match(h.get('bot-chat-attachments').textContent, /notes.pdf/);
  const image = new h.dom.window.File(['image'], 'screen.png', { type: 'image/png' });
  const event = new h.dom.window.Event('paste', { bubbles: true, cancelable: true });
  Object.defineProperty(event, 'clipboardData', { value: { files: [image], items: [{ kind: 'file', getAsFile: () => image }] } });
  await act(async () => h.get('bot-chat-input').dispatchEvent(event));
  await h.settle(); await h.settle();
  assert.equal(event.defaultPrevented, true);
  assert.equal(state.uploads.length, 2, 'clipboard files/items do not duplicate the upload');
  assert.equal((h.get('bot-chat-composer-send-btn') as HTMLButtonElement).disabled, false);
  await h.click('bot-chat-composer-send-btn');
  const send = h.requests.find((r: any) => r.path.endsWith('/web/messages'));
  assert.deepEqual(send.body.artifact_ids, ['art_upload_0', 'art_upload_1']);
  assert.equal(send.body.text, '');
  assert.equal(h.get('bot-chat-attachments'), null);
  await h.settle();
  assert.equal(h.all('a[data-debug-id^="bot-chat-artifact-"]').length, 2);
  assert.equal(state.messages[0].attachments?.length, 2);
 });
});

test('attachments: failures block send, retry succeeds, remove clears draft, and plain paste stays native', async () => {
 const state = hub(); state.uploadStatus = 503;
 await fixture(state, 'chat', async h => {
  const picker = h.get('bot-chat-upload-input') as HTMLInputElement;
  const file = new h.dom.window.File(['text'], 'retry.pdf', { type: 'application/pdf' });
  Object.defineProperty(picker, 'files', { configurable: true, value: [file] });
  await act(async () => picker.dispatchEvent(new h.dom.window.Event('change', { bubbles: true })));
  await h.settle(); await h.settle();
  assert.equal((h.get('bot-chat-composer-send-btn') as HTMLButtonElement).disabled, true);
  assert.match(h.get('bot-chat-attachments').textContent, /Upload unavailable/);
  state.uploadStatus = 0;
  const retry = h.all('[data-debug-id^="bot-chat-upload-retry-"]')[0];
  await act(async () => retry.click()); await h.settle(); await h.settle();
  assert.equal(state.uploads.length, 1);
  assert.equal((h.get('bot-chat-composer-send-btn') as HTMLButtonElement).disabled, false);
  await act(async () => h.all('[data-debug-id^="bot-chat-upload-remove-"]')[0].click());
  assert.equal(h.get('bot-chat-attachments'), null);
  const plain = new h.dom.window.Event('paste', { bubbles: true, cancelable: true });
  Object.defineProperty(plain, 'clipboardData', { value: { files: [], items: [], getData: () => 'hello' } });
  await act(async () => h.get('bot-chat-input').dispatchEvent(plain));
  assert.equal(plain.defaultPrevented, false);
  assert.equal(state.uploads.length, 1);
 });
});

test('attachments: refreshed and purged history update preview IDs', () => {
 const original = msg(1, { attachments: [{ artifact_id: 'art_a' }] });
 const known = model.mergeBotMessages(new Map(), [original as any]);
 const changed = model.mergeBotMessages(known, [{ ...original, attachments: [{ artifact_id: 'art_b' }] } as any]);
 assert.notEqual(changed, known);
 assert.deepEqual(model.botChatMessages(model.botTimeline(changed), [], new Map())[0].artifactIds, ['art_b']);
 const purged = model.botChatMessages([{ ...original, body_purged: true } as any], [], new Map())[0];
 assert.deepEqual(purged.artifactIds, []);
});


test('shared uploads preserve bot origin metadata and the 20-file send limit', async () => {
  const state = hub();
  await fixture(state, 'chat', async h => {
    const files = Array.from({ length: 21 }, (_, i) => new h.dom.window.File(['hello'], `notes-${i}.pdf`, { type: 'application/pdf' }));
    const picker = h.get('bot-chat-upload-input') as HTMLInputElement;
    Object.defineProperty(picker, 'files', { configurable: true, value: files });
    await act(async () => picker.dispatchEvent(new h.dom.window.Event('change', { bubbles: true })));
    await h.settle(); await h.settle();
    const uploads = h.requests.filter((r: any) => r.path === '/artifacts' && r.method === 'POST');
    assert.equal(uploads.length, 21);
    for (const request of uploads) {
      assert.equal(request.body.origin_kind, 'bot_chat');
      assert.equal(request.body.origin_ref, 'bot_a');
      assert.equal(request.body.agent_id, undefined, 'bot upload does not claim agent ownership');
      assert.equal(request.body.agent_instance_id, undefined);
    }
    await h.click('bot-chat-composer-send-btn');
    assert.match(h.get('bot-chat-composer-error').textContent, /up to 20 files/);
    assert.equal(h.requests.some((r: any) => r.path.endsWith('/web/messages')), false);
    await act(async () => h.all('[data-debug-id^="bot-chat-upload-remove-"]')[0].click());
    await h.click('bot-chat-composer-send-btn');
    assert.equal(h.requests.find((r: any) => r.path.endsWith('/web/messages')).body.artifact_ids.length, 20);
  });
});

test('shared uploads reject oversized files before posting and keep send blocked', async () => {
  await fixture(hub(), 'chat', async h => {
    const file = new h.dom.window.File(['small'], 'oversized.pdf', { type: 'application/pdf' });
    Object.defineProperty(file, 'size', { value: 16 * 1024 * 1024 });
    const picker = h.get('bot-chat-upload-input') as HTMLInputElement;
    Object.defineProperty(picker, 'files', { configurable: true, value: [file] });
    await act(async () => picker.dispatchEvent(new h.dom.window.Event('change', { bubbles: true })));
    await h.settle();
    assert.match(h.get('bot-chat-attachments').textContent, /Failed/);
    assert.equal(h.requests.some((r: any) => r.path === '/artifacts' && r.method === 'POST'), false);
    assert.equal((h.get('bot-chat-composer-send-btn') as HTMLButtonElement).disabled, true);
  });
});

test('bot and agent timestamps share the same formatter for today, older dates and invalid dates', async () => {
  const { formatMessageTimestamp } = await import('../src/ui/components/chat/formatMessageTimestamp.ts');
  assert.equal(model.formatBotChatTimestamp, formatMessageTimestamp);
  for (const value of [0, NaN, Date.now(), Date.UTC(2020, 0, 1)]) {
    assert.deepEqual(model.formatBotChatTimestamp(value), formatMessageTimestamp(value));
  }
});


test('chat: live tools follow the authorized runtime after reconnect refresh', async () => {
  const state = hub([msg(1)]);
  await fixture(state, 'chat', async h => {
    assert.equal(h.sockets.length, 0, 'an instance without an authorized conversation cannot subscribe');
    state.bot = { ...state.bot, advanced: { ...state.bot.advanced, conversation_id: 'chat_bot_runtime' } };
    await act(async () => resyncAfterReconnect(h.store.dispatch));
    await h.settle();
    const first = h.sockets[0] as FakeToolSocket;
    first.open();
    assert.deepEqual(first.sent[0].instance_ids, ['inst_bot']);
    await act(async () => first.state(snapshot('inst_bot')));
    assert.ok(h.get('live-tools-shell-sh_inst_bot'));
    assert.equal(first.sent[0].views[0].conversation_id, 'chat_bot_runtime');
    const tail = h.get('live-tool-activity');
    assert.ok(tail.parentElement === h.get('bot-chat-messages-container'));
    assert.equal(tail.nextElementSibling?.getAttribute('data-debug-id'), 'bot-chat-pin-turn-spacer');
    await act(async () => first.state(snapshot('inst_bot', 2, {
      active: [],
      completed_since_last: [{
        ...snapshot('inst_bot').active[0],
        status: 'completed', duration_ms: 750, completed_at_ms: 750,
      }],
    }), false));
    assert.equal(h.get('live-tools-shell-sh_inst_bot'), null);
    assert.ok(tail.querySelector('[aria-label="Succeeded"]'));

    state.bot = { ...state.bot, advanced: { ...state.bot.advanced, conversation_id: 'chat_new', agent_instance_id: 'inst_new' } };
    await act(async () => resyncAfterReconnect(h.store.dispatch));
    await h.settle();
    assert.equal(first.readyState, 3);
    assert.equal(h.get('live-tools-shell-sh_inst_bot'), null);
    const next = h.sockets.at(-1) as FakeToolSocket;
    next.open();
    assert.deepEqual(next.sent[0].instance_ids, ['inst_new']);
    assert.equal(next.sent[0].views[0].conversation_id, 'chat_new');
    await act(async () => next.state(snapshot('inst_new')));
    assert.ok(h.get('live-tools-shell-sh_inst_new'));
  });
});

test('chat: stored web actions approve and reject through web intake', async () => {
  const actions = (...action_ids: string[]) => ({ action_ids });
  const state = hub([
    msg(1, { provider: 'web', metadata: actions('approve', 'reject', 'resolved', 'missing', 'feedback_failure') }),
    msg(3, { provider: 'web', body_purged: true, metadata: actions('purged') }),
    msg(5, { provider: 'telegram', metadata: actions('other_channel') }),
  ]);
  state.cards.set('approve', 'pending').set('reject', 'pending').set('resolved', 'accepted').set('feedback_failure', 'pending');
  await fixture(state, 'chat', async h => {
    assert.equal(h.get('action-card-purged'), null);
    assert.equal(h.get('action-card-other_channel'), null);
    assert.equal(h.get('action-card-approve-btn-resolved'), null);
    assert.equal(h.get('action-card-approve-btn-missing'), null);
    await h.click('action-card-approve-btn-approve');
    const input = h.get('action-card-comment-input-reject');
    const setter = Object.getOwnPropertyDescriptor(h.dom.window.HTMLInputElement.prototype, 'value')!.set!;
    await act(async () => {
      setter.call(input, 'Needs review');
      input.dispatchEvent(new h.dom.window.Event('input', { bubbles: true }));
    });
    await h.click('action-card-reject-btn-reject');
    assert.equal(h.get('action-card-status-approve').textContent, 'accepted');
    assert.equal(h.get('action-card-status-reject').textContent, 'rejected');
    const posts = h.requests.filter((request: any) => request.method === 'POST');
    assert.deepEqual(posts.map((request: any) => request.path), [
      '/cards/approve/accept', '/bots/me/channels/web/messages',
      '/cards/reject/discard', '/bots/me/channels/web/messages',
    ]);
    assert.match(posts[1].body.text, /Action approve .* was approved by user/);
    assert.match(posts[3].body.text, /Action reject .* was rejected by user: Needs review/);

    state.sendStatus = 503;
    await h.click('action-card-approve-btn-feedback_failure');
    assert.equal(h.get('action-card-status-feedback_failure').textContent, 'accepted');
    assert.equal(h.get('action-card-approve-btn-feedback_failure'), null);
    assert.match(h.get('action-card-feedback_failure').textContent, /Could not send feedback/);
  });
});
