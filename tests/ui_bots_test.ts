import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';

const { resolveBotStatusLabel, filterBotConversations, validateBotPlacement, BOT_STATUS_DETAILS, whatsAppCardState, whatsAppQrDataUrl } = await import('../src/ui/components/settings/botsView.ts');
const { getVisibleSettingsCategories } = await import('../src/ui/components/settings/SettingsModal.tsx');
const { resolveExperimentFlag, BOTS_EXPERIMENT_KEY, EXPERIMENTAL_FLAGS } = await import('../src/ui/components/settings/experimentFlags.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { botsApi } = await import('../src/ui/api/endpoints/bots.ts');
const { default: BotsPanel } = await import('../src/ui/components/settings/BotsPanel.tsx');
const { default: ConversationsHomePage } = await import('../src/ui/components/chat/ConversationsHomePage.tsx');
const { default: vault } = await import('../src/ui/store/vaultSlice.ts');
const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');
const options = { bridges: [{ bridge_id: 'brg_a', label: 'Laptop', online: false, bot_capable: true, providers: [{ provider: 'claude', label: 'Claude', models: ['opus'] }] }] };
const candidate = { bridge_id: '*', provider: '*', model: '*', tier: 'allowed' as const };
function bot() {
  return { bot_id: 'bot_a', display_name: 'Ninjy bot', status: 'ready', status_detail: '',
    telegram: { configured: true, bot_username: 'ninjy_test', binding: null },
    whatsapp: { configured: true, phone_display: '15550100001', binding: null, window_open: false, reengage_sent: false, reengage_error: '', held_replies: [] },
    placement_revision: 3,
    advanced: { agent_instance_id: 'inst_bot', bridge_id: 'brg_a', bridge_label: 'Laptop', provider: 'claude', model: 'opus', runtime_status: 'idle' } };
}

test('resolveBotStatusLabel', () => {
  assert.deepEqual(['ready', 'working', 'starting', 'sleeping', 'waiting_for_machine', 'new'].map((s) => resolveBotStatusLabel(s as any)),
    ['Ready', 'Answering…', 'Starting…', 'Asleep — wakes on your next message', 'Waiting for a machine — your messages are saved', 'Not started yet']);
  assert.equal(BOT_STATUS_DETAILS.no_bridge, 'None of your machines is online.');
  assert.equal(BOT_STATUS_DETAILS.busy, 'Your machine is busy; trying again in a few minutes.');
  assert.equal(BOT_STATUS_DETAILS.relocation_stranded, 'Waiting for the machine your bot last ran on to come back online.');
  assert.equal(BOT_STATUS_DETAILS.gave_up, 'Your bot could not answer your last message. Send another message to try again.');
});

test('filterBotConversations', () => {
  const rows = [{ agentInstanceId: 'inst_human' }, { agentInstanceId: 'inst_bot' }, {}];
  assert.equal(filterBotConversations(rows, null), rows);
  assert.equal(filterBotConversations(rows, ''), rows);
  assert.deepEqual(filterBotConversations(rows, 'inst_bot'), [rows[0], rows[2]]);
  assert.equal(rows.length, 3);
});

test('placement form validation mirrors 10.1', () => {
  assert.equal(validateBotPlacement([], options), null);
  assert.equal(validateBotPlacement([candidate], options), null);
  assert.equal(validateBotPlacement([{ ...candidate, bridge_id: 'brg_a', provider: 'claude', model: 'opus' }], options), null, 'offline owned bridges are allowed');
  assert.equal(validateBotPlacement(Array.from({ length: 33 }, () => candidate), options), 'too_many_candidates');
  assert.equal(validateBotPlacement([{ ...candidate, bridge_id: 'other' }], options), 'unknown_bridge');
  assert.equal(validateBotPlacement([{ ...candidate, provider: 'other' }], options), 'unknown_provider');
  assert.equal(validateBotPlacement([{ ...candidate, model: 'opus' }], options), 'model_requires_provider');
  assert.equal(validateBotPlacement([candidate, { ...candidate, tier: 'preferred' }], options), 'duplicate_candidate');
  assert.equal(validateBotPlacement([{ ...candidate, provider: 'claude', model: 'custom' }], options), null, 'the spec permits concrete model names with a concrete provider');
});

test('settings category hidden when experiment off', () => {
  assert.equal(EXPERIMENTAL_FLAGS.find((flag) => flag.key === BOTS_EXPERIMENT_KEY)?.description,
    'A personal bot you can talk to from Telegram or WhatsApp. It runs on your machines; Ninjy picks the machine and model.');
  for (const flags of [undefined, [], [{ key: 'bots', enabled: false }], [{ key: 'bots', enabled: true }, { key: 'bots', enabled: true }]]) {
    assert.equal(getVisibleSettingsCategories(true, resolveExperimentFlag(flags, BOTS_EXPERIMENT_KEY) === 'enabled').some((c) => c.id === 'bots'), false);
  }
  assert.deepEqual(getVisibleSettingsCategories(false, true).find((c) => c.id === 'bots'),
    { id: 'bots', label: 'Bots', title: 'Bots', description: 'Your personal bot on Telegram and WhatsApp.' });
});

async function fixture(run: (h: any) => Promise<void>, enabled = true, initialBot: any = bot(), view = 'panel') {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node,
    navigator: dom.window.navigator, requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  }
  const previousFetch = globalThis.fetch;
  const requests: any[] = [];
  let current = initialBot;
  let revision = 3;
  let placementRows: any[] = [];
  let conflict = false;
  globalThis.fetch = (async (url: any, init: any = {}) => {
    const path = new URL(String(url), 'https://hub.test').pathname.replace('/api/v1', '');
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    requests.push({ path, method, body });
    if (path === '/me/experiments') return Response.json({ data: { experiments: [{ key: 'bots', enabled }] } });
    if (path === '/chats') return Response.json({ data: [
      { conversation_id: 'chat_bot', agent_instance_id: 'inst_bot', agent_name: 'Ninjy bot' },
      { conversation_id: 'chat_human', agent_instance_id: 'inst_human', agent_name: 'My assistant' },
    ], page: { has_more: false } });
    if (path === '/bots/me') {
      if (method === 'POST') { current = bot(); return Response.json({ data: current }, { status: 201 }); }
      if (method === 'DELETE') { current = null; return Response.json({ data: { deleted: true } }); }
      return current ? Response.json({ data: current }) : Response.json({ error: { code: 'not_found', details: { code: 'bot_not_found' }, message: 'No bot' } }, { status: 404 });
    }
    if (path.endsWith('/placement/options')) return Response.json({ data: options });
    if (path.endsWith('/placement')) {
      if (method === 'PUT') {
        if (conflict) return Response.json({ error: { code: 'conflict', details: { code: 'placement_revision_changed' }, message: 'Changed' } }, { status: 409 });
        revision++; placementRows = body.candidates;
      }
      return Response.json({ data: { placement_revision: revision, candidates: placementRows } });
    }
    if (path.endsWith('/whatsapp/pairing')) return Response.json({ data: { pairing_url: 'https://wa.me/15550100001?text=CODE', pairing_text: 'CODE', phone_display: '15550100001', expires_at: '2026-11-18T00:10:00Z' } }, { status: 201 });
    if (path.endsWith('/whatsapp') && method === 'DELETE') { current.whatsapp.binding = null; return Response.json({ data: { disconnected: true } }); }
    if (path === '/me/agent-writes') return Response.json({ data: [], page: {} });
    if (path.endsWith('/pairing')) return Response.json({ data: { pairing_url: 'https://t.me/ninjy_test?start=abc', expires_at: '2026-11-18T00:10:00Z' } }, { status: 201 });
    if (path.endsWith('/telegram') && method === 'DELETE') { current.telegram.binding = null; return Response.json({ data: { disconnected: true } }); }
    if (path.endsWith('/deliveries')) return Response.json({ data: { deliveries: [{ delivery_id: 'bdl_a', state: 'acted', round: 1, finish_reason: 'acted', created_at: '2026-11-18', attempts: [] }] } });
    throw new Error('Unexpected request: ' + path);
  }) as typeof fetch;
  const store = configureStore({ reducer: { auxPanes, vault, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (g) => g({ serializableCheck: false }).concat(heimdallApi.middleware), enhancers: (g) => g({ autoBatch: false }) });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const settle = async () => { await act(async () => { await new Promise((r) => setTimeout(r, 25)); }); };
  const get = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement;
  const click = async (id: string) => { assert.ok(get(id), id); await act(async () => get(id).click()); await settle(); };
  let closed = false;
  try {
    await act(async () => root.render(React.createElement(Provider, { store, children: view === 'inbox' ? React.createElement(ConversationsHomePage) : React.createElement(BotsPanel, { onOpenTerminal: () => { closed = true; } }) })));
    await settle(); await settle();
    await run({ dom, store, requests, get, click, settle, closed: () => closed, setBot: (value: any) => { current = value; },
      changeRevision: () => { revision++; }, conflict: () => { conflict = true; } });
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
    dom.window.close();
    for (const [key, value] of saved) { if (value) Object.defineProperty(globalThis, key, value); else delete (globalThis as any)[key]; }
  }
}

test('panel off performs no bot requests; empty state creates without placement', async () => {
  await fixture(async ({ get, requests }: any) => {
    assert.equal(get('settings-bots-panel'), null);
    assert.equal(requests.filter((r: any) => r.path.startsWith('/bots')).length, 0);
  }, false);
  await fixture(async ({ get, click, requests }: any) => {
    assert.equal(get('settings-bots-empty').textContent, "You don't have a bot yet. Your bot runs on your machines and answers you on Telegram or WhatsApp.");
    await click('settings-bots-create-btn');
    assert.deepEqual(requests.find((r: any) => r.method === 'POST').body, {});
    assert.equal(get('settings-bots-status').textContent, 'Ready');
  }, true, null);
});

test('Advanced hides runtime details and Open terminal opens the real PTY aux tab', async () => {
  await fixture(async ({ get, click, store, dom, closed }: any) => {
    const details = get('settings-bots-advanced-details');
    assert.equal(details.closest('details').open, false);
    assert.match(details.textContent, /Machine: Laptop/);
    assert.match(details.textContent, /Provider: claude/);
    assert.match(details.textContent, /Model: opus/);
    assert.equal(get('settings-bots-advanced-deliveries').textContent.includes('acted'), true);
    await click('settings-bots-advanced-terminal-btn');
    assert.equal(store.getState().auxPanes.isOpen, true);
    assert.equal(store.getState().auxPanes.agentPanes.inst_bot.tabs.some((tab: any) => tab.content.type === 'agentPty' && tab.content.agentInstanceId === 'inst_bot'), true);
    assert.equal(dom.window.location.hash, '#/conversations/inst_bot');
    assert.equal(closed(), true);
  });
  const unstarted = bot(); unstarted.advanced.agent_instance_id = '';
  await fixture(async ({ get }: any) => {
    assert.equal(get('settings-bots-advanced-terminal-btn').disabled, true);
    assert.equal(get('settings-bots-advanced-terminal-btn').title, 'Your bot has not started yet.');
  }, true, unstarted);
});

test('Telegram link, notice, disconnect confirmation and bot deletion', async () => {
  await fixture(async ({ get, click, store, settle, setBot, requests }: any) => {
    assert.match(get('settings-bots-telegram-notice').textContent, /Telegram chats are not end-to-end encrypted/);
    await click('settings-bots-telegram-connect-btn');
    assert.match(get('settings-bots-telegram-link').textContent, /Open this link on your phone within 10 minutes:/);
    assert.equal(get('settings-bots-telegram-copy-btn').textContent, 'Copy link');
    const paired = bot(); (paired.telegram as any).binding = { state: 'active', display: '@alice', connected_at: '2026-11-18' };
    setBot(paired);
    await act(async () => handleUserWsEvent(store.dispatch, { type: 'bot_changed' })); await settle();
    assert.equal(get('settings-bots-telegram-paired').textContent, 'Connected to @alice');
    await click('settings-bots-telegram-disconnect-btn');
    assert.ok(get('settings-bots-telegram-disconnect-confirm-btn').closest('[role="dialog"]'));
    assert.equal(requests.some((r: any) => r.path.endsWith('/telegram') && r.method === 'DELETE'), false);
    await click('settings-bots-telegram-disconnect-confirm-btn');
    assert.ok(get('settings-bots-telegram-connect-btn'));
    await click('settings-bots-delete-btn');
    assert.match(get('settings-bots-delete-confirm-btn').closest('[role="dialog"]').textContent, /Delete your bot\? Its Telegram and WhatsApp connections and message history are removed\./);
    await click('settings-bots-delete-confirm-btn');
    assert.ok(get('settings-bots-empty'));
  });
  const unconfigured = bot(); unconfigured.telegram.configured = false;
  await fixture(async ({ get }: any) => {
    assert.match(get('settings-bots-telegram-unconfigured').textContent, /Telegram is not set up on this Ninjy hub/);
    assert.ok(get('settings-bots-telegram-notice'));
    assert.equal(get('settings-bots-telegram-connect-btn'), null);
  }, true, unconfigured);
});

test('placement preserves draft revision across bot_changed and displays exact CAS conflict', async () => {
  await fixture(async ({ get, click, conflict, requests, store, settle, changeRevision }: any) => {
    assert.equal(get('settings-bots-placement-toggle').closest('details').open, false);
    await click('settings-bots-placement-add-btn');
    assert.ok(get('settings-bots-placement-row-0'));
    assert.equal(get('settings-bots-placement-model-0').disabled, true);
    changeRevision();
    await act(async () => handleUserWsEvent(store.dispatch, { type: 'bot_changed' })); await settle();
    conflict();
    await click('settings-bots-placement-save-btn');
    assert.equal(requests.find((r: any) => r.method === 'PUT').body.expected_revision, 3);
    assert.equal(get('settings-bots-placement-error').textContent, 'Placement changed elsewhere. Reload and try again.');
    await click('settings-bots-placement-remove-0');
    assert.equal(get('settings-bots-placement-row-0'), null);
  });
});

test('bot endpoint wire paths, methods, bodies and tag invalidation', async () => {
  await fixture(async ({ store, requests }: any) => {
    await act(async () => { await store.dispatch(botsApi.endpoints.putBotPlacement.initiate({ expected_revision: 3, candidates: [candidate] })).unwrap(); });
    const request = requests.find((r: any) => r.method === 'PUT');
    assert.equal(request.path, '/bots/me/placement');
    assert.deepEqual(request.body, { expected_revision: 3, candidates: [candidate] });
    const actions: any[] = [];
    handleUserWsEvent((action: any) => { if (typeof action !== 'function') actions.push(action); }, { type: 'bot_changed' });
    assert.ok(actions.some((action) => action.type.endsWith('invalidateTags') && action.payload.includes('Bot')));
  });
});

test('Conversations home filters only the bot instance while the experiment is enabled', async () => {
  for (const enabled of [false, true]) {
    await fixture(async ({ get, requests }: any) => {
      assert.ok(get('conversation-inbox-row-chat_human'));
      assert.equal(Boolean(get('conversation-inbox-row-chat_bot')), !enabled);
      assert.equal(requests.some((r: any) => r.path === '/bots/me'), enabled);
    }, enabled, bot(), 'inbox');
  }
});

test('placement Save sends ordered rules and a successful revision; duplicate rows are refused locally', async () => {
  await fixture(async ({ get, click, requests }: any) => {
    await click('settings-bots-placement-add-btn');
    await click('settings-bots-placement-add-btn');
    await click('settings-bots-placement-save-btn');
    assert.equal(requests.some((r: any) => r.method === 'PUT'), false);
    assert.equal(get('settings-bots-placement-error').textContent, 'Each machine, provider and model rule must be unique.');
    await click('settings-bots-placement-remove-1');
    await click('settings-bots-placement-save-btn');
    assert.deepEqual(requests.find((r: any) => r.method === 'PUT').body, { expected_revision: 3, candidates: [candidate] });
    assert.equal(get('settings-bots-placement-error'), null);
  });
});

test('whatsAppCardState covers all four states and whatsAppQrDataUrl produces a local GIF', () => {
  const w: any = bot().whatsapp;
  assert.equal(whatsAppCardState({ ...w, configured: false }), 'unconfigured');
  assert.equal(whatsAppCardState(w), 'unpaired');
  const paired = { ...w, binding: { display: '+15551234567' } };
  assert.equal(whatsAppCardState(paired), 'paired');
  assert.equal(whatsAppCardState({ ...paired, held_replies: [{ body: 'Reply' }] }), 'held');
  assert.equal(whatsAppCardState({ ...w, enabled: true }), 'unpaired');
  assert.equal(whatsAppCardState({ ...w, enabled: false }), 'invite_only');
  assert.equal(whatsAppCardState({ ...paired, enabled: false }), 'invite_only');
  assert.equal(whatsAppCardState({ ...w, configured: false, enabled: false }), 'unconfigured');
  assert.match(whatsAppQrDataUrl('https://wa.me/15550100001?text=CODE'), /^data:image\/gif;base64,/);
});

test('WhatsApp card renders four mocked states and all reminder values', async () => {
  const binding = { state: 'active', display: '+15551234567', connected_at: '2026-11-18' };
  for (const state of ['unconfigured', 'unpaired', 'paired', 'held']) {
    const b: any = bot();
    b.whatsapp.configured = state !== 'unconfigured';
    b.whatsapp.binding = ['paired', 'held'].includes(state) ? binding : null;
    b.whatsapp.held_replies = state === 'held' ? [{ message_id: 'wamid.1', body: '<script>literal</script>\nReply', created_at: '2026-11-18' }] : [];
    await fixture(async ({ get }: any) => {
      assert.ok(get('settings-bots-whatsapp-' + (state === 'held' ? 'held' : state)));
      assert.ok(get('settings-bots-whatsapp-notice'));
      assert.equal(Boolean(get('settings-bots-whatsapp-connect-btn')), state === 'unpaired');
      assert.equal(Boolean(get('settings-bots-whatsapp-disconnect-btn')), ['paired', 'held'].includes(state));
      if (state === 'held') {
        assert.equal(get('settings-bots-whatsapp-held-item-0').textContent, '<script>literal</script>\nReply');
        assert.equal(get('settings-bots-whatsapp-held-item-0').querySelector('script'), null);
        assert.equal(get('settings-bots-whatsapp-reminder'), null);
      }
    }, true, b);
  }
  for (const [sent, error, expected] of [
    [true, 'send_failed', 'Ninjy sent you a WhatsApp reminder.'],
    [false, 'template_unavailable', 'Ninjy could not send you a WhatsApp reminder because its message template is not approved yet.'],
    [false, 'send_failed', 'Ninjy could not send you a WhatsApp reminder.'],
  ]) {
    const b: any = bot();
    Object.assign(b.whatsapp, { binding, held_replies: [{ message_id: '1', body: 'Reply' }], reengage_sent: sent, reengage_error: error });
    await fixture(async ({ get }: any) => assert.equal(get('settings-bots-whatsapp-reminder').textContent, expected), true, b);
  }
});

test('WhatsApp card shows the invite-only message instead of Connect; Telegram card unchanged', async () => {
  for (const binding of [null, { state: 'active', display: '+15551234567', connected_at: '2026-11-18' }]) {
    const b: any = bot();
    b.whatsapp.enabled = false;
    b.whatsapp.binding = binding;
    await fixture(async ({ get }: any) => {
      assert.equal(get('settings-bots-whatsapp-invite-only').textContent, 'WhatsApp is invite-only — ask the admin for access.');
      assert.equal(get('settings-bots-whatsapp-connect-btn'), null);
      assert.equal(get('settings-bots-whatsapp-disconnect-btn'), null);
      assert.equal(get('settings-bots-whatsapp-unpaired'), null);
      assert.ok(get('settings-bots-telegram-connect-btn'), 'Telegram card is unaffected');
    }, true, b);
  }
  const enabled: any = bot();
  enabled.whatsapp.enabled = true;
  await fixture(async ({ get }: any) => {
    assert.equal(get('settings-bots-whatsapp-invite-only'), null);
    assert.ok(get('settings-bots-whatsapp-connect-btn'));
  }, true, enabled);
});

test('WhatsApp pairing link, QR, clipboard, disconnect cancellation and confirmation', async () => {
  await fixture(async ({ get, click, setBot, store, settle, requests, dom }: any) => {
    let copied = '';
    Object.defineProperty(dom.window.navigator, 'clipboard', { value: { writeText: async (value: string) => { copied = value; } }, configurable: true });
    await click('settings-bots-whatsapp-connect-btn');
    const link = get('settings-bots-whatsapp-open-link');
    assert.equal(link.href, 'https://wa.me/15550100001?text=CODE');
    assert.equal(link.target, '_blank');
    assert.match(get('settings-bots-whatsapp-qr').src, /^data:image\/gif;base64,/);
    assert.equal(get('settings-bots-whatsapp-qr').alt, 'QR code to connect WhatsApp');
    assert.equal(get('settings-bots-whatsapp-pairing-text').textContent, 'Message: CODE');
    await click('settings-bots-whatsapp-copy-btn');
    assert.equal(copied, link.href);
    const paired: any = bot();
    paired.whatsapp.binding = { state: 'active', display: '+15551234567', connected_at: '2026-11-18' };
    setBot(paired);
    await act(async () => handleUserWsEvent(store.dispatch, { type: 'bot_changed' })); await settle();
    assert.equal(get('settings-bots-whatsapp-paired').textContent, 'Connected to +15551234567');
    await click('settings-bots-whatsapp-disconnect-btn');
    assert.match(get('settings-bots-whatsapp-disconnect-dialog').textContent, /Your bot will stop receiving messages from this WhatsApp account/);
    await click('settings-bots-whatsapp-disconnect-cancel-btn');
    assert.equal(requests.some((r: any) => r.method === 'DELETE'), false);
    await click('settings-bots-whatsapp-disconnect-btn');
    await click('settings-bots-whatsapp-disconnect-confirm-btn');
    assert.ok(get('settings-bots-whatsapp-connect-btn'));
    assert.equal(get('settings-bots-whatsapp-link'), null);
    assert.equal(requests.filter((r: any) => r.path.endsWith('/whatsapp') && r.method === 'DELETE').length, 1);
  });
});

test('web bot API sends stable keys, pages unified history and refreshes on bot_changed', async () => {
  const previousFetch = globalThis.fetch;
  const requests: { path: string; method: string; body?: unknown }[] = [];
  const store = configureStore({ reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (g) => g({ serializableCheck: false }).concat(heimdallApi.middleware),
    enhancers: (g) => g({ autoBatch: false }) });
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const url = new URL(String(input), 'https://hub.test');
    const method = init.method ?? 'GET';
    requests.push({ path: url.pathname + url.search, method, body: init.body ? JSON.parse(init.body) : undefined });
    if (method === 'POST') return Response.json({ data: { message_id: 'web-in', created: true } }, { status: 201 });
    return Response.json({ data: { messages: [{ message_id: 'web-out', binding_id: 'web-binding', provider: 'web', direction: 'outbound', body: 'answer', send_state: 'sent', created_at: 'now', read_at: '', replied_at: '', body_purged: false }], next_cursor: 'older' } });
  }) as typeof fetch;
  const history = store.dispatch(botsApi.endpoints.getUnifiedBotMessages.initiate({ limit: 2, cursor: 'id /?' }));
  try {
    const page = await history.unwrap();
    assert.equal(page.messages[0].provider, 'web');
    assert.equal(page.next_cursor, 'older');
    assert.match(requests[0].path, /messages\?limit=2&cursor=id%20%2F%3F$/);
    const sent = await store.dispatch(botsApi.endpoints.sendBotWebMessage.initiate({ text: 'hello', idempotency_key: 'stable-key' })).unwrap();
    assert.equal(sent.message_id, 'web-in');
    assert.deepEqual(requests.find((r) => r.method === 'POST'), { path: '/api/v1/bots/me/channels/web/messages', method: 'POST', body: { text: 'hello', idempotency_key: 'stable-key' } });
    await new Promise((resolve) => setTimeout(resolve, 20));
    const before = requests.filter((r) => r.method === 'GET').length;
    handleUserWsEvent(store.dispatch, { type: 'bot_changed', payload: { bot_id: 'bot_a' } });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.ok(requests.filter((r) => r.method === 'GET').length > before);
  } finally {
    history.unsubscribe();
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
  }
});
