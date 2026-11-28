import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import AgentOutputBlocks from '../src/ui/components/chat/AgentOutputBlocks.tsx';
import agentOutputReducer, {
  agentOutputPayloadFromEvent, agentOutputSegmentReceived, agentReplyReceived, selectAgentOutputTurns,
} from '../src/ui/store/agentOutputSlice.ts';

// G12: agent output is streamed, not stored. These cover the UI half: the
// muted live block, collapse/expand on turn end, UI-memory-only state, and a
// new agent reply dropping earlier blocks.

const segment = (turn: number, revision: number, status = 'pending', body = `turn ${turn} text r${revision}`, part = 0) => ({
  type: 'agent_output', event: 'assistant_segment', conversation_id: 'chat_g12', agent_instance_id: 'inst_g12',
  turn_id: part ? `ham:epoch:${turn}:s${part}` : `ham:epoch:${turn}`, message_id: `msg_${turn}_${part}`,
  launch_epoch: 'epoch', revision, message_status: status, stop_reason: status === 'complete' ? 'end_turn' : '', input_ids: [], body,
});

function makeStore() {
  return configureStore({ reducer: { agentOutput: agentOutputReducer, vault: (s = {}) => s } });
}

function withDom<T>(run: (dom: JSDOM) => Promise<T>): Promise<T> {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT', 'localStorage', 'sessionStorage'];
  const previous = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true, localStorage: dom.window.localStorage, sessionStorage: dom.window.sessionStorage });
  return run(dom).finally(() => { dom.window.close(); Object.assign(globalThis, previous); });
}

async function mount(dom: JSDOM, store: ReturnType<typeof makeStore>) {
  const root = createRoot(dom.window.document.getElementById('root')!);
  await act(async () => root.render(React.createElement(Provider, { store, children: React.createElement(AgentOutputBlocks, { conversationId: 'chat_g12' }) })));
  return root;
}

