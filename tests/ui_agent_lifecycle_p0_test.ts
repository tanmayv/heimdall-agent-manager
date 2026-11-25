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

for (const [name, run] of [
  ['launchAgentInstance', (store: any) => store.dispatch(agents.agentsApi.endpoints.launchAgentInstance.initiate({ agentId: 'agt_a', bridgeId: 'brg_a', provider: 'claude', providerProfile: 'claude-work', model: 'opus', projectId: 'proj_a' }))],
  ['createAgentInstanceInChain', (store: any) => store.dispatch(agents.agentsApi.endpoints.createAgentInstanceInChain.initiate({ agentId: 'agt_a', chainId: 'chain_a', provider: 'claude', providerProfile: 'claude-work', model: 'opus' }))],
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

test('isAlreadyRunningError recognises 409 / already_running only', () => {
  assert.equal(agents.isAlreadyRunningError({ status: 409 }), true);
  assert.equal(agents.isAlreadyRunningError({ data: { error: { message: 'already_running' } } }), true);
  assert.equal(agents.isAlreadyRunningError({ error: 'Agent already running' }), true);
  assert.equal(agents.isAlreadyRunningError({ status: 500, error: 'boom' }), false);
  assert.equal(agents.isAlreadyRunningError(undefined), false);
});

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
