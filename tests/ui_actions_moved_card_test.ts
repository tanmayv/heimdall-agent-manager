import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { actionMessageContext } from '../src/ui/components/actions/actionModel.ts';
import { buildConversationHash } from '../src/ui/utils/conversationUrl.ts';
test('action metadata identifies event, merged count and moved destination', () => {
  const meta = { event_type: 'chain.state', action_name: 'Review', joined_count: 2, moved_to_instance_id: 'inst_destination', triggered_at: '2026-12-01T09:00:00Z' };
  assert.deepEqual(actionMessageContext(JSON.stringify(meta)), { eventType: 'chain.state', actionName: 'Review', joinedCount: 2, movedTo: 'inst_destination', triggeredAt: meta.triggered_at });
  assert.match(buildConversationHash([actionMessageContext(meta).movedTo]), /conversations\/inst_destination/);
  assert.equal(actionMessageContext('bad JSON').movedTo, '');
  const source = fs.readFileSync(new URL('../src/ui/components/workbench/AgentChatPane.tsx', import.meta.url), 'utf8');
  assert.match(source, /Moved to another machine/);
  assert.match(source, /buildConversationHash\(\[context.movedTo\]\)/);
  assert.match(source, /eventRun \? context.eventType/);
});
