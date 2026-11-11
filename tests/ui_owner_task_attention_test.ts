// Owner-chain tasks in the Needs-attention deck/tray (design B): the Hub
// relays an owner Bridge's in-memory "needs you" flags as task items with card
// id otask:<bridge>:<chain>:<task> (provider owner_task). Their actions run as
// signed owner operations through the owner relay, never as Hub card ops.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_task_attention_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fakeOwner, ownerTestSession, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { ownerTaskAnswer, ownerTaskCardRef, ownerTaskStartAgent, ownerTaskVerdict } from '../src/ui/services/attention/ownerTaskActions.ts';
import { normalizeAttentionItems } from '../src/ui/api/endpoints/attention.ts';
import { needsAgentStart } from '../src/ui/components/attention/StartAgentAction.tsx';

test('ownerTaskCardRef names the owner task of an otask card only', () => {
  assert.deepEqual(ownerTaskCardRef('otask:brg_home:chain_1:T-1'), { bridgeId: 'brg_home', chainId: 'chain_1', taskId: 'T-1' });
  assert.equal(ownerTaskCardRef('crd_task_task_1'), null);
  assert.equal(ownerTaskCardRef('blk:abc'), null);
  assert.equal(ownerTaskCardRef('otask:brg_home:chain_1'), null);
  assert.equal(ownerTaskCardRef('otask::chain_1:T-1'), null);
});

test('owner task items are named by id and say what they wait for (the Hub has no content)', () => {
  const base = { card_id: 'otask:brg_home:chain_1:T-1', kind: 'task', provider: 'owner_task', title: '', rationale: '', operations: [], action_refs: { chain_id: 'chain_1', task_id: 'T-1', bridge_id: 'brg_home' } };
  const [blocked, review, notRunning, hub] = normalizeAttentionItems([
    { ...base, details: { attention: 'blocked', badge: 'question', state: 'ready', attempt_no: 1, owner_chain: true } },
    { ...base, card_id: 'otask:brg_home:chain_1:T-2', details: { attention: 'review', badge: 'review', state: 'in_review', attempt_no: 2, owner_chain: true } },
    { ...base, card_id: 'otask:brg_home:chain_1:T-3', details: { attention: 'blocked', badge: 'agent_not_running', state: 'ready', attempt_no: 0, owner_chain: true } },
    { ...base, card_id: 'crd_task_x', provider: 'task_validation', title: 'vault:v2:x', details: { attention: 'review' } },
  ]);
  assert.equal(blocked.title, 'Ticket T-1');
  assert.equal(blocked.rationale, 'Waiting for your answer');
  assert.equal(review.rationale, 'Waiting for your approval');
  assert.equal(notRunning.rationale, 'Its agent is not running');
  assert.equal(hub.title, 'vault:v2:x', 'Hub cards are untouched');
});

test('Answer comments on the owner task, then resolves it at the fresh revision', async () => {
  const env = await ownerTestSession();
  let rev = 4;
  const calls: OwnerCall[] = [];
  const send = fakeOwner(env.session, (call) => {
    if (call.method === 'task.read') return { title: 'T', body: '', priority: 'p2', revision: String(rev), items: [], next_cursor: '' };
    if (call.method === 'task.comment') { rev += 1; return { ok: '1' }; }
    if (call.method === 'task.resolve') { rev += 1; return { ok: '1' }; }
    return { code: 'invalid_scope' };
  }, calls, { chain: () => '1', task: () => String(rev) });
  try {
    await ownerTaskAnswer({ bridgeId: env.bridgeId, chainId: 'chain_1', taskId: 'T-1' }, '  Use the staging DB  ', { session: async () => env.session, send });
    const writes = calls.filter((c) => c.method !== 'task.read');
    assert.deepEqual(writes.map((c) => c.method), ['task.comment', 'task.resolve']);
    assert.equal(writes[0].command.task_id, 'T-1');
    assert.equal(writes[0].command.expected_revision, '4');
    assert.equal(await decryptVaultText(writes[0].payload.body_cipher, env.session.keyring), 'Use the staging DB', 'the answer travels encrypted');
    assert.equal(writes[1].command.expected_revision, '5');
    await assert.rejects(ownerTaskAnswer({ bridgeId: env.bridgeId, chainId: 'chain_1', taskId: 'T-1' }, '  ', { session: async () => env.session, send }));
  } finally { clearKeyringSession(); }
});

