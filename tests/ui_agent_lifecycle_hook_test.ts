import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { JSDOM } from 'jsdom';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { useAgentLifecycle } from '../src/ui/hooks/useAgentLifecycle.ts';
import { permissionToggleRequest } from '../src/ui/components/workbench/permissionToggleModel.ts';

async function fixture(run: (env: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost' });
  const keys = ['window', 'document', 'IS_REACT_ACT_ENVIRONMENT', 'fetch'];
  const previous = Object.fromEntries(keys.map(key => [key, (globalThis as any)[key]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const calls: any[] = [], inline: any[] = [], toasts: any[] = [];
  let reply: any = { data: { agent_instance_id: 'inst_a', operation_id: 'op_a', phase: 'prepared' } };
  let status = 202;
  let gate: Promise<void> | undefined;
  globalThis.fetch = (async (url: any, init: any) => {
    calls.push({ url: String(url), body: init.body ? JSON.parse(init.body) : undefined });
    if (gate) await gate;
    const body = JSON.stringify(reply);
    return { ok: status < 400, status, headers: { get: () => 'application/json' }, text: async () => body };
  }) as any;
  const store = await makeVaultStore();
  let actions!: ReturnType<typeof useAgentLifecycle>;
  let useInline = true;
  function View() {
    actions = useAgentLifecycle({ inline: useInline ? result => { if (result) inline.push(result); } : undefined, toast: entry => toasts.push(entry) });
    return React.createElement('button', { disabled: actions.isPending() }, actions.result?.message || 'Ready');
  }
  const root = createRoot(document.getElementById('root')!);
  const render = () => act(async () => { root.render(React.createElement(Provider, { store, children: React.createElement(View) })); });
  await render();
  try {
    await run({ calls, inline, toasts, actions: () => actions,
      button: () => document.querySelector('button')!,
      respond: (next: any, code = 202) => { reply = next; status = code; },
      hold: () => { let release!: () => void; gate = new Promise(resolve => { release = resolve; }); return () => { gate = undefined; release(); }; },
      toastOnly: async () => { useInline = false; await render(); },
    });
  } finally {
    await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); });
    dom.window.close();
    for (const key of keys) (globalThis as any)[key] = previous[key];
  }
}

test('double click issues one start; pending disables controls and 202 says requested', async () => {
  await fixture(async env => {
    const release = env.hold();
    let first: any, second: any;
    await act(async () => {
      first = env.actions().start({ instanceId: 'inst_a' });
      second = env.actions().start({ instanceId: 'inst_a' });
    });
    assert.equal(first, second);
    assert.equal(env.button().disabled, true);
    assert.equal(env.calls.length, 1);
    await act(async () => { release(); await first; });
    assert.equal(env.button().disabled, false);
    assert.equal(env.button().textContent, 'Start requested.');
    assert.equal(env.inline.length, 1);
    assert.equal(env.toasts.length, 0, 'inline sink suppresses toast');
  });
});

test('only structured already_running on Start is benign; failed conflicts remain visible', async () => {
  await fixture(async env => {
    for (const [action, details, expected] of [
      ['start', { code: 'already_running' }, 'already-running'],
      ['restart', { code: 'already_running' }, 'failed'],
      ['start', { code: 'start_raced' }, 'failed'],
      ['start', undefined, 'failed'],
    ] as const) {
      env.respond({ error: { code: 'conflict', message: 'already running', details } }, 409);
      let result: any;
      await act(async () => { result = await env.actions()[action]({ instanceId: 'inst_a' }); });
      assert.equal(result.status, expected);
      assert.equal(env.button().textContent, result.message);
      if (expected === 'failed') assert.equal(result.httpStatus, 409);
    }
    assert.equal(env.toasts.length, 0);
    await env.toastOnly();
    env.respond({ error: { message: 'Bridge offline', details: { code: 'bridge_offline' } } }, 503);
    await act(async () => { await env.actions().stop({ agentId: 'agt_a', instanceId: 'inst_a' }); });
    assert.deepEqual(env.toasts, [{ tone: 'danger', title: 'Bridge offline' }]);
    assert.equal(env.calls.length, 5, 'failed requests are never automatically retried');
  });
});

test('create, stop and restart preserve transport intent and asynchronous feedback', async () => {
  await fixture(async env => {
    await act(async () => {
      const result = await env.actions().create({ agentId: 'agt_a', provider: 'codex', providerProfile: 'work', projectId: '' });
      assert.equal(result.status, 'accepted');
      assert.equal(result.data.agent_instance_id, 'inst_a');
    });
    assert.deepEqual(env.calls[0].body, { agent_id: 'agt_a', provider: 'codex', provider_profile: 'work', project_id: '' });
    await act(async () => { await env.actions().stop({ agentId: 'agt_a', instanceId: 'inst_a', force: true }); });
    assert.equal(env.button().textContent, 'Stop requested.');
    assert.deepEqual(env.calls[1].body, { force: true, reason: 'user_force_stop' });
    await act(async () => { await env.actions().restart({ instanceId: 'inst_a' }); });
    assert.match(env.calls[2].url, /\/inst_a\/restart$/);
    assert.equal(env.button().textContent, 'Restart requested.');
  });
});

test('reconfigure and retry keep durable identity, expected revisions and permission mode', async () => {
  await fixture(async env => {
    const request = permissionToggleRequest({ agent_instance_id: 'inst_a', bridge_id: 'brg_a', project_id: 'proj_a', provider: 'codex', provider_profile: 'work', model: 'm_a', configuration_revision: 7 } as any, true, 'stable-intent');
    env.respond({ error: { message: 'Disconnected' } }, 503);
    await act(async () => { await env.actions().reconfigure(request); });
    env.respond({ data: { operation_id: 'op_a', idempotency_key: 'stable-intent', revision: 9, phase: 'recovery_required' } });
    await act(async () => { await env.actions().reconfigure(request); });
    const { instanceId, ...body } = request;
    assert.deepEqual(env.calls[0].body, body);
    assert.deepEqual(env.calls[1].body, body, 'explicit retry of same intent preserves key');
    assert.equal(body.permission_mode, 'yolo');
    assert.equal(body.expected_revision, 7);
    await act(async () => {
      await env.actions().retry({ instanceId, idempotency_key: 'stable-intent', expected_operation_revision: 9 });
    });
    assert.match(env.calls[2].url, /\/reconfigurations\/retry$/);
    assert.deepEqual(env.calls[2].body, { idempotency_key: 'stable-intent', expected_operation_revision: 9 });
  });
});
