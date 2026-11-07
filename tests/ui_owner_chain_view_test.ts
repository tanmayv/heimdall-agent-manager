// R4b: a Bridge-owned chain opens in a normal chain view built from signed
// owner reads (tickets with states, brief/requirements, comments with
// timestamps, submissions, owner and archived reviews), its basic actions are
// signed owner commands, and an offline owner shows the registry metadata with
// an explicit offline state and no raw errors.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_owner_chain_view_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { fakeOwner, ownerTestSession, type OwnerCall } from './helpers/ownerFakeRelay.ts';
import { decryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { clearKeyringSession } from '../src/ui/utils/vaultKeyringSession.ts';
import type { OwnerChainSummary } from '../src/ui/api/ownerChains.ts';

// React DOM decides its event support (e.g. `input` for onChange) when it is
// first loaded, so the DOM exists before react-dom and the view are imported.
const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/', pretendToBeVisual: true });
for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
const { createRoot } = await import('react-dom/client');
const { OwnerChainView } = await import('../src/ui/components/taskchain/OwnerChainView.tsx');

function mountDom() {
  const container = dom.window.document.createElement('div');
  dom.window.document.body.appendChild(container);
  const root = createRoot(container);
  const $ = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const text = () => dom.window.document.body.textContent || '';
  const flush = async () => { for (let i = 0; i < 40; i++) await act(async () => { await new Promise((r) => setTimeout(r, 2)); }); };
  const click = async (id: string) => { const el = $(id); assert.ok(el, 'missing ' + id); await act(async () => { el!.click(); }); await flush(); };
  const type = async (id: string, value: string) => {
    const el = $(id) as HTMLInputElement | HTMLTextAreaElement;
    assert.ok(el, 'missing ' + id);
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')!.set!;
    await act(async () => { setter.call(el, value); el.dispatchEvent(new dom.window.Event('input', { bubbles: true })); });
  };
  const restore = async () => {
    await act(async () => root.unmount());
    container.remove();
  };
  return { dom, root, $, text, flush, click, type, restore };
}

function summary(env: { bridgeId: string; bridgeName: string }, extra: Partial<OwnerChainSummary> = {}): OwnerChainSummary {
  return {
    chainId: 'chain_owned', ownerBridgeId: env.bridgeId, bridgeName: env.bridgeName, online: true,
    title: 'Registry title', description: 'Registry description', sealed: false,
    tasks: [{ taskId: 'task_1', title: 'Fix login' }, { taskId: 'task_2', title: 'Write docs' }],
    projectId: '', projectName: '', migrated: true, ...extra,
  };
}

test('owner chain view renders tickets, brief, comments, submissions and reviews, and signs a comment', async () => {
  const env = await ownerTestSession();
  const { session } = env;
  const calls: OwnerCall[] = [];
  let comments = [
    { operation_id: 'cmt_legacy', principal_id: 'inst_author', body: 'Imported comment', seq: '1', created_at: '2025-04-03T12:00:00Z' },
  ];
  const send = fakeOwner(session, async (call) => {
    const task = call.command.task_id;
    switch (call.method) {
      case 'chain.read': return { chain_id: 'chain_owned', task_id: '', revision: '7', title: 'Live chain title', description: 'Live description', defaults_json: '{}',
        items: [{ task_id: 'task_1', title: 'Fix login', revision: '3', priority: 'p1' }, { task_id: 'task_2', title: 'Write docs', revision: '1', priority: 'p2' }], next_cursor: '' };
      case 'runtime.read': return task === 'task_1'
        ? { revision: '3', fleet: [], leases: [], config: [], requirements: [['2', JSON.stringify({ goal: 'Users can sign in', acceptance: ['SSO works', 'Errors are shown'] })]],
            state: [['in_review', '2', '']], submission: [['2', 'a'.repeat(40), '2', 'Implemented SSO', 'agt_worker']], controls: [],
            attempts: { attempt_no: '2', last_release: '', work_lease_id: '', completeness: 'full' } }
        : { revision: '1', fleet: [], leases: [], config: [], requirements: [], state: [], submission: [], controls: [['held', 'ready', 'waiting', '']],
            attempts: { attempt_no: '0', last_release: '', work_lease_id: '', completeness: 'full' } };
      case 'task.read': return { chain_id: 'chain_owned', task_id: task, revision: '3', title: 'Fix login', body: 'Login fails on Safari', priority: 'p1', items: comments, next_cursor: '' };
      case 'migration.archive.read': return { chain_id: 'chain_owned', migration_id: 'mig_1', next_cursor: '', items: [
        { kind: 'review', doc_index: '0', row: '0', record: JSON.stringify({ task_id: 'task_1', attempt_no: 1, role: 'security', reviewer_kind: 'agent', reviewer_agent_id: 'agt_reviewer', verdict: 'request_changes', findings_json: JSON.stringify([{ note: 'Validate the redirect' }]), created_at: '2025-04-02T09:00:00Z' }) },
      ] };
      case 'history.read': return { chain_id: 'chain_owned', next_cursor: '', items: [
        { seq: '40', task_id: 'task_1', ts_ms: String(Date.parse('2026-11-01T10:00:00Z')), actor_kind: 'device', actor_id: session.identity.deviceId, kind: 'review.post', operation_id: 'op_r', completeness: 'full', evidence_bytes: '10' },
        { seq: '41', task_id: 'task_2', ts_ms: '1', actor_kind: 'device', actor_id: 'x', kind: 'review.post', operation_id: 'op_other', completeness: 'full', evidence_bytes: '10' },
      ] };
      case 'history.fetch': {
        assert.equal(call.payload.seq, '40', 'only the selected task’s review evidence is fetched');
        return { seq: '40', offset: '0', next_offset: '', completeness: 'full',
          evidence: JSON.stringify({ command: '{}', payload: JSON.stringify({ requirements_revision: '2', attempt: '1', head: '', verdict: 'approve', summary: 'Looks right' }), content: '', result: '{}' }) };
      }
      case 'submission.read': return { kind: 'submission', chain_id: 'chain_owned', task_id: task, attempt: call.payload.attempt, summary: 'Summary of attempt ' + call.payload.attempt,
        offset: '0', next_offset: '', head: 'b'.repeat(40), requirements_revision: '2', configuration_revision: '1', author_agent_id: 'agt_worker', output: '', native_attempt: '', attempt_completeness: 'full' };
      case 'task.comment': {
        comments = [...comments, { operation_id: call.command.operation_id, principal_id: session.identity.deviceId, body: await decryptVaultText(call.payload.body_cipher, session.keyring), seq: '2', created_at: '2026-11-07T10:00:00Z' }];
        return { chain_id: 'chain_owned', task_id: task, revision: '4' };
      }
      default: return { code: 'invalid_scope' };
    }
  }, calls);
  const ui = mountDom();
  try {
    await act(async () => ui.root.render(React.createElement(OwnerChainView, { chain: summary(env), send, session: async () => session })));
    await ui.flush();
    assert.equal(ui.$('owner-chain-title')!.textContent, 'Live chain title');
    assert.match(ui.$('owner-chain-bridge-state')!.textContent!, /Home Bridge · online/);
    assert.ok(ui.$('owner-chain-owner-badge'));
    assert.equal(ui.$('owner-chain-task-state-task_1')!.textContent, 'In review');
    assert.equal(ui.$('owner-chain-task-state-task_2')!.textContent, 'Ready');
    assert.match(ui.$('owner-chain-task-task_2')!.textContent!, /Held/);

    await ui.click('owner-chain-task-task_1');
    assert.equal(ui.$('owner-chain-task-title')!.textContent, 'Fix login');
    assert.match(ui.$('owner-chain-brief')!.textContent!, /Login fails on Safari/);
    assert.match(ui.$('owner-chain-requirements')!.textContent!, /Rev 2.*Users can sign in.*SSO works.*Errors are shown/s);
    const imported = ui.$('owner-chain-comment-cmt_legacy')!;
    assert.match(imported.textContent!, /inst_author.*Imported comment/s);
    assert.equal(imported.querySelector('time')!.getAttribute('datetime'), '2025-04-03T12:00:00Z', 'comments keep their timestamps');
    const reviews = ui.$('owner-chain-reviews')!.textContent!;
    assert.match(reviews, /Approved.*You.*attempt 1.*Looks right/s, 'owner review from event history');
    assert.match(reviews, /Changes requested.*agt_reviewer \(security\).*attempt 1.*Archived from Hub.*Validate the redirect/s, 'archived migration review');
    assert.ok(ui.$('owner-chain-attempt-1') && ui.$('owner-chain-attempt-2'), 'attempt history');
    await ui.click('owner-chain-attempt-2');
    assert.match(ui.$('owner-chain-submission')!.textContent!, /Attempt 2.*agt_worker.*Summary of attempt 2/s);
    assert.ok(ui.$('owner-chain-review-approve'), 'an in-review ticket offers a verdict');
    assert.ok(!ui.text().includes('{"'), 'no raw JSON is rendered');

    await ui.type('owner-chain-comment-input', 'Please also cover Firefox');
    await ui.click('owner-chain-comment-submit');
    const comment = calls.find((c) => c.method === 'task.comment')!;
    assert.equal(comment.command.task_id, 'task_1');
    assert.equal(comment.command.expected_revision, '3', 'the command is bound to the task revision just read');
    assert.equal(await decryptVaultText(comment.payload.body_cipher, session.keyring), 'Please also cover Firefox');
    assert.match(ui.$('owner-chain-comments')!.textContent!, /You.*Please also cover Firefox/s);
    assert.equal(ui.$('owner-chain-notice')!.textContent, 'Comment added.');

    await ui.type('owner-chain-review-summary', 'Ship it');
    await ui.click('owner-chain-review-approve');
    const review = calls.find((c) => c.method === 'review.post')!;
    assert.deepEqual({ attempt: review.payload.attempt, head: review.payload.head, rr: review.payload.requirements_revision, verdict: review.payload.verdict, summary: review.payload.summary },
      { attempt: '2', head: 'a'.repeat(40), rr: '2', verdict: 'approve', summary: 'Ship it' });

    await ui.click('owner-chain-hold');
    assert.equal(calls.filter((c) => c.method === 'task.hold').length, 1);

    await ui.click('owner-chain-debug-toggle');
    assert.ok(ui.dom.window.document.querySelector('[aria-label="Owner-local tasks"]'), 'the raw console stays reachable behind Advanced/debug');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('an offline owner shows registry metadata and an explicit offline state, with no raw error', async () => {
  const env = await ownerTestSession('brg_away', 'Laptop');
  const calls: OwnerCall[] = [];
  const send = fakeOwner(env.session, () => 'offline', calls);
  const ui = mountDom();
  try {
    // Listed offline: nothing is requested from the owner.
    await act(async () => ui.root.render(React.createElement(OwnerChainView, { chain: summary(env, { online: false }), send, session: async () => env.session })));
    await ui.flush();
    assert.equal(calls.length, 0);
    assert.equal(ui.$('owner-chain-offline')!.textContent, 'Owner Bridge Laptop is offline — details and changes unavailable');
    assert.equal(ui.$('owner-chain-title')!.textContent, 'Registry title');
    assert.match(ui.text(), /Fix login/);
    assert.match(ui.text(), /Write docs/);
    assert.equal(ui.$('owner-chain-error'), null);
    assert.equal(ui.$('owner-chain-create-task-form'), null, 'no changes are offered offline');

    // Listed online but unreachable: the relay answer becomes the same state.
    await act(async () => ui.root.render(React.createElement(OwnerChainView, { key: 'b', chain: summary(env, { online: true }), send, session: async () => env.session })));
    await ui.flush();
    assert.ok(calls.length > 0);
    assert.equal(ui.$('owner-chain-offline')!.textContent, 'Owner Bridge Laptop is offline — details and changes unavailable');
    assert.equal(ui.$('owner-chain-error'), null);
    assert.ok(!/owner_unavailable/.test(ui.text()), 'the raw code never shows');
  } finally {
    await ui.restore();
    clearKeyringSession();
  }
});

test('owner refusals are worded, not raw codes', async () => {
  const { ownerErrorMessage } = await import('../src/ui/api/ownerChains.ts');
  assert.equal(ownerErrorMessage(new Error('stale_revision')), 'The chain changed on its owner Bridge. It has been reloaded; try again.');
  assert.equal(ownerErrorMessage(new Error('some_new_code')), 'The owner Bridge refused the request (some new code).');
  assert.equal(ownerErrorMessage(new Error('{"weird":1}')), 'The owner Bridge request failed. Try again.');
  assert.equal(ownerErrorMessage(new Error('owner_unavailable'), 'Desk'), 'Owner Bridge Desk is offline — details and changes unavailable');
});
