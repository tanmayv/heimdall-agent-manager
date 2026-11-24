import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emptyActionForm, formFromAction, actionFormBody, mapServerError, matchesTab } from '../src/ui/components/actions/actionModel.ts';
import { actionsApi } from '../src/ui/api/endpoints/actions.ts';
import { makeVaultStore, installFetchCapture } from './helpers/vaultEndpointHarness.ts';

const record: any = { id: 'act_1', owner_user_id: 'u', name: 'Review', prompt_text: 'Review {{event.type}}', enabled: true, min_interval_s: 30, target: { kind: 'agent', agent_id: 'agt_1', project_id: '', instance_strategy: 'reuse', selector: 'first', rules: [{ bridge_id: '*', provider: 'claude', model: '*' }] }, triggers: [{ id: 'trg_1', kind: 'schedule', enabled: true, rev: 2, next_fire_at: '2026-12-01T09:00:00Z', config: { mode: 'cron', cron_expr: '0 9 * * 1-5', timezone: 'America/New_York', blackout_dates: ['2026-12-25'] } }, { id: 'trg_2', kind: 'event', enabled: false, delay_s: 600, config: { event_type: 'chain.state', entity_id: 'chain_1', filter: { all: [{ field: 'data.state', op: 'eq', value: 'completed' }] } } }], created_at: '', updated_at: '' };
test('API v2 form round trip preserves target, config and trigger IDs; removal omits trigger', () => {
  const form = formFromAction(record);
  const body = actionFormBody(form);
  assert.deepEqual(body.target, record.target);
  assert.deepEqual(body.triggers?.map(t => t.id), ['trg_1', 'trg_2']);
  assert.deepEqual(body.triggers?.[0].config, record.triggers[0].config);
  assert.equal(body.triggers?.[1].delay_s, 600);
  assert.equal('rev' in body.triggers![0], false);
  form.triggers.splice(0, 1);
  assert.deepEqual(actionFormBody(form).triggers?.map(t => t.id), ['trg_2']);
  assert.equal(record.triggers.length, 2);
  assert.equal(emptyActionForm(45).min_interval_s, 45);
});
test('filters cover all, schedule, event and no trigger', () => {
  for (const tab of ['all', 'scheduled', 'event'] as const) assert.equal(matchesTab(record, tab), true);
  assert.equal(matchesTab(record, 'none'), false);
  assert.equal(matchesTab({ ...record, triggers: [] }, 'none'), true);
});
test('validation detail codes map to the responsible form field', () => {
  for (const [code, field] of Object.entries({ prompt_required: 'prompt_text', min_interval_out_of_range: 'min_interval_s', unknown_bridge: 'target', invalid_strategy: 'target', invalid_cron: 'triggers', schedules_unsupported: 'triggers', unknown_chain: 'triggers', delay_out_of_range: 'triggers' })) {
    assert.equal(mapServerError({ error: 'Bad value', data: { details: { code } } }).field, field);
  }
});
test('real endpoints send nested JSON, partial PATCH, feature, enable/disable and before cursor', async () => {
  const capture = installFetchCapture(); const store = await makeVaultStore();
  try {
    capture.setNextResponse({ data: record });
    await store.dispatch(actionsApi.endpoints.createAction.initiate(actionFormBody(formFromAction(record)))).unwrap();
    assert.deepEqual(capture.requests.at(-1)?.body.target, record.target);
    assert.ok(Array.isArray(capture.requests.at(-1)?.body.triggers[0].config.blackout_dates));
    await store.dispatch(actionsApi.endpoints.patchAction.initiate({ id: 'act_1', name: 'New' })).unwrap();
    assert.deepEqual(capture.requests.at(-1)?.body, { name: 'New' });
    await store.dispatch(actionsApi.endpoints.setActionEnabled.initiate({ id: 'act_1', enabled: false })).unwrap();
    assert.match(capture.requests.at(-1)!.url, /act_1\/disable$/);
    await store.dispatch(actionsApi.endpoints.setActionEnabled.initiate({ id: 'act_1', enabled: true })).unwrap();
    assert.match(capture.requests.at(-1)!.url, /act_1\/enable$/);
    capture.setNextResponse({ data: { candidates: [], bridges: [], providers: [] } });
    await store.dispatch(actionsApi.endpoints.actionPlacementCandidates.initiate({ agent_id: 'agt_1' })).unwrap();
    assert.match(capture.requests.at(-1)!.url, /feature=event_pipeline_v1/);
    capture.setNextResponse({ data: [] });
    await store.dispatch(actionsApi.endpoints.actionRuns.initiate({ id: 'act_1', before: '2026-01-01T00:00:00Z', before_id: 'run_2' })).unwrap();
    assert.equal(new URL(capture.requests.at(-1)!.url, 'http://hub').searchParams.get('before'), '2026-01-01T00:00:00Z');
    assert.equal(new URL(capture.requests.at(-1)!.url, 'http://hub').searchParams.get('before_id'), 'run_2');
  } finally { store.dispatch(actionsApi.util.resetApiState()); }
});
