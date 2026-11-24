import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { Provider } from 'react-redux';
import Rules, { moveRule, updateRule, bridgeOptionLabel, ANYWHERE_TEXT } from '../src/ui/components/actions/PlacementRulesEditor.tsx';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { actionFormBody, emptyActionForm } from '../src/ui/components/actions/actionModel.ts';
test('rule reorder is saved in visible order and Any provider clears model', () => {
  const a = { bridge_id: 'brg_a', provider: 'claude', model: 'opus' }, b = { bridge_id: 'brg_b', provider: 'codex', model: '*' };
  const form = emptyActionForm(); if (form.target.kind !== 'agent') throw Error();
  form.target.rules = moveRule([a, b], 1, -1);
  assert.deepEqual((actionFormBody(form).target as any).rules, [b, a]);
  assert.deepEqual(moveRule([a, b], 0, -1), [a, b]);
  assert.equal(updateRule(a, 'provider', '*').model, '*');
});
test('offline and missing-feature bridges remain labeled options; empty rules explain anywhere', async () => {
  assert.equal(bridgeOptionLabel({ bridge_id: 'b', label: 'Laptop', eligible: false, reason: 'offline' }), 'Laptop · offline');
  assert.match(bridgeOptionLabel({ bridge_id: 'b', label: 'Old', eligible: false, reason: 'missing_feature' }), /needs a bridge update to run actions/);
  const store = await makeVaultStore();
  const html = renderToStaticMarkup(React.createElement(Provider, { store, children: React.createElement(Rules, { agentId: '', value: [], onChange() {}, maxRules: 16 }) }));
  assert.ok(html.includes(ANYWHERE_TEXT));
  store.dispatch((await import('../src/ui/api/endpoints/actions.ts')).actionsApi.util.resetApiState());
});
