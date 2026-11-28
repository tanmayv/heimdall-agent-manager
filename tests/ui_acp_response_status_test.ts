import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import AgentActivityBubbles from '../src/ui/components/chat/AgentActivityBubbles.tsx';
import ChatMessageList from '../src/ui/components/chat/ChatMessageList.tsx';
import reducer, { agentActionReceived } from '../src/ui/store/agentActivitySlice.ts';
import AgentOutputBlocks from '../src/ui/components/chat/AgentOutputBlocks.tsx';
import agentOutputReducer, { agentOutputSegmentReceived, hasLiveAgentOutput, selectAgentOutputTurns } from '../src/ui/store/agentOutputSlice.ts';

test('ACP Responding lives in the tail and disappears immediately when the streamed turn completes or fails', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT',
    'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window) });
  dom.window.HTMLElement.prototype.scrollTo = () => {};
  const store = configureStore({ reducer: { agentActivity: reducer, agentOutput: agentOutputReducer, vault: (s = {}) => s } });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  let turn = 0; let revision = 0; let finished = true;
  const render = async (status: string, working = true) => {
    if (status === 'pending' && finished) { turn += 1; finished = false; }
    if (status !== 'pending') finished = true;
    revision += 1;
    store.dispatch(agentOutputSegmentReceived({ conversationId: 'chat', agentInstanceId: 'inst_a', turnId: `ham:epoch:${turn}`,
      messageId: `msg_${turn}`, revision, status, stopReason: status === 'complete' ? 'end_turn' : '', body: 'Streamed partial response' }));
    const turns = selectAgentOutputTurns(store.getState(), 'chat');
    await act(async () => root.render(React.createElement(Provider, { store, children:
      React.createElement('div', {}, React.createElement(ChatMessageList, {
        conversationKey: 'chat', debugPrefix: 'test-thread', messages: [],
        renderMessageBody: ({ message }: any) => message.body,
        agentActivity: React.createElement(React.Fragment, {},
          React.createElement(AgentOutputBlocks, { conversationId: 'chat' }),
          React.createElement(AgentActivityBubbles, { instanceId: 'inst_a',
            isWorking: working, isResponding: hasLiveAgentOutput(turns) })),
      }), React.createElement('aside', { 'data-debug-id': 'attention-deck' }, 'Needs your approval'))
    })));
  };
  try {
    for (const width of [390, 1280]) {
      Object.defineProperty(dom.window, 'innerWidth', { value: width, configurable: true });
      await render('pending');
      const status = q('conversation-activity-responding')!;
      assert.equal(status.textContent, 'Responding…');
      assert.ok(q('conversation-activity-bubbles')!.contains(status));
      assert.ok(q('test-thread-scroll')!.contains(status), 'status is inside the conversation scroller');
      assert.ok(q('test-thread-messages-container')!.contains(status));
      assert.equal(q('attention-deck')!.contains(status), false);
      assert.doesNotMatch(q('conversation-activity-bubbles')!.className, /absolute|fixed|sticky/);
      const transcript = q('test-thread-messages-container')!;
      assert.match(transcript.textContent!, /Streamed partial response/);
      assert.ok(transcript.textContent!.indexOf('Streamed partial response') < transcript.textContent!.indexOf('Responding…'));
      await render('complete');
      assert.equal(q('conversation-activity-responding'), null, 'completion removes Responding while runtime still reports working');
      assert.match(q('conversation-activity-bubbles')!.textContent!, /Working…/);
      await render('complete', false);
      assert.equal(q('conversation-activity-bubbles'), null, 'an idle ACP runtime clears Working after its response completes');
      await render('pending');
      await render('failed', false);
      assert.equal(q('conversation-activity-responding'), null, 'failure removes Responding without a fade delay');
      assert.equal(q('conversation-activity-bubbles'), null);
    }
    await act(async () => store.dispatch(agentActionReceived({ instanceId: 'inst_a',
      action: 'task_show', summary: 'opened a task', ts: Date.now() })));
    await render('pending');
    assert.equal(q('conversation-activity-responding'), null, 'fresh actions retain priority over the fallback status');
    assert.match(q('conversation-activity-bubbles')!.textContent!, /Reading task/);
    await render('complete');
    assert.equal(q('conversation-activity-responding'), null);
    assert.match(q('conversation-activity-bubbles')!.textContent!, /Reading task/);
    assert.equal(hasLiveAgentOutput([]), false);
    const pane = fs.readFileSync('src/ui/components/workbench/AgentChatPane.tsx', 'utf8');
    assert.match(pane, /isResponding=\{hasLiveAgentOutput\(agentOutputTurns\)\}/);
    assert.match(pane, /<AgentOutputBlocks conversationId=\{conversationId\} \/>/);
    assert.doesNotMatch(pane, /conversation-assistant-pending-|>Responding…</);
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    Object.assign(globalThis, previous);
  }
});
