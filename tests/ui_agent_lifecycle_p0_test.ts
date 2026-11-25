// P0 lifecycle fixes: launch payloads keep provider (driver) and provider_profile
// separate, start failures are classified, and the panes surface lifecycle errors.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_agent_lifecycle_p0_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const agents = await import('../src/ui/api/endpoints/agents.ts');
const { buildRuntimePayload } = await import('../src/ui/api/runtimePayload.ts');
const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
const REPO_ROOT = path.resolve(import.meta.dirname, '..');
const read = (rel: string) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');

function installCapturingFetch() {
  const calls: { key: string; body: any }[] = [];
  const previous = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    calls.push({ key: `${String(init?.method || 'GET').toUpperCase()} ${url.pathname}`, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    const body = { data: { agent_instance_id: 'inst_new' } };
    return {
      ok: true, status: 200,
      headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
      text: async () => JSON.stringify(body), json: async () => body,
    } as any;
  };
  return { calls, restore: () => { (globalThis as any).fetch = previous; } };
}

test('runtime payload distinguishes omitted and cleared project', () => {
  assert.deepEqual(buildRuntimePayload({}), {});
  assert.deepEqual(buildRuntimePayload({ projectId: undefined }), {});
  assert.deepEqual(buildRuntimePayload({ projectId: '' }), { project_id: '' });
});

for (const projectId of [undefined, '', 'proj_a']) {
  test(`instance and conversation runtime scope: project=${String(projectId)}`, async () => {
    const fetch = installCapturingFetch();
    const store = await makeVaultStore();
    const selection = { provider: 'claude', providerProfile: 'work', model: 'opus', bridgeId: 'brg_a', projectId, chainId: 'chain_a' };
    const expected = { provider: 'claude', provider_profile: 'work', model: 'opus', bridge_id: 'brg_a', chain_id: 'chain_a', ...(projectId !== undefined ? { project_id: projectId } : {}) };
    try {
      await store.dispatch(agents.agentsApi.endpoints.createAgentInstance.initiate({ agentId: 'agt_a', displayName: 'Worker', ...selection })).unwrap();
      await store.dispatch(chatEndpoints.endpoints.createLaunchConversation.initiate({ agentId: 'agt_a', ...selection, body: 'hello', artifactIds: ['art_a'] })).unwrap();
      const instance = fetch.calls.find(c => c.key.endsWith('/agent-instances') && c.key.startsWith('POST'));
      const chat = fetch.calls.find(c => c.key.endsWith('/chats') && c.key.startsWith('POST'));
      assert.deepEqual(instance?.body, { agent_id: 'agt_a', ...expected, display_name: 'Worker' });
      assert.deepEqual(chat?.body, { agent_id: 'agt_a', ...expected, initial_message: { body: 'hello' }, artifact_ids: ['art_a'] });
      assert.equal(fetch.calls.filter(c => c.key.endsWith('/agent-instances/inst_new')).length, 1);
    } finally {
      store.dispatch(heimdallApi.util.resetApiState());
      fetch.restore();
    }
  });
}

for (const [name, run] of [
  ['createAgentInstance', (store: any) => store.dispatch(agents.agentsApi.endpoints.createAgentInstance.initiate({ agentId: 'agt_a', bridgeId: 'brg_a', provider: 'claude', providerProfile: 'claude-work', model: 'opus', projectId: 'proj_a' }))],
  ['createAgentInstance with chain', (store: any) => store.dispatch(agents.agentsApi.endpoints.createAgentInstance.initiate({ agentId: 'agt_a', chainId: 'chain_a', provider: 'claude', providerProfile: 'claude-work', model: 'opus' }))],
] as const) {
  test(`${name} sends provider (driver) and provider_profile separately`, async () => {
    const fetch = installCapturingFetch();
    const store = await makeVaultStore();
    try {
      await run(store);
      const post = fetch.calls.find((c) => c.key.startsWith('POST') && c.key.endsWith('/agent-instances'));
      assert.ok(post, 'POST /agent-instances was issued');
      assert.equal(post.body.provider, 'claude');
      assert.equal(post.body.provider_profile, 'claude-work');
    } finally {
      store.dispatch(heimdallApi.util.resetApiState());
      fetch.restore();
    }
  });
}

test('isAlreadyRunningError recognises already_running only, not every 409', () => {
  assert.equal(agents.isAlreadyRunningError({ originalStatus: 409, details: { code: 'already_running' } }), true);
  assert.equal(agents.isAlreadyRunningError({ data: { error: { message: 'already_running' } } }), true);
  assert.equal(agents.isAlreadyRunningError({ error: 'Agent already running' }), true);
  // start_raced is also a 409 but is a real failure.
  assert.equal(agents.isAlreadyRunningError({ originalStatus: 409, details: { code: 'start_raced' }, error: 'instance changed before runtime action' }), false);
  assert.equal(agents.isAlreadyRunningError({ status: 409 }), false);
  assert.equal(agents.isAlreadyRunningError({ status: 500, error: 'boom' }), false);
  assert.equal(agents.isAlreadyRunningError(undefined), false);
});

// Drive the real startAgentInstance mutation against hub-shaped 409 bodies so the
// classification is checked on the error RTK actually hands the panes.
for (const [code, message, expected] of [
  ['already_running', 'instance inst_a is already running (runtime_status=running)', true],
  ['start_raced', 'instance changed before runtime action', false],
] as const) {
  test(`start mutation 409 ${code} -> isAlreadyRunningError=${expected}`, async () => {
    const previous = (globalThis as any).fetch;
    (globalThis as any).fetch = async () => {
      const body = { error: { code: 'conflict', message, details: { code } } };
      return {
        ok: false, status: 409,
        headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
        text: async () => JSON.stringify(body), json: async () => body,
      } as any;
    };
    const store = await makeVaultStore();
    try {
      const result: any = await store.dispatch(agents.agentsApi.endpoints.startAgentInstance.initiate({ instanceId: 'inst_a' }));
      assert.ok(result.error, 'start rejected');
      assert.equal(result.error.originalStatus, 409);
      assert.equal(agents.isAlreadyRunningError(result.error), expected);
      assert.equal(agents.lifecycleErrorMessage(result.error, 'x'), message);
    } finally {
      store.dispatch(heimdallApi.util.resetApiState());
      (globalThis as any).fetch = previous;
    }
  });
}

test('AgentChatPane Start uses /start, not /restart', () => {
  const src = read('src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(src, /if \(needsStart\) await startInstance\(/);
  assert.doesNotMatch(src, /if \(needsStart\) await restartInstance\(/);
});

test('lifecycle actions unwrap results and surface errors instead of swallowing them', () => {
  for (const rel of ['src/ui/components/chat/ChainOverviewPanel.tsx', 'src/ui/components/workbench/AgentPtyWorkbenchPane.tsx']) {
    const src = read(rel);
    for (const m of ['startInstance', 'stopInstance', 'restartInstance']) {
      const re = new RegExp(`await ${m}(?:Mutation)?\\(.*?\\)(\\.unwrap\\(\\))?`, 'g');
      const hits = [...src.matchAll(re)];
      assert.ok(hits.length > 0, `${rel} calls ${m}`);
      for (const h of hits) assert.ok(h[1], `${rel}: ${h[0]} must be unwrapped`);
    }
    assert.match(src, /role="alert"/, `${rel} renders lifecycle failures`);
    assert.doesNotMatch(src, /console\.error\('Failed to (start|stop|restart) agent/);
  }
});
