import { test } from 'node:test';
import assert from 'node:assert/strict';
import { conversationConfigurationIssues, type ConfigurationValidityInput } from '../src/ui/utils/conversationConfigurationValidity.ts';

const valid: ConfigurationValidityInput = {
  instanceLoaded: true, instanceError: false,
  bridgeId: 'bridge-a', bridgesLoaded: true, bridgesError: false, bridge: { status: 'online' },
  projectId: 'project-a', projectLoaded: true, projectError: false, project: { state: 'active' },
  provider: 'codex', model: 'smart', capabilities: [{ provider: 'codex', models: ['smart'] }],
};
test('active configuration and projectless conversation allow messages', () => {
  assert.deepEqual(conversationConfigurationIssues(valid), []);
  assert.deepEqual(conversationConfigurationIssues({ ...valid, projectId: '', project: undefined, projectLoaded: false }), []);
});
test('missing, revoked, archived and offline bridges explain bridge repair', () => {
  for (const bridge of [undefined, { status: 'revoked' }, { status: 'archived' }, { status: 'offline' }]) {
    const issues = conversationConfigurationIssues({ ...valid, bridge });
    assert.equal(issues.length, 1);
    assert.match(issues[0], /Bridge.*(Choose|choose|Reconnect)/);
  }
});
test('archived and missing projects block even when runtime is valid', () => {
  for (const project of [undefined, { state: 'archived' }]) {
    assert.match(conversationConfigurationIssues({ ...valid, project })[0], /Project.*(active project|inactive)/);
  }
});
test('retained picker values cannot make absent provider or tier valid', () => {
  assert.match(conversationConfigurationIssues({ ...valid, capabilities: [] })[0], /Provider.*codex.*Choose an active provider/);
  assert.match(conversationConfigurationIssues({ ...valid, model: 'removed-tier' })[0], /Model\/tier.*removed-tier.*Choose an active model\/tier/);
});
test('all independent invalid bindings are reported together', () => {
  const issues = conversationConfigurationIssues({ ...valid, capabilities: [], project: { state: 'archived' } });
  assert.equal(issues.length, 2);
  assert.match(issues[0], /Provider/);
  assert.match(issues[1], /Project/);
});
test('loading and query failures block without claiming configuration was deleted', () => {
  assert.match(conversationConfigurationIssues({ ...valid, instanceLoaded: false })[0], /Checking/);
  assert.match(conversationConfigurationIssues({ ...valid, bridgesError: true })[0], /could not be verified/);
  assert.match(conversationConfigurationIssues({ ...valid, bridge: { status: 'online', provider_status_error: true } })[0], /Provider availability could not be verified/);
  assert.match(conversationConfigurationIssues({ ...valid, projectError: true })[0], /could not be verified/);
});
test('repairing provider and tier clears the read-only reason', () => {
  const unavailable = { ...valid, provider: 'old-provider' };
  assert.equal(conversationConfigurationIssues(unavailable).length, 1);
  assert.deepEqual(conversationConfigurationIssues({ ...unavailable, provider: 'codex', model: 'smart' }), []);
});
