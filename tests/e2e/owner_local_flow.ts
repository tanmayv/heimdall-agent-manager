// Runs only against the disposable enrollment harness's Hub and real Bridge.
import { prepareOwnerOperation, sendOwnerOperation, openOwnerReply, ownerRelayFile, ownerId } from '../../src/ui/api/ownerLocalClient.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';

export async function ownerLocalFlow({ hub, approver, bridgeId, http, expect, stopOwner, restartOwner, inspectHub, otherAccount, cli, launchChild, prepareGit, registryFixture, rekeyOwner }: any) {
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


  // Search uses the same production UI signing/relay client and the real CLI.
  const searchChain = ownerId('chain_'), searchTask = ownerId('task_');
  const searchCommand = async (method: string, input: any, useCli = false) => {
    const operation = await prepareOwnerOperation(session, bridgeId, method, { chainId: searchChain, ...input });
    return useCli ? openOwnerReply(session, operation, await cli(await ownerRelayFile(session, operation))) : invoke(operation);
  };
  await searchCommand('chain.create', { expectedRevision: '0', title: 'search-private-chain', description: 'search-private-description' });
  await searchCommand('task.create', { taskId: searchTask, expectedRevision: '1', title: 'search-private-task', body: 'uniquesearchbody 世界' }, true);
  await searchCommand('task.comment', { taskId: searchTask, expectedRevision: '1', body: 'uniquesearchcomment sharedsearchword' }, true);
  const search = async (query: string, useCli = false) => JSON.parse((await searchCommand('chain.search', { expectedRevision: '0', query }, useCli)).body).hits;
  expect((await search('uniquesearchbody', true)).length === 1, 'real CLI searches freshly committed local task');
  expect((await search('世界')).length === 1 && (await search('uniquesearchcomment')).length === 1, 'Unicode and comment search use durable owner FTS');
  const { searchOwnerChains } = await import('../../src/ui/api/ownerSearchClient.ts');
  const listing = async () => (await http(hub, 'GET', '/api/v1/owner-local/chains')).data;
  const combined = await searchOwnerChains(session, await listing(), 'uniquesearchcomment', 20, send);
  expect(combined.hits.length === 1 && combined.hits[0].chain_id === searchChain, 'existing UI owner-search client finds exactly the authorized chain');

  // Exercise the exported existing UI search entrypoint over both real sources.
  const { installKeyringFromWrap, clearKeyringSession } = await import('../../src/ui/utils/vaultKeyringSession.ts');
  const { searchTaskChainsEncrypted } = await import('../../src/ui/utils/taskChainSearch.ts');
  const { encryptVaultText } = await import('../../src/ui/utils/vaultContent.ts');
  const { sessionHeaders } = await import('./hubOidc.mjs');
  const legacyCreated = await http(hub, 'POST', '/api/v1/task-chains', { body: {
    title: await encryptVaultText('sharedsearchword legacy title', session.keyring),
    description: await encryptVaultText('sharedsearchword legacy description', session.keyring), kind: 'mixed_work',
  } });
  expect(legacyCreated.status === 200 || legacyCreated.status === 201, 'real legacy chain remains Hub canonical for unmigrated coverage: ' + legacyCreated.status + (legacyCreated.status >= 400 ? ' ' + legacyCreated.raw : ''));
  const legacyId = legacyCreated.data.chain_id;
  await installKeyringFromWrap(approver.identity, approver.wrap, await approver.chain());
  const realFetch = globalThis.fetch;
  globalThis.fetch = (input: any, init: any = {}) => realFetch(new URL(String(input), hub.base), {
    ...init, headers: { ...Object.fromEntries(new Headers(sessionHeaders(hub.session, hub.base))), ...Object.fromEntries(new Headers(init.headers)) },
  });
  try {
    let mixed: any;
    for (const deadline = Date.now() + 45000;; await new Promise((r) => setTimeout(r, 500))) {
      mixed = await searchTaskChainsEncrypted('sharedsearchword', approver.userId, { limit: 20 });
      if (mixed.hits.some((h: any) => h.chain_id === legacyId)) break;
      if (Date.now() > deadline) throw new Error('legacy refresh did not join owner search');
    }
    expect(mixed.hits.filter((h: any) => h.chain_id === searchChain).length === 1 &&
      mixed.hits.filter((h: any) => h.chain_id === legacyId).length === 1,
      'production UI search returns owner and unmigrated legacy hits exactly once');
    let release: () => void = () => {};
    let reached: () => void = () => {};
    const held = new Promise<void>((r) => { release = r; });
    const ready = new Promise<void>((r) => { reached = r; });
    let intercepted = false;
    globalThis.fetch = async (input: any, init: any = {}) => {
      const response = await realFetch(new URL(String(input), hub.base), {
        ...init, headers: { ...Object.fromEntries(new Headers(sessionHeaders(hub.session, hub.base))), ...Object.fromEntries(new Headers(init.headers)) },
      });
      if (String(input).endsWith('/owner-local/relay') && !intercepted) {
        intercepted = true; reached(); await held;
      }
      return response;
    };
    const late = searchTaskChainsEncrypted('sharedsearchword', approver.userId, { limit: 20 });
    await ready;
    clearKeyringSession(); release();
    let discarded = false; try { await late; } catch { discarded = true; }
    expect(discarded, 'real UI discards completed owner query after lock/session generation changes');
  } finally { globalThis.fetch = realFetch; clearKeyringSession(); }

  const isolated = JSON.parse((await invoke(await make('chain.search', { expectedRevision: '0', query: 'uniquesearchcomment' }))).body);
  expect(isolated.hits.length === 0, 'signed chain filter cannot expose matching content in another chain');
  const foreignSearch = await searchCommand('chain.search', { expectedRevision: '0', query: 'uniquesearchcomment' });
  expect(foreignSearch.code === 'ok', 'search result is independently device authorized');
  const operation = await prepareOwnerOperation(session, bridgeId, 'chain.search', { chainId: searchChain, expectedRevision: '0', query: 'uniquesearchcomment' });
  const wrongScope = await http(otherHub, 'POST', '/api/v1/owner-local/relay', { body: await ownerRelayFile(session, operation) });
  expect(wrongScope.status !== 200, 'another account cannot search owner-local prose');
  await searchCommand('task.edit', { taskId: searchTask, expectedRevision: '2', title: 'edited-private-task', body: 'uniquesearchedited' }, true);
  expect((await search('uniquesearchbody')).length === 0 && (await search('uniquesearchedited')).length === 1, 'real edit atomically removes old postings and indexes new content');
  await searchCommand('chain.edit', { expectedRevision: '4', title: 'edited-private-chain', description: 'uniquesearchchaindescription' });
  expect((await search('uniquesearchchaindescription')).length === 1, 'chain edit publishes title metadata and indexes prose');
  await stopOwner(); await restartOwner();
  expect((await search('uniquesearchedited', true)).length === 1 && (await search('uniquesearchcomment')).length === 1, 'actual owner restart rebuilds index from committed canonical rows');
  await searchCommand('task.delete', { taskId: searchTask, expectedRevision: '3' }, true);
  expect(!(await listing()).some((r: any) => r.task_id === searchTask), 'deleted title tombstone is excluded from visible Hub listing');
  expect((await search('uniquesearchedited')).length === 0 && (await search('uniquesearchcomment')).length === 0, 'real delete removes canonical task/comment postings together');
  await stopOwner(); await restartOwner();
  expect((await search('uniquesearchedited')).length === 0, 'restart cannot resurrect deleted search content');

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
        let input={protocol_version:'1',chain_id:cid,task_id:tid,lease_id:ownerId('lease_'),configuration_revision:'1',expected_revision:'4',operation_id:ownerId('op_'),method:'lease.claim',request_expires_ms:String(Date.now()+300000),capability:''};
        const claim=worker.call(input);expect(claim.status===0,'lifecycle worker claims real exact-child lease');
        let cap=JSON.parse(claim.data.body).capability;
        await human('requirements.edit',{expectedRevision:'4',requirementsRevision:'2',body:JSON.stringify({goal:'lifecycle-private-revised-goal',acceptance:['lifecycle-private-revised-acceptance']})});
        const requirementHits=JSON.parse((await human('chain.search',{taskId:'',expectedRevision:'0',query:'lifecycle-private-revised-goal'})).body).hits;
        expect(requirementHits.some((h:any)=>h.kind==='requirements'),'real search indexes revised goals and acceptance');
        expect(JSON.parse((await human('chain.search',{taskId:'',expectedRevision:'0',query:'lifecycle-private-goal'})).body).hits.length===0,'old requirements postings are removed');

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
        expect(JSON.parse((await human('chain.search',{taskId:'',expectedRevision:'0',query:'lifecycle-private-checks-pass'})).body).hits.some((h:any)=>h.kind==='output'),'real search indexes committed submission output');

        const replay=worker.call(submit);expect(replay.status===0 && replay.data.replay && replay.data.body===submitted.data.body,'lost submit reply replays after lease release without effects');

        // Retain attempt 1, request rework, then submit attempt 2 through real children.
        await human('review.post',{expectedRevision:'6',requirementsRevision:'2',attempt:'1',head:git.head,verdict:'request_changes',body:'Revise the first submission'});
        input={...input,lease_id:ownerId('lease_'),expected_revision:'7',operation_id:ownerId('op_'),method:'lease.claim',capability:''};
        const claimedAgain=worker.call(input);expect(claimedAgain.status===0,'worker claims a new lease after rework');
        cap=JSON.parse(claimedAgain.data.body).capability;
        expect(call(worker,'requirements.present',{requirements_revision:'2'},cap,'7').status===0,'second lease presents exact requirements');
        expect(call(worker,'requirements.ack',{requirements_revision:'2'},cap,'7').status===0,'second lease ACKs exact requirements');
        const secondSubmit={...input,operation_id:ownerId('op_'),method:'lease.submit',capability:cap,payload:JSON.stringify({requirements_revision:'2',head:git.head,summary:'lifecycle-private-second-checks-pass'})};
        expect(worker.call(secondSubmit).status===0,'real CLI retains a distinct second submission');
        for(const [term,attempt] of [['lifecycle-private-checks-pass','1'],['lifecycle-private-second-checks-pass','2']]){
          const hit=JSON.parse((await human('chain.search',{taskId:'',expectedRevision:'0',query:term})).body).hits.find((h:any)=>h.kind==='output');
          expect(hit?.attempt===attempt && hit?.object_id===tid+':'+attempt,'historical output search identifies exact attempt '+attempt);
          const old=JSON.parse((await human('submission.read',{expectedRevision:'0',attempt})).body);
          expect(old.kind==='submission' && old.attempt===attempt && old.summary===term,'signed exact-attempt read returns retained output '+attempt);
        }

        const verdict={requirements_revision:'2',attempt:'2',head:git.head,verdict:'approve',summary:'lifecycle-private-independent-review'};
        expect(call(worker,'review.open',verdict,'','8').status!==0,'author cannot obtain reviewer capability');
        expect(call(reviewer,'review.open',{...verdict,head:'f'.repeat(40)},'','8').status!==0,'stale submitted head rejects review');
        await human('review.post',{expectedRevision:'8',requirementsRevision:'2',attempt:'2',head:git.head,verdict:'approve',body:'lifecycle-private-human-verdict'});
        const observed=JSON.parse((await human('runtime.read',{expectedRevision:'0'})).body);
        expect(observed.state[0][0]==='in_review','device-signed human approval does not replace named independent review');
        const opened=call(reviewer,'review.open',verdict,'','9');expect(opened.status===0,'independent actual child obtains scoped reviewer capability');
        const rcap=JSON.parse(opened.data.body).capability;
        const reviewed=call(reviewer,'review.post',verdict,rcap,'9');expect(reviewed.status===0,'independent actual child posts bound verdict');
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
        await stopOwner();await restartOwner();
        for(const [term,attempt] of [['lifecycle-private-checks-pass','1'],['lifecycle-private-second-checks-pass','2']]){
          expect(JSON.parse((await human('chain.search',{taskId:'',expectedRevision:'0',query:term})).body).hits.some((h:any)=>h.kind==='output' && h.attempt===attempt),'real restart rebuild preserves historical output '+attempt);
        }
        if(!conflict){
          const {JSDOM}=await import('jsdom');
          const React=await import('react');
          const {installKeyringFromWrap,clearKeyringSession}=await import('../../src/ui/utils/vaultKeyringSession.ts');
          const {sessionHeaders}=await import('./hubOidc.mjs');
          const {searchOwnerChains}=await import('../../src/ui/api/ownerSearchClient.ts');
          const {homeChainsFromSearchHits}=await import('../../src/ui/components/home/homeChainSearchLogic.ts');
          const {parseChainRoute}=await import('../../src/ui/utils/ownerSubmissionNavigation.ts');
          const {default:OwnerLocalPanel}=await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');
          await installKeyringFromWrap(approver.identity,approver.wrap,await approver.chain());
          const dom=new JSDOM('<div id="root"></div>',{url:hub.base});
          const keys=['window','document','navigator','HTMLElement','IS_REACT_ACT_ENVIRONMENT'];
          const descriptors=keys.map(k=>Object.getOwnPropertyDescriptor(globalThis,k));
          for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true})) Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
          const originalFetch=globalThis.fetch;
          globalThis.fetch=(url:any,init:any={})=>originalFetch(new URL(String(url),hub.base),{...init,headers:{...Object.fromEntries(new Headers(sessionHeaders(hub.session,hub.base))),...Object.fromEntries(new Headers(init.headers))}});
          const {createRoot}=await import('react-dom/client');
          const root=createRoot(dom.window.document.getElementById('root')!);
          try{
            const listed=await http(hub,'GET','/api/v1/owner-local/chains?headers_only=1');
            expect(listed.status===200,'rendered historical search uses authenticated listing: '+listed.status);
            const listing=listed.data;
            for(const [term,attempt] of [['lifecycle-private-checks-pass','1'],['lifecycle-private-second-checks-pass','2']]){
              const result=await searchOwnerChains(session,listing,term,20,send);
              const row=homeChainsFromSearchHits(result.hits,[]).find((r:any)=>r.chainId===cid)!;
              expect(row.title.includes('submission attempt '+attempt) && row.submissionRoute?.endsWith('/submissions/'+attempt),'production UI exposes historical output identity '+attempt);
              const target=parseChainRoute(row.submissionRoute!);
              await React.act(async()=>root.render(React.createElement(OwnerLocalPanel,{key:attempt,onClose:()=>{},initialBridgeId:bridgeId,initialChainId:target.chainId,initialTaskId:target.taskId,initialSubmissionAttempt:target.submissionAttempt})));
              for(const deadline=Date.now()+15000;;){
                if(dom.window.document.querySelector('h3')?.textContent?.includes('attempt '+attempt))break;
                if(Date.now()>deadline)throw new Error('historical panel did not open exact attempt: '+dom.window.document.body.textContent);
                await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});
              }
              // Detail arrives before the post-operation paginated listing.
              // Keep the browser environment until that refresh has settled.
              for(const deadline=Date.now()+15000;(dom.window.document.querySelector('[data-debug-id="owner-local-list"]') as HTMLButtonElement)?.disabled;){
                if(Date.now()>deadline)throw new Error('historical listing refresh did not settle');
                await React.act(async()=>{await new Promise(r=>setTimeout(r,50));});
              }
              expect(dom.window.document.querySelector('pre')?.textContent?.includes(term),'rendered UI reads exact historical summary '+attempt);
              if(attempt==='1')expect(!dom.window.document.querySelector('pre')?.textContent?.includes('lifecycle-private-second-checks-pass'),'old output is not replaced by current submission');
            }
          }finally{
            await React.act(async()=>root.unmount());
            globalThis.fetch=originalFetch;clearKeyringSession();dom.window.close();
            keys.forEach((k,i)=>{if(descriptors[i])Object.defineProperty(globalThis,k,descriptors[i]!);else delete (globalThis as any)[k];});
          }
        }

      } finally {await worker.stop();await reviewer.stop();}
    }
  }

  if(process.env.HEIMDALL_E2E_OWNER_CONTROLS==='1'){
    const {ownerLocalControlsFlow}=await import('./owner_local_controls_flow.ts');
    await ownerLocalControlsFlow({session,bridgeId,hub,http,cli,launchChild,expect,approver});
  }
  if(process.env.HEIMDALL_E2E_OWNER_WORKFLOWS==='1'){
    const {ownerLocalWorkflowsFlow}=await import('./owner_local_workflows_flow.ts');
    await ownerLocalWorkflowsFlow({session,bridgeId,hub,http,cli,launchChild,expect,approver,stopOwner,restartOwner,inspectHub});
  }
  if(process.env.HEIMDALL_E2E_OWNER_GRANTS==='1'){
    const {ownerGrantsFlow}=await import('./owner_grants_flow.ts');
    await ownerGrantsFlow({hub,approver,bridgeId,http,expect,cli,stopOwner,restartOwner,rekeyOwner});
  }
  if(process.env.HEIMDALL_E2E_OWNER_REGISTRY==='1'){
    const {ownerRegistryFlow}=await import('./owner_registry_flow.ts');
    await ownerRegistryFlow({hub,approver,bridgeId,http,expect,registryFixture,rekeyOwner});
  }
  return { chainId, taskId };
}
