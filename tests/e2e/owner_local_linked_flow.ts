import { readFileSync } from 'node:fs';
import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';
import { encryptVaultText, decryptVaultText } from '../../src/ui/utils/vaultContent.ts';

// Synthetic content only; runs through enrolled browser signatures, the actual
// CLI file relay, Hub scope checks and the single owner writer.
export async function ownerLocalLinkedFlow({session,bridgeId,cli,expect,stopOwner,restartOwner,inspectHub}:any) {
  const chainId=ownerId('linked_'),taskId=ownerId('linkedtask_');
  const prepare=(method:string,input:any={})=>prepareOwnerOperation(session,bridgeId,method,{chainId,expectedRevision:'0',...input});
  const invoke=async(op:any)=>openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  const call=async(method:string,input:any={})=>invoke(await prepare(method,input));
  const read=async(method:string,input:any={})=>JSON.parse((await call(method,input)).body);
  const mutate=async(method:string,input:any={})=>call(method,{expectedRevision:(await read(input.taskId?'task.read':'chain.read',input.taskId?{taskId:input.taskId}:{})).revision,...input});
  const rejected=async(method:string,input:any={})=>{let denied=false;try{await mutate(method,input);}catch{denied=true;}expect(denied,method+' rejects invalid signed scope or stale content');};
  await call('chain.create',{title:'Synthetic linked canonical content',description:'C3 isolated owner proof'});
  await call('task.create',{taskId,expectedRevision:(await read('chain.read')).revision,title:'Linked task',body:'Synthetic task scope'});
  const record=async(kind:string,id:string,text:string,references:any[]=[],revision='1')=>JSON.stringify({
    account_id:session.identity.userId,owner_bridge_id:bridgeId,chain_id:chainId,task_id:taskId,
    kind,object_id:id,revision,author_id:'original_synthetic_author',created_ms:'37',media_type:'text/plain',
    body_cipher:await encryptVaultText(text,session.keyring),references:JSON.stringify(references),provenance:'synthetic archived producer',
  });
  const blob=await record('blob','chunk','YmluYXJ5X2NodW5rAA==');
  const message=await record('message','msg_original','linked-message-needle 世界😀',[],'2');
  const artifact=await record('artifact','art_original','artifact-extraction-deferred-needle',[{kind:'blob',object_id:'chunk',revision:'1'}],'7');
  const ops=[];
  for(const body of [blob,message,artifact]){
    const op=await prepare('linked.put',{expectedRevision:(await read('chain.read')).revision,body});
    await invoke(op);ops.push(op);
  }
  expect((await invoke(ops[1])).replay,'exact signed linked-message retry returns historical receipt');
  const fetch=async(kind:string,id:string,revision='1')=>{
    let offset='0',raw='';
    for(let i=0;i<100;i++){
      const page=await read('linked.fetch',{body:JSON.stringify({kind,object_id:id,revision,offset})});
      raw+=page.record;offset=page.next_offset;if(!offset)return raw;
    }
    throw new Error('linked fetch did not terminate');
  };
  expect(await fetch('artifact','art_original','7')===artifact,'artifact envelope and original metadata export byte-for-byte');
  const history=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-history.json',import.meta.url),'utf8'));
  for(const kind of ['attempts','events','facets'])history[kind]=JSON.stringify(JSON.parse(history[kind]).map((raw:string)=>{
    const o=JSON.parse(raw);o.chain_id=chainId;o.task_id=taskId;return JSON.stringify(o);
  }));
  await mutate('native.history.import',{taskId,body:JSON.stringify(history)});
  const facet={task_id:taskId,source_revision:'snapshot_7',key:JSON.stringify(['3','artifacts','1'])};
  const resolved=await read('linked.facet.read',{body:JSON.stringify(facet)});
  expect(resolved.references.every((r:any)=>r.state==='resolved'),'canonical native facet resolves exact artifact and message versions');
  const hits=await read('chain.search',{query:'linked-message-needle'});
  expect(hits.hits.some((h:any)=>h.kind==='message' && h.task_id===taskId),'ordinary owner search connects linked message prose');
  expect((await read('chain.search',{query:'artifact-extraction-deferred-needle'})).hits.length===0,'artifact content indexing remains deferred');
  const pages:string[]=[];let cursor='';
  for(let i=0;i<10;i++){
    const page=await read('linked.backup',{cursor,limit:1});
    expect(page.manifest_cipher.startsWith('vault:v2:'),'portable linked backup page is encrypted');
    pages.push(await decryptVaultText(page.manifest_cipher,session.keyring));
    cursor=page.next_cursor;if(!cursor)break;
  }
  expect(pages.length===4 && !cursor,'bounded backup includes tombstone phase and all three canonical body records');
  const envelopes=await read('envelope.read',{limit:100});
  expect(envelopes.items.some((e:any)=>JSON.parse(e.envelopes).some((v:any)=>v.epoch && v.vault_id && v.cipher_digest)),'event envelope inventory retains key metadata and canonical evidence locations');
  await stopOwner();await restartOwner();
  expect(await fetch('message','msg_original','2')===message,'real owner process restart preserves linked message exact envelope');
  expect((await read('linked.facet.read',{body:JSON.stringify(facet)})).references.every((r:any)=>r.state==='resolved'),'facet resolution survives real restart');
  expect((await read('chain.search',{query:'linked-message-needle'})).hits.some((h:any)=>h.kind==='message'),'restart rebuild indexes canonical linked messages');
  const otherScope=JSON.parse(message);otherScope.chain_id='wrong_chain';
  await rejected('linked.put',{body:JSON.stringify(otherScope)});
  await mutate('linked.delete',{body:JSON.stringify({kind:'message',object_id:'msg_original',revision:'2'})});
  for(const body of pages)await mutate('linked.restore',{body});
  let retired=false;try{await fetch('message','msg_original','2');}catch{retired=true;}
  expect(retired,'restoring older encrypted pages cannot resurrect a newer destination tombstone');
  expect((await read('chain.search',{query:'linked-message-needle'})).hits.length===0,'deleted message is absent from live prose search');
  expect((await read('linked.facet.read',{body:JSON.stringify(facet)})).references.some((r:any)=>r.kind==='message' && r.state==='deleted'),'facet retains deleted linked identity explicitly');
  await mutate('linked.delete',{body:JSON.stringify({kind:'artifact',object_id:'art_original',revision:'7'})});
  let collected=false;try{await fetch('blob','chunk');}catch{collected=true;}
  expect(collected,'deleting the final artifact reference transactionally tombstones and collects its blob chunk');
  await inspectHub(chainId);
  console.log('C3 linked canonical content: signed message/artifact/blob/facet, restart, encrypted manifests, tombstones, search and GC PASS');
}