const q = (dom: JSDOM, id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
const receive = async (store: ReturnType<typeof makeStore>, raw: any) => {
  const payload = agentOutputPayloadFromEvent(raw);
  assert.ok(payload);
  await act(async () => { store.dispatch(agentOutputSegmentReceived(payload!)); });
};

test('a live turn streams into a muted working block; stale revisions are ignored', () => withDom(async (dom) => {
  const store = makeStore();
  const root = await mount(dom, store);
  assert.equal(q(dom, 'conversation-agent-output'), null, 'nothing streamed, nothing shown');
  await receive(store, segment(1, 1));
  const live = q(dom, 'conversation-agent-output-live-ham-epoch-1')!;
  assert.ok(live, 'the live block appears');
  assert.match(live.className, /text-muted/);
  assert.match(live.className, /text-xs/);
  assert.match(live.textContent!, /Working…/);
  assert.match(live.textContent!, /turn 1 text r1/);
  await receive(store, segment(1, 3));
  assert.match(live.textContent!, /turn 1 text r3/);
  await receive(store, segment(1, 2));
  assert.match(live.textContent!, /turn 1 text r3/, 'an older revision cannot regress the snapshot');
  // A tool boundary closes segment 0 without a stop reason: the turn keeps streaming.
  await receive(store, { ...segment(1, 4, 'complete'), stop_reason: '' });
  await receive(store, segment(1, 1, 'pending', 'after the tool', 1));
  const still = q(dom, 'conversation-agent-output-live-ham-epoch-1')!;
  assert.ok(still, 'a segment boundary is not a turn end');
  assert.match(still.textContent!, /after the tool/);
  await act(async () => root.unmount());
}));

test('a finished turn collapses to one line and expands on click', () => withDom(async (dom) => {
  const store = makeStore();
  const root = await mount(dom, store);
  await receive(store, segment(1, 1, 'pending', 'First line of work\nsecond line'));
  await receive(store, segment(1, 2, 'complete', 'First line of work\nsecond line'));
  assert.equal(q(dom, 'conversation-agent-output-live-ham-epoch-1'), null, 'the live block collapses on turn end');
  const summary = q(dom, 'conversation-agent-output-summary-ham-epoch-1')!;
  assert.ok(summary);
  assert.equal(summary.getAttribute('aria-expanded'), 'false');
  assert.match(summary.textContent!, /Worked/);
  assert.match(summary.textContent!, /First line of work/);
  assert.doesNotMatch(summary.textContent!, /second line/, 'collapsed to one line');
  assert.equal(q(dom, 'conversation-agent-output-expanded-ham-epoch-1'), null);
  await act(async () => { summary.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
  const expanded = q(dom, 'conversation-agent-output-expanded-ham-epoch-1')!;
  assert.ok(expanded, 'click expands what streamed');
  assert.match(expanded.textContent!, /second line/);
  assert.equal(summary.getAttribute('aria-expanded'), 'true');
  await act(async () => { summary.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
  assert.equal(q(dom, 'conversation-agent-output-expanded-ham-epoch-1'), null, 'click collapses again');
  // A failed turn collapses too, labelled as interrupted; a newer turn ends older ones.
  await receive(store, segment(2, 1, 'failed', 'cut short'));
  assert.match(q(dom, 'conversation-agent-output-summary-ham-epoch-2')!.textContent!, /Interrupted/);
  await receive(store, segment(3, 1));
  await receive(store, segment(4, 1));
  assert.ok(q(dom, 'conversation-agent-output-summary-ham-epoch-3'), 'a new turn ends the previous one');
  assert.ok(q(dom, 'conversation-agent-output-live-ham-epoch-4'));
  await act(async () => root.unmount());
}));

test('streamed output lives only in UI memory: a reload or new mount has no blocks', () => withDom(async (dom) => {
  const store = makeStore();
  const root = await mount(dom, store);
  await receive(store, segment(1, 1, 'complete', 'secret-ish narration'));
  assert.ok(q(dom, 'conversation-agent-output'));
  for (const storage of [dom.window.localStorage, dom.window.sessionStorage]) {
    for (let i = 0; i < storage.length; i++) {
      assert.doesNotMatch(String(storage.getItem(storage.key(i)!)), /narration|msg_1_0/, 'never written to browser storage');
    }
  }
  await act(async () => root.unmount());
  // A reload is a fresh store; a fresh mount reads only that store.
  const reloaded = makeStore();
  const again = await mount(dom, reloaded);
  assert.equal(q(dom, 'conversation-agent-output'), null);
  assert.deepEqual(selectAgentOutputTurns(reloaded.getState(), 'chat_g12'), []);
  await act(async () => again.unmount());
}));

test('a new agent message drops earlier finished blocks and keeps the live turn', () => withDom(async (dom) => {
  const store = makeStore();
  const root = await mount(dom, store);
  await receive(store, segment(1, 1, 'complete'));
  await receive(store, segment(2, 1, 'complete'));
  await receive(store, segment(3, 1));
  assert.ok(q(dom, 'conversation-agent-output-summary-ham-epoch-1'));
  await act(async () => { store.dispatch(agentReplyReceived({ conversationId: 'chat_g12' })); });
  assert.equal(q(dom, 'conversation-agent-output-summary-ham-epoch-1'), null);
  assert.equal(q(dom, 'conversation-agent-output-summary-ham-epoch-2'), null);
  assert.ok(q(dom, 'conversation-agent-output-live-ham-epoch-3'), 'the streaming turn stays');
  assert.equal(selectAgentOutputTurns(store.getState(), 'chat_g12').length, 1);
  await receive(store, segment(3, 2, 'complete'));
  await act(async () => { store.dispatch(agentReplyReceived({ conversationId: 'chat_g12' })); });
  assert.equal(q(dom, 'conversation-agent-output'), null);
  await act(async () => root.unmount());
}));

test('the real WS funnel routes agent_output to the slice and an agent reply prunes it, with no fetch', async () => {
  const { installWindowShim, makeVaultStore, installFetchCapture } = await import('./helpers/vaultEndpointHarness.ts');
  installWindowShim();
  const store: any = await makeVaultStore({ extraReducers: { agentOutput: agentOutputReducer } });
  const net = installFetchCapture();
  const ws = await import('../src/ui/api/wsInvalidation.ts');
  ws.handleUserWsEvent(store.dispatch, segment(1, 1, 'complete'));
  ws.handleUserWsEvent(store.dispatch, segment(2, 1));
  assert.equal(selectAgentOutputTurns(store.getState(), 'chat_g12').length, 2);
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.equal(net.requests.length, 0, 'a streamed segment never refetches anything');
  ws.handleUserWsEvent(store.dispatch, { type: 'chat_event', event: 'chat_updated', direction: 'agent_to_user', conversation_id: 'chat_g12',
    agent_instance_id: 'inst_g12', message_id: 'msg_reply', fetch_required: true, fetch_kind: 'chat_message', fetch_id: 'msg_reply' });
  const turns = selectAgentOutputTurns(store.getState(), 'chat_g12');
  assert.deepEqual(turns.map((turn: any) => turn.turnKey), ['ham:epoch:2'], 'the reply drops finished turns before it');
  ws.resetQueuedInvalidations();
});

test('thoughts and plans stream into the same live block, plan first', () => withDom(async (dom) => {
  const store = makeStore();
  const root = await mount(dom, store);
  await receive(store, { ...segment(1, 1, 'pending', 'pondering the task'), kind: 'thought', message_id: 'msg_thought' });
  await receive(store, { ...segment(1, 1, 'pending', JSON.stringify({ sessionUpdate: 'plan', entries: [{ content: 'read code', status: 'completed' }, { content: 'write fix', status: 'pending' }] })), kind: 'plan', message_id: 'msg_plan' });
  await receive(store, segment(1, 1, 'pending', 'visible text'));
  const live = q(dom, 'conversation-agent-output-live-ham-epoch-1')!;
  const thought = q(dom, 'conversation-agent-output-ham-epoch-1-thought')!;
  const plan = q(dom, 'conversation-agent-output-ham-epoch-1-plan')!;
  assert.match(thought.className, /italic/);
  assert.match(thought.textContent!, /pondering the task/);
  assert.match(plan.textContent!, /☑read code/);
  assert.match(plan.textContent!, /☐write fix/);
  const text = live.textContent!;
  assert.ok(text.indexOf('read code') < text.indexOf('pondering') && text.indexOf('pondering') < text.indexOf('visible text'));
  // A codex-shaped plan renders too; the summary line prefers assistant text.
  await receive(store, { ...segment(1, 2, 'complete', JSON.stringify({ plan: [{ step: 'ship it', status: 'inProgress' }] })), kind: 'plan', message_id: 'msg_plan' });
  const summary = q(dom, 'conversation-agent-output-summary-ham-epoch-1')!;
  assert.match(summary.textContent!, /visible text/);
  await act(async () => { summary.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
  assert.match(q(dom, 'conversation-agent-output-ham-epoch-1-plan')!.textContent!, /◐ship it/);
  await act(async () => root.unmount());
}));
