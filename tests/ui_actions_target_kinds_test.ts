import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { offeredTargetKinds } from '../src/ui/components/actions/ActionFormPage.tsx';
test('bot target appears only when offered by the server', () => {
  assert.deepEqual(offeredTargetKinds(['agent', 'instance']).map(k => k.value), ['agent', 'instance']);
  assert.deepEqual(offeredTargetKinds(['agent', 'instance', 'bot']).map(k => k.value), ['agent', 'instance', 'bot']);
});

test('bot selection defaults to the owner after loading and preserves explicit targets', async () => {
  const { defaultBotTarget } = await import('../src/ui/components/actions/actionModel.ts');
  assert.deepEqual(defaultBotTarget({ kind: 'bot', bot_id: '' }, 'bot_owner'), { kind: 'bot', bot_id: 'bot_owner' });
  assert.deepEqual(defaultBotTarget({ kind: 'bot', bot_id: '' }), { kind: 'bot', bot_id: '' });
  assert.deepEqual(defaultBotTarget({ kind: 'bot', bot_id: 'bot_selected' }, 'bot_owner'), { kind: 'bot', bot_id: 'bot_selected' });
  assert.deepEqual(defaultBotTarget({ kind: 'instance', instance_id: 'inst_1' }, 'bot_owner'), { kind: 'instance', instance_id: 'inst_1' });
});
