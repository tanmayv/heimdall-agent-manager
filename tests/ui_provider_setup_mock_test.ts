import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  MOCK_PROVIDER_SETUP_RESPONSE,
  cloneProviderSetupResponse,
  providerSetupMockApi,
} from '../src/ui/components/providers/providerSetupMockApi.ts';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('mock response mirrors bridge discovery, auth, selection, and verification state', () => {
  const payload = cloneProviderSetupResponse();
  assert.equal(payload.data.bridge.bridge_id, 'brg_mock_dawnstar');
  assert.equal(payload.data.discovery.state, 'complete');
  assert.deepEqual(payload.data.providers.map((provider) => provider.provider), [
    'claude',
    'codex',
    'copilot',
    'antigravity',
  ]);
  assert.equal('verification' in payload.data.providers[0].models[0], false);
  assert.match(payload.data.providers[0].icon_url, /^data:image\/svg\+xml,/);

  payload.data.providers[0].enabled = false;
  assert.equal(MOCK_PROVIDER_SETUP_RESPONSE.data.providers[0].enabled, true);
});

test('selection mutation enables a provider without model-level selection', async () => {
  const current = cloneProviderSetupResponse();
  const { response, mutation } = await providerSetupMockApi.saveSelection(
    current,
    'antigravity',
    true,
  );
  const provider = response.data.providers.find((item) => item.provider === 'antigravity');
  assert.equal(provider?.enabled, true);
  assert.equal('verification' in (provider?.models[1] || {}), false);
  assert.equal('enabled_models' in mutation.data, false);
});

test('test runs are ephemeral and require start-success plus explicit validation before stop', async () => {
  const setup = cloneProviderSetupResponse();
  const started = await providerSetupMockApi.startTestRun(setup, 'claude', 'claude-opus-5');
  assert.equal(started.data.state, 'detecting');
  assert.equal(started.data.ephemeral, true);
  assert.equal(started.data.start_success_at, null);
  assert.match(started.data.agent_instance_id, /^probe_claude_/);

  const ready = await providerSetupMockApi.reportStartSuccess(started);
  assert.equal(ready.data.state, 'awaiting_validation');
  assert.ok(ready.data.start_success_at);
  assert.equal(ready.data.stopped_at, null);

  const stopped = await providerSetupMockApi.validateAndStopTestRun(ready);
  assert.equal(stopped.data.state, 'stopped');
  assert.ok(stopped.data.stopped_at);
  assert.equal('verification' in setup.data.providers[0].models[0], false);
});

test('provider setup has standalone enrollment and settings entry points', () => {
  const shell = fs.readFileSync(path.join(repoRoot, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
  const settings = fs.readFileSync(path.join(repoRoot, 'src/ui/components/settings/ProvidersPanel.tsx'), 'utf8');
  const surface = fs.readFileSync(path.join(repoRoot, 'src/ui/components/providers/ProviderSetupSurface.tsx'), 'utf8');
  const testModal = fs.readFileSync(path.join(repoRoot, 'src/ui/components/providers/ProviderTestRunModal.tsx'), 'utf8');

  assert.match(shell, /path === '\/device\/providers'/);
  assert.match(shell, /provider-enrollment-standalone-page/);
  assert.match(settings, /ProviderSetupSurface mode="settings"/);
  assert.match(surface, /provider-setup-enable-\$\{provider\.provider\}/);
  assert.doesNotMatch(surface, /provider-model-enable-/);
  assert.match(surface, /provider-model-test-\$\{provider\.provider\}-\$\{model\.model_id\}/);
  assert.match(testModal, /provider-test-run-output/);
  assert.match(testModal, /Waiting for start-success/);
  assert.match(testModal, /provider-test-validate-btn/);
  assert.match(testModal, /No result was persisted to the Hub or bridge/);
  assert.match(surface, /provider-setup-apply-btn/);
  assert.doesNotMatch(surface, /provider-setup-skip-btn|provider-setup-finish-btn/);
  assert.match(surface, /Mock API/);
});
