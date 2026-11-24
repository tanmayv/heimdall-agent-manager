import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { offeredTargetKinds } from '../src/ui/components/actions/ActionFormPage.tsx';
test('bot target appears only when offered by the server', () => {
  assert.deepEqual(offeredTargetKinds(['agent', 'instance']).map(k => k.value), ['agent', 'instance']);
  assert.deepEqual(offeredTargetKinds(['agent', 'instance', 'bot']).map(k => k.value), ['agent', 'instance', 'bot']);
});
