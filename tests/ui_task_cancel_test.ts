// Task cancel from the web UI: every caller sends the hub's cancel contract
// ({reason, request_id}; the hub refuses `{}` with 400), reads the
// {task, changed, cleanup_pending, message} result, and surfaces a refusal.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_cancel_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installFetchCapture, makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import { DEFAULT_TASK_CANCEL_REASON, taskCancelBody } from '../src/ui/api/taskCancel.ts';

const CANCEL_URL = /\/task-chains\/chain_1\/tasks\/task_1\/cancel$/;

const hubResult = {
  data: { task: { task_id: 'task_1', chain_id: 'chain_1', state: 'cancelled' }, changed: true, cleanup_pending: false, message: '' },
};

async function cancelMutation() {
  const store = await makeVaultStore();
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  return (arg: { chainId: string; taskId: string; reason?: string }) => store.dispatch(tasksApi.endpoints.cancelTaskDetail.initiate(arg));
}

test('taskCancelBody always carries a reason and a fresh request_id', () => {
  const a = taskCancelBody();
  const b = taskCancelBody('  Replaced by task_9  ');
  assert.equal(a.reason, DEFAULT_TASK_CANCEL_REASON);
  assert.equal(b.reason, 'Replaced by task_9');
  assert.equal(taskCancelBody('   ').reason, DEFAULT_TASK_CANCEL_REASON);
  assert.ok(a.request_id && b.request_id && a.request_id !== b.request_id, 'each cancel is its own request');
});

test('cancelTaskDetail posts the cancel contract and returns the hub result', async () => {
  const capture = installFetchCapture();
  capture.setNextResponse(hubResult);
  const cancel = await cancelMutation();

  const result: any = await cancel({ chainId: 'chain_1', taskId: 'task_1' });
  const sent = capture.find((r) => CANCEL_URL.test(r.url));
  assert.equal(sent.method, 'POST');
  assert.equal(sent.body.reason, DEFAULT_TASK_CANCEL_REASON);
  assert.equal(typeof sent.body.request_id, 'string');
  assert.ok(sent.body.request_id.length > 0, 'the hub refuses a cancel without request_id');
  assert.equal(result.error, undefined);
  assert.equal(result.data.changed, true);
  assert.equal(result.data.task.state, 'cancelled');

  capture.reset();
  await cancel({ chainId: 'chain_1', taskId: 'task_1', reason: 'Replaced by task_9' });
  assert.equal(capture.find((r) => CANCEL_URL.test(r.url)).body.reason, 'Replaced by task_9');
});

test('a hub refusal reaches the user as the hub message', async () => {
  (globalThis as any).fetch = async () => ({
    ok: false,
    status: 409,
    headers: { get: () => 'application/json' },
    text: async () => JSON.stringify({ error: { code: 'conflict', message: 'task already completed; reopen it explicitly' } }),
  });
  const cancel = await cancelMutation();
  const result: any = await cancel({ chainId: 'chain_1', taskId: 'task_1' });
  const { actionErrorMessage } = await import('../src/ui/components/tasks/useTaskActions.ts');
  assert.equal(actionErrorMessage(result.error), 'task already completed; reopen it explicitly');
});

test('the attention deck cancel sends the same contract', async () => {
  const capture = installFetchCapture();
  const { cancelTask } = await import('../src/ui/services/attention/attentionActions.ts');
  await cancelTask({ chain_id: 'chain_1', task_id: 'task_1' } as any, false);
  const sent = capture.find((r) => CANCEL_URL.test(r.url));
  assert.equal(sent.method, 'POST');
  assert.ok(sent.body.reason.trim(), 'reason is required by the hub');
  assert.ok(sent.body.request_id, 'request_id is required by the hub');
});
