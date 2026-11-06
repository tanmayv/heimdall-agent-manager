import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ownerSubmissionRoute, parseChainRoute } from '../src/ui/utils/ownerSubmissionNavigation.ts';
import { homeChainsFromSearchHits } from '../src/ui/components/home/homeChainSearchLogic.ts';
import { ownerParse } from '../src/ui/api/ownerLocal.ts';

test('historical output links preserve exact task/attempt and never use current task route', () => {
  const hits = ['1','2'].map(attempt => ({ chain_id:'chain:one', task_id:'task:one', kind:'output', attempt,
    title:'Chain — submission attempt '+attempt, description:'output', project_id:'', status:'', updated_at:'' }));
  const rows=homeChainsFromSearchHits(hits,[]);
  assert.notEqual(rows[0].submissionRoute,rows[1].submissionRoute);
  assert.deepEqual(parseChainRoute(rows[0].submissionRoute!),{chainId:'chain:one',taskId:'task:one',submissionAttempt:'1'});
  assert.deepEqual(parseChainRoute(rows[1].submissionRoute!),{chainId:'chain:one',taskId:'task:one',submissionAttempt:'2'});
  assert.equal(ownerSubmissionRoute({...hits[0],kind:'task'}),undefined);
  assert.equal(ownerSubmissionRoute({...hits[0],attempt:'0'}),undefined);
  assert.equal(ownerSubmissionRoute({...hits[0],attempt:'9223372036854775808'}),undefined);
  assert.deepEqual(parseChainRoute('/chains/c/tasks/t/submissions/invalid'),{chainId:'c',taskId:'t',submissionAttempt:'invalid'});
  assert.deepEqual(parseChainRoute('/chains/c/tasks/t/submissions/'),{chainId:'c',taskId:'t',submissionAttempt:''});
  assert.deepEqual(parseChainRoute('/chains/c/tasks/t'),{chainId:'c',taskId:'t'});
  assert.deepEqual(parseChainRoute('/chains/c'),{chainId:'c'});
});
test('historical read requires an explicit positive attempt and canonical bounded offset', () => {
  assert.deepEqual({...ownerParse('{"attempt":"1","offset":"0"}','submission_read_payload')},{attempt:'1',offset:'0'});
  for(const raw of ['{"attempt":"0","offset":"0"}','{"offset":"0"}','{"attempt":"1","offset":"-1"}','{"attempt":"1","offset":"0","latest":"1"}'])
    assert.throws(()=>ownerParse(raw,'submission_read_payload'));
});