test('Approve / Request changes post the user review on the current submission', async () => {
  const env = await ownerTestSession();
  const calls: OwnerCall[] = [];
  const head = 'a'.repeat(40);
  const send = fakeOwner(env.session, (call) => {
    if (call.method === 'runtime.read') return { revision: '9', state: [['in_review', '2']], requirements: [['3', '{}']], submission: [['2', head, '3', 'did it', 'agt_w']], leases: [], attempts: { attempt_no: 2 } };
    if (call.method === 'task.read') return { title: 'T', body: '', priority: 'p2', revision: '9', items: [], next_cursor: '' };
    if (call.method === 'review.post') return { ok: '1' };
    return { code: 'invalid_scope' };
  }, calls, { chain: () => '1', task: () => '9' });
  const ref = { bridgeId: env.bridgeId, chainId: 'chain_1', taskId: 'T-2' };
  try {
    await ownerTaskVerdict(ref, 'approve', '', { session: async () => env.session, send });
    await ownerTaskVerdict(ref, 'request_changes', 'Add a test', { session: async () => env.session, send });
    const posts = calls.filter((c) => c.method === 'review.post');
    assert.equal(posts.length, 2);
    assert.equal(posts[0].payload.verdict, 'approve');
    assert.equal(posts[0].payload.summary, 'Approved.');
    assert.equal(posts[0].payload.attempt, '2');
    assert.equal(posts[0].payload.head, head);
    assert.equal(posts[0].payload.requirements_revision, '3');
    assert.equal(posts[1].payload.verdict, 'request_changes');
    assert.equal(posts[1].payload.summary, 'Add a test');
    await assert.rejects(ownerTaskVerdict(ref, 'request_changes', ' ', { session: async () => env.session, send }));
    // The deck item showed attempt 2: a verdict for it goes through.
    await ownerTaskVerdict(ref, 'approve', '', { session: async () => env.session, send }, 2);
    assert.equal(calls.filter((c) => c.method === 'review.post').length, 3);
    // The worker resubmitted after the item showed attempt 1: refused, nothing posted.
    await assert.rejects(ownerTaskVerdict(ref, 'approve', '', { session: async () => env.session, send }, 1), /resubmitted/);
    await assert.rejects(ownerTaskVerdict(ref, 'request_changes', 'Fix it', { session: async () => env.session, send }, 1), /resubmitted/);
    assert.equal(calls.filter((c) => c.method === 'review.post').length, 3);
  } finally { clearKeyringSession(); }
});

test('Start agent is offered for an owner agent_not_running item and resolves the block', async () => {
  const refs = { chain_id: 'chain_1', task_id: 'T-3', bridge_id: 'brg_home' };
  const [down, question] = normalizeAttentionItems([
    { card_id: 'otask:brg_home:chain_1:T-3', kind: 'task', provider: 'owner_task', title: '', operations: [], action_refs: refs, details: { attention: 'blocked', badge: 'agent_not_running', state: 'ready', attempt_no: 0, owner_chain: true } },
    { card_id: 'otask:brg_home:chain_1:T-1', kind: 'task', provider: 'owner_task', title: '', operations: [], action_refs: refs, details: { attention: 'blocked', badge: 'question', state: 'ready', attempt_no: 1, owner_chain: true } },
  ]);
  assert.equal(needsAgentStart(down), true);
  assert.equal(needsAgentStart(question), false, 'a question is answered, not started');

  const env = await ownerTestSession();
  const calls: OwnerCall[] = [];
  const send = fakeOwner(env.session, (call) => {
    if (call.method === 'task.read') return { title: 'T', body: '', priority: 'p2', revision: '7', items: [], next_cursor: '' };
    if (call.method === 'task.resolve') return { ok: '1' };
    return { code: 'invalid_scope' };
  }, calls, { chain: () => '1', task: () => '7' });
  try {
    await ownerTaskStartAgent({ bridgeId: env.bridgeId, chainId: 'chain_1', taskId: 'T-3' }, { session: async () => env.session, send });
    const writes = calls.filter((c) => c.method !== 'task.read');
    assert.deepEqual(writes.map((c) => c.method), ['task.resolve']);
    assert.equal(writes[0].command.task_id, 'T-3');
    assert.equal(writes[0].command.expected_revision, '7');
  } finally { clearKeyringSession(); }
});
