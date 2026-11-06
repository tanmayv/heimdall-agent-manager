import { prepareOwnerOperation, ownerId, ownerRelayFile, openOwnerReply } from '../../src/ui/api/ownerLocalClient.ts';
import { readFileSync } from 'node:fs';

// Actual CLI -> Hub relay -> enrolled disposable Bridge, using UI signatures.
export async function ownerLocalMetadataFlow({session,bridgeId,cli,expect,stopOwner,restartOwner}:any) {
  const chainId=ownerId('chain_');
  const prepare=(method:string,input:any={})=>prepareOwnerOperation(session,bridgeId,method,{chainId,expectedRevision:'0',...input});
  const invoke=async(op:any)=>openOwnerReply(session,op,await cli(await ownerRelayFile(session,op)));
  const call=async(method:string,input:any={})=>invoke(await prepare(method,input));
  const denied=async(method:string,input:any,message:string)=>{let rejected=false;try{await call(method,input);}catch{rejected=true;}expect(rejected,message);};
  await call('chain.create',{title:'Native metadata snapshot',description:'Disposable C1d source provenance'});
  const fixture=(kind:string)=>{
    const bundle=JSON.parse(readFileSync(new URL('../../src/contracts/fixtures/owner-native-metadata-'+kind+'.json',import.meta.url),'utf8'));
    bundle.chain_id=chainId;
    for(const row of bundle.records)row.chain_id=chainId;
    return bundle;
  };
  const members=fixture('members'),directories=fixture('directories');
  const exact=await prepare('native.metadata.import',{expectedRevision:'1',body:JSON.stringify(members)});
  const accepted=await invoke(exact);
  expect(JSON.parse(accepted.body).revision==='2','signed native metadata import advances chain CAS');
  await call('native.metadata.import',{expectedRevision:'2',body:JSON.stringify(directories)});
  const read=async(kind:string,input:any={})=>JSON.parse((await call('native.metadata.read',{nativeSourceRevision:'native_revision_7',nativeHistoryKind:kind,...input})).body);
  for(const bundle of [members,directories]){
    const page=await read(bundle.kind);
    expect(page.owner_user_id==='native_owner','original owner retained independently of local account');
    expect(page.items.length===bundle.records.length && page.items.every((row:any)=>bundle.records.some((expected:any)=>Object.keys(row).length===Object.keys(expected).length && Object.entries(expected).every(([key,value])=>row[key]===value))),'real CLI round-trips every ordinary native member/directory field');
  }
  const first=await read('member',{limit:1}),second=await read('member',{limit:1,cursor:first.next_cursor});
  expect(first.items.length===1 && first.next_cursor && second.items.length===1 && !second.next_cursor,'immutable source pages include empty native instance key once');
  await denied('native.metadata.read',{nativeSourceRevision:'native_revision_7',nativeHistoryKind:'directory',cursor:first.next_cursor},'source page cannot cross kind');
  await denied('native.metadata.import',{expectedRevision:'2',body:JSON.stringify(members)},'stale import CAS rejected');
  const changed={...directories,records:directories.records.map((row:any)=>({...row,path:'/changed'}))};
  await denied('native.metadata.import',{expectedRevision:'3',body:JSON.stringify(changed)},'same pinned source revision rejects conflicting native metadata');
  const later={...members,source_revision:'native_revision_8',records:members.records.map((row:any)=>({...row,role:'reviewer'}))};
  await call('native.metadata.import',{expectedRevision:'3',body:JSON.stringify(later)});
  const old=await read('member'),latest=await read('member',{nativeSourceRevision:'native_revision_8'});
  expect(old.items.some((row:any)=>row.role==='coordinator') && latest.items.every((row:any)=>row.role==='reviewer'),'later source revision preserves complete old snapshot');
  expect((await invoke(exact)).replay,'exact signed lost-reply replay survives later imports');
  const events=JSON.parse((await call('history.read')).body);
  const event=events.items.find((item:any)=>item.kind==='native.metadata.import');
  const evidence=JSON.parse((await call('history.fetch',{eventSeq:event.seq})).body);
  expect(JSON.parse(JSON.parse(evidence.evidence).content).body===JSON.stringify(members),'exact original imported document remains in signed immutable history');

  const facts=['chain','task','comment','summary'].map(fixture);
  let revision=4;
  for(const bundle of facts) {
    const prepared=await prepare('native.metadata.import',{expectedRevision:String(revision),body:JSON.stringify(bundle)});
    await invoke(prepared);revision++;
    const page=await read(bundle.kind);
    expect(page.items.length===1 && Object.keys(page.items[0]).length===Object.keys(bundle.records[0]).length && Object.entries(bundle.records[0]).every(([key,value])=>page.items[0][key]===value),'real CLI preserves all native '+bundle.kind+' fields and scalar types');
    expect((await invoke(prepared)).replay,'exact source '+bundle.kind+' replay');
    const later={...bundle,source_revision:'native_revision_8',records:bundle.records.map((row:any)=>({...row,[bundle.kind==='chain'||bundle.kind==='task'?'title':'body']:'later source text'}))};
    await call('native.metadata.import',{expectedRevision:String(revision),body:JSON.stringify(later)});revision++;
    const old=(await read(bundle.kind)).items[0];
    expect(Object.entries(bundle.records[0]).every(([key,value])=>old[key]===value),'old source '+bundle.kind+' snapshot remains exact');
  }
  await stopOwner();await restartOwner();
  expect((await read('directory')).items[0].vcs_info_json===directories.records[0].vcs_info_json,'restart preserves native VCS string bytes and Unicode path');
  for(const bundle of facts) {
    expect((await read(bundle.kind)).items[0].updated_at===bundle.records[0].updated_at,'restart retains exact native '+bundle.kind+' timestamp');
    expect((await read(bundle.kind,{nativeSourceRevision:'native_revision_8'})).items.length===1,'restart retains newer '+bundle.kind+' source snapshot');
  }
  expect((await invoke(exact)).replay,'restart retains exact accepted import receipt');
}
