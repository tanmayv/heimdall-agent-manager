import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { extractMessageActionIds } from '../src/ui/components/chat/types.ts';
import { actionRunTime } from '../src/ui/components/chat/actionRunTime.ts';

const metadata = {
  action_id: 'act_test2', action_name: 'Test 2', run_id: 'arun_18eab5f29854af59',
  event_type: 'schedule.fired', triggered_at: '2026-11-23T15:24:15Z',
  target_run_at: '2026-11-23T15:25:00Z', timezone: 'UTC',
};

test('automation action IDs never become approval-card references', () => {
  for (const message of [{ metadata }, { metadata: JSON.stringify(metadata) }, { metadata_json: JSON.stringify(metadata) }]) {
    assert.deepEqual(extractMessageActionIds(message), []);
  }
  assert.deepEqual(extractMessageActionIds({ metadata: { action_id: 'crd_real' } }), ['crd_real']);
});

test('actual fire time wins over scheduled slot, truncates minutes, and retains full timestamp', () => {
  assert.deepEqual(actionRunTime(metadata), { label: '2026-11-23 15:24 (UTC)', timestamp: '2026-11-23T15:24:15.000Z' });
  assert.deepEqual(actionRunTime(JSON.stringify(metadata)), actionRunTime(metadata));
  assert.deepEqual(actionRunTime({ triggered_at: 'bad' }), { label: '', timestamp: '' });
});

test('missing cards are quiet and action-run headers use neutral tokens and timestamp tooltip', () => {
  const card = fs.readFileSync(new URL('../src/ui/components/chat/ChatActionCard.tsx', import.meta.url), 'utf8');
  assert.ok(card.indexOf('if (!card) return null;') < card.indexOf('data-debug-id={`action-card-${actionId}`}'));
  const pane = fs.readFileSync(new URL('../src/ui/components/workbench/AgentChatPane.tsx', import.meta.url), 'utf8');
  const section = pane.slice(pane.indexOf("if (message.messageType === 'action')"), pane.indexOf('return (\n      <PlainMessageBody'));
  assert.match(section, /border-subtle bg-surface/);
  assert.doesNotMatch(section, /text-warning|uppercase|bg-warning/);
  assert.match(section, /title=\{fireTime.timestamp\}/);
});
