// Runs only against the disposable enrollment harness's Hub and real Bridge.
import { prepareOwnerOperation, sendOwnerOperation, openOwnerReply, ownerRelayFile, ownerId } from '../../src/ui/api/ownerLocalClient.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';

export async function ownerLocalFlow({ hub, approver, bridgeId, http, expect, stopOwner, restartOwner, inspectHub, otherAccount, cli, launchChild, prepareGit }: any) {
  const session = { identity: approver.identity, chain: await approver.chain(), keyring: await importKeyring(Uint8Array.from(approver.keyringBytes), approver.userId) };
  const chainId = ownerId('chain_'), taskId = ownerId('task_');
  const send = async (body: unknown) => {
    const r = await http(hub, 'POST', '/api/v1/owner-local/relay', { body });
    if (r.status !== 200) throw new Error(r.raw);
    return r.data;
  };
  const invoke = (op: any) => sendOwnerOperation(session, op, send);
  const make = (method: any, input: any) => prepareOwnerOperation(session, bridgeId, method, { chainId, ...input });
  const create = await make('chain.create', { expectedRevision: '0', title: 'owner-private-chain', description: 'owner-private-description' });
  expect(JSON.parse((await invoke(create)).body).revision === '1', 'real Hub relay commits owner-local genesis');
  const task = await make('task.create', { taskId, expectedRevision: '1', title: 'owner-private-task', body: 'owner-private-task-body' });
  await invoke(task);
  expect((await invoke(task)).replay, 'task retry returns historical receipt');
  const comment = await make('task.comment', { taskId, expectedRevision: '1', body: 'owner-private-comment' });
  await invoke(comment);
  expect((await invoke(comment)).replay, 'comment retry returns historical receipt');
  const read = () => make('task.read', { taskId, expectedRevision: '0' });
  const detail = JSON.parse((await invoke(await read())).body);
  expect(detail.body === 'owner-private-task-body' && detail.items.length === 1 && detail.items[0].body === 'owner-private-comment', 'owner detail and exactly one comment read through real relay');
  const rows = await http(hub, 'GET', '/api/v1/owner-local/chains');
  expect(rows.status === 200 && rows.data.length === 2 && rows.data.every((r: any) => r.online), 'Hub exposes protected chain/task listing only');
  await inspectHub(chainId);
  const bad = { ...task, command: task.command.replace(/"signature":"[0-9a-f]"/, '"signature":"0"') };
  // Same valid schema, changed signed payload: never a mutation.
  const command = JSON.parse(task.command); command.signature = '0'.repeat(128); bad.command = JSON.stringify(command);
  let denied = false; try { await invoke(bad); } catch { denied = true; }
  expect(denied, 'forged device signature denied');
  const other = await createDeviceIdentity(memoryDeviceStore(), approver.userId);
  const forged = { ...session, identity: other };
  denied = false;
  try { await prepareOwnerOperation(forged, bridgeId, 'task.read', { chainId, taskId, expectedRevision: '0' }); } catch { denied = true; }
  expect(denied, 'unenrolled device cannot prepare commands');
  const otherHub = await otherAccount();
  const hidden = await http(otherHub, 'GET', '/api/v1/owner-local/chains');
  expect(hidden.status === 200 && hidden.data.length === 0, 'another account cannot discover metadata');
  const wrongAccount = await http(otherHub, 'POST', '/api/v1/owner-local/relay', { body: await ownerRelayFile(session, await read()) });
  expect(wrongAccount.status !== 200, 'another account cannot relay to this owner');
  await stopOwner();
  const offlineRows = await http(hub, 'GET', '/api/v1/owner-local/chains');
  expect(offlineRows.data.length === 2 && offlineRows.data.every((r: any) => !r.online), 'offline owner retains metadata-only listing');
  const offline = await send(await ownerRelayFile(session, await read()));
  expect(offline.code === 'owner_unavailable' && !offline.envelope, 'offline details explicitly unavailable');
  await restartOwner();
  const persisted = JSON.parse((await invoke(await read())).body);
  expect(persisted.body === detail.body && persisted.items.length === 1, 'isolated owner process restart preserves SQLite task and comment');
  expect((await invoke(comment)).replay, 'pre-restart comment replay does not append a duplicate');
  const cliOp = await read();
  const relay = await ownerRelayFile(session, cliOp);
  const cliResult = await openOwnerReply(session, cliOp, await cli(relay));
  expect(JSON.parse(cliResult.body).items.length === 1, 'real CLI signed file traverses real local Bridge and Hub relay');

  const cliChain = ownerId('chain_'), cliTask = ownerId('task_');
  const throughCli = async (method: any, input: any) => {
    const operation = await prepareOwnerOperation(session, bridgeId, method, { chainId: cliChain, ...input });
    return openOwnerReply(session, operation, await cli(await ownerRelayFile(session, operation)));
  };
  await throughCli('chain.create', { expectedRevision: '0', title: 'CLI chain', description: 'CLI description' });
  await throughCli('task.create', { taskId: cliTask, expectedRevision: '1', title: 'CLI task', body: 'CLI body' });
  await throughCli('task.comment', { taskId: cliTask, expectedRevision: '1', body: 'CLI comment' });
  const cliDetail = JSON.parse((await throughCli('task.read', { taskId: cliTask, expectedRevision: '0' })).body);
  expect(cliDetail.body === 'CLI body' && cliDetail.items.length === 1 && cliDetail.items[0].body === 'CLI comment', 'CLI chain create -> task create -> comment -> detail read all commit through real relay');

  let oversizedDenied = false;
  try {
    await prepareOwnerOperation(session, bridgeId, 'task.create', { chainId: cliChain, taskId: ownerId('task_'), expectedRevision: '3', title: '\x01'.repeat(8192), body: '\x01'.repeat(8192) });
  } catch { oversizedDenied = true; }
  expect(oversizedDenied, 'browser signing flow rejects JSON-expanded oversized fields');
  const escapedTask = ownerId('task_'), escaped = '\x01'.repeat(2730);
  await throughCli('task.create', { taskId: escapedTask, expectedRevision: '3', title: escaped, body: escaped });
  for (let i = 0; i < 3; i++) await throughCli('task.comment', { taskId: escapedTask, expectedRevision: String(i + 1), body: escaped + i });
  let cursor = '', seen = 0, pages = 0;
  do {
    const page = await throughCli('task.read', { taskId: escapedTask, expectedRevision: '0', cursor });
    expect(new TextEncoder().encode(page.body).length <= 65536, 'escaped read page includes framing within 64KiB');
    const data = JSON.parse(page.body);
    expect(data.title === escaped && data.body === escaped, 'escaped task header survives real relay');
    for (const item of data.items) expect(item.body === escaped + seen++, 'escaped comments remain ordered across cursor pages');
    if (data.next_cursor) expect(data.items.length > 0 && data.next_cursor !== cursor, 'real relay nonterminal cursor advances');
    cursor = data.next_cursor;
    pages++;
    if (pages > 5) throw new Error('cursor failed to terminate');
  } while (cursor);
  expect(seen === 3 && pages > 1, 'real CLI follows escaped comment pagination to completion');
  const unsigned = { ...relay, envelope: 'not-ciphertext' };
  let rejected = false; try { const reply = await cli(unsigned); rejected = reply?.code !== 'ok'; } catch { rejected = true; }
  expect(rejected, 'CLI rejects unsigned/invalid request file');

  if (launchChild) {
    const child = await launchChild();
    try {
      const fleet=await make('fleet.edit',{taskId,expectedRevision:'2',instanceId:child.instanceId,configurationRevision:'1'});
      expect(JSON.parse((await invoke(fleet)).body).revision==='3','signed UI fleet edit pins actual launched child in owner SQLite');
      const input={protocol_version:'1',chain_id:chainId,task_id:taskId,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:'3',operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
      const claimed=child.call(input);
      expect(claimed.status===0 && claimed.data?.code==='ok','real agent CLI claims local lease with exact-child proof: '+JSON.stringify({status:claimed.status,ok:claimed.reply?.ok,error:claimed.reply?.error,stderr:claimed.error}));
      const result=JSON.parse(claimed.data.body);
      const cap=JSON.parse(result.capability);
      expect(cap.instance_id===child.instanceId && cap.chain_id===chainId && cap.task_id===taskId && cap.allowed_methods==='lease.claim,lease.heartbeat','owner-signed capability binds child and scope');
      const replay=child.call(input);
      expect(replay.status===0 && replay.data.replay && replay.data.body===claimed.data.body,'real CLI claim retry returns identical historical result');
      const heartbeat={...input,operation_id:ownerId('op_'),method:'lease.heartbeat',capability:result.capability};
      const renewed=child.call(heartbeat);
      expect(renewed.status===0 && renewed.data.code==='ok','real agent CLI heartbeat renews bounded local deadline');
      const observation=JSON.parse((await invoke(await make('runtime.read',{taskId,expectedRevision:'0'}))).body);
      expect(observation.leases.length===1 && observation.leases[0][0]===input.lease_id && observation.leases[0][4]==='2','UI owner relay observes exact lease and renewed deadline version');
      await inspectHub(chainId);
      await child.stop();
      const stale=child.call(heartbeat);
      expect(stale.status!==0,'stopped child token cannot replay or renew local lease');
    } finally { await child.stop(); }
  }

  if (prepareGit && launchChild) {
    for (const conflict of [false,true]) {
      const cid=ownerId('chain_'),tid=ownerId('task_'),git=prepareGit(tid,conflict);
      const worker=await launchChild(git.repository),reviewer=await launchChild();
      try {
        const human=async(method:string,input:any)=>invoke(await prepareOwnerOperation(session,bridgeId,method,{chainId:cid,taskId:tid,...input}));
        await human('chain.create',{taskId:'',expectedRevision:'0',title:'lifecycle-private-chain',description:'lifecycle-private-description'});
        await human('task.create',{expectedRevision:'1',title:'lifecycle-private-task',body:'lifecycle-private-body'});
        await human('fleet.edit',{expectedRevision:'1',instanceId:worker.instanceId,configurationRevision:'1'});
        const config={configuration_revision:'1',author_agent_id:worker.agentId,reviewer_agent_id:reviewer.agentId,reviewer_instance_id:reviewer.instanceId,directory_id:ownerId('dir_'),merge_policy:'git',repository:git.repository,worktree:git.worktree,source_branch:git.sourceBranch,target_branch:git.targetBranch,base_head:git.baseHead};
        await human('lifecycle.configure',{expectedRevision:'2',lifecycleConfig:config});
        await human('requirements.edit',{expectedRevision:'3',requirementsRevision:'1',body:JSON.stringify({goal:'lifecycle-private-goal',acceptance:['lifecycle-private-acceptance']})});
        const input={protocol_version:'1',chain_id:cid,task_id:tid,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:'4',operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
        const claim=worker.call(input);expect(claim.status===0,'lifecycle worker claims real exact-child lease');
        let cap=JSON.parse(claim.data.body).capability;
        await human('requirements.edit',{expectedRevision:'4',requirementsRevision:'2',body:JSON.stringify({goal:'lifecycle-private-revised-goal',acceptance:['lifecycle-private-revised-acceptance']})});
        const call=(child:any,method:string,payload:any,capability:string,revision='5')=>child.call({...input,expected_revision:revision,operation_id:ownerId('op_'),method,capability,payload:JSON.stringify(payload)});
        const old=call(worker,'requirements.ack',{requirements_revision:'1'},cap);
        expect(old.status!==0,'old requirements ACK rejected through real CLI');
        const unread=call(worker,'requirements.ack',{requirements_revision:'2'},cap);
        expect(unread.status!==0,'unpresented exact requirements ACK rejected');
        const presented=call(worker,'requirements.present',{requirements_revision:'2'},cap);
        expect(presented.status===0 && JSON.parse(presented.data.body).brief.includes('lifecycle-private-revised'),'real CLI reads exact immutable brief');
        expect(call(worker,'requirements.ack',{requirements_revision:'2'},cap).status===0,'real CLI ACKs exact presented revision');
        const submit={...input,expected_revision:'5',operation_id:ownerId('op_'),method:'lease.submit',capability:cap,payload:JSON.stringify({requirements_revision:'2',head:git.head,summary:'lifecycle-private-checks-pass'})};
        const submitted=worker.call(submit);expect(submitted.status===0,'real CLI submits actual clean source head');
        const replay=worker.call(submit);expect(replay.status===0 && replay.data.replay && replay.data.body===submitted.data.body,'lost submit reply replays after lease release without effects');
        const verdict={requirements_revision:'2',attempt:'1',head:git.head,verdict:'approve',summary:'lifecycle-private-independent-review'};
        expect(call(worker,'review.open',verdict,'','6').status!==0,'author cannot obtain reviewer capability');
        expect(call(reviewer,'review.open',{...verdict,head:'f'.repeat(40)},'','6').status!==0,'stale submitted head rejects review');
        await human('review.post',{expectedRevision:'6',requirementsRevision:'2',attempt:'1',head:git.head,verdict:'approve',body:'lifecycle-private-human-verdict'});
        const observed=JSON.parse((await human('runtime.read',{expectedRevision:'0'})).body);
        expect(observed.state[0][0]==='in_review','device-signed human approval does not replace named independent review');
        const opened=call(reviewer,'review.open',verdict,'','7');expect(opened.status===0,'independent actual child obtains scoped reviewer capability');
        const rcap=JSON.parse(opened.data.body).capability;
        const reviewed=call(reviewer,'review.post',verdict,rcap,'7');expect(reviewed.status===0,'independent actual child posts bound verdict');
        let state:any;
        for(const deadline=Date.now()+15000;;await new Promise(r=>setTimeout(r,200))){
          state=JSON.parse((await human('runtime.read',{expectedRevision:'0'})).body);
          if(state.state[0][0]===(conflict?'merge_blocked':'done'))break;
          if(Date.now()>deadline)throw new Error('merge gate did not settle: '+JSON.stringify(state));
        }
        expect(state.leases.length===0,'submit release and gate persist in owner SQLite');
        if(conflict)expect(state.state[0][2]==='merge_conflict' && git.targetHead()===git.baseHead,'real Git conflict keeps durable intent blocking and target unchanged');
        else expect(git.targetHead()===git.head && state.state[0][2]===git.head,'real Git exact target CAS stores successful merge receipt');
        await inspectHub(cid);
        await worker.stop();
        expect(worker.call(submit).status!==0,'stopped child cannot read historical submit receipt');
      } finally {await worker.stop();await reviewer.stop();}
    }
  }

  return { chainId, taskId };
}
