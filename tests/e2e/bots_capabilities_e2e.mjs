// Spec 14.3: capabilities through a real isolated bot, hub and bridges.
// Run inside nix develop: node tests/e2e/bots_capabilities_e2e.mjs
// Requires npm ci and Python 3; no model or Telegram credentials.
// BOTS_E2E_BIN_DIR may point at prebuilt binaries; otherwise Nix builds them.
// Run log and per-step JSON remain in BOTS_E2E_EVIDENCE_ROOT (default: /var/tmp).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {hubLogin, sessionHeaders} from './hubOidc.mjs';
import {createFakeTelegram} from '../../tools/fake_telegram/server.mjs';
import '../helpers/vaultEndpointHarness.ts';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const root=fs.mkdtempSync(path.join(process.env.BOTS_E2E_EVIDENCE_ROOT || '/var/tmp','bots-capabilities-e2e-'));
const state=path.join(root,'state'), bin=process.env.BOTS_E2E_BIN_DIR || path.join(root,'bin');
fs.mkdirSync(bin,{recursive:true});
const logFile=path.join(root,'run.log');
const log=(s)=>{console.log(s);fs.appendFileSync(logFile,s+'\n');};
log('C6 evidence: '+root);
const env={...process.env};
for(const name of Object.keys(env)) if(name.startsWith('HEIMDALL_')) delete env[name];
env.HEIMDALL_LOCAL_STATE_ROOT=state;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function run(cmd,args,extra={}) {
  log('$ '+[cmd,...args].join(' '));
  return await new Promise((resolve,reject)=>{
    const child=spawn(cmd,args,{cwd:repo,env,...extra,stdio:['ignore','pipe','pipe']});
    let output='', errors='';
    child.stdout.on('data',b=>{output+=b;fs.appendFileSync(logFile,b);});
    child.stderr.on('data',b=>{errors+=b;fs.appendFileSync(logFile,b);});
    child.on('error',reject);
    child.on('exit',code=>code===0?resolve(output):reject(new Error(cmd+' exited '+code+'\n'+(output+errors).slice(-5000))));
  });
}
async function poll(fn,label,timeout=90000) {
  const deadline=Date.now()+timeout;
  do {
    const result=await fn();
    if(result) return result;
    await sleep(250);
  } while(Date.now()<deadline);
  throw new Error('Timed out: '+label);
}
// Prefer the spec ports; if occupied select another port in the same range.
async function preferredPort(port,base) {
  for(let candidate of [port,...Array.from({length:99},(_,i)=>base+i)]) {
    const available=await new Promise(resolve=>{
      const server=net.createServer();
      server.once('error',()=>resolve(false));
      server.listen(candidate,'127.0.0.1',()=>server.close(()=>resolve(true)));
    });
    if(available) return candidate;
  }
  throw new Error('No free port in range '+base);
}
const ports=[];
for(const [port,base] of [[18281,18300],[18280,18400],[15373,15400],[18290,18500],[49627,49700],[49628,49800],[49629,49900],[49630,50000],[18199,18600]])
  ports.push(await preferredPort(port,base));
log('Ports: '+JSON.stringify(ports));
const [hubPort,proxyPort,uiPort,oidcPort,aPort,aEp,bPort,bEp,tgPort]=ports;
assert.equal(new Set(ports).size,ports.length);
const api='http://127.0.0.1:'+proxyPort, tg='http://127.0.0.1:'+tgPort;
Object.assign(env,{
  HEIMDALL_TELEGRAM_BOT_TOKEN:'TEST:FAKE',HEIMDALL_TELEGRAM_API_BASE:tg,
  HEIMDALL_BOT_TIMERS_JSON:JSON.stringify({read_ms:15000,idle_no_reply_ms:180000,bot_attempt_silence_ms:30000,bot_disconnect_grace_ms:5000}),
});
const fake=createFakeTelegram({token:'TEST:FAKE',botUsername:'ninjy_test_bot'});
const hubDir=path.join(state,'hubs/bots-cap-e2e');
let headers, keyring, app, otherApp;
const nativeFetch=globalThis.fetch;
async function request(route,method='GET',body,expected=200) {
  const res=await nativeFetch(api+'/api/v1'+route,{method,headers:{...headers,'content-type':'application/json'},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(40000)});
  const json=await res.json();
  assert.equal(res.status,expected,method+' '+route+': '+JSON.stringify(json));
  return json.data??json;
}
async function control(route,body) {
  const res=await nativeFetch(tg+'/_control/'+route,{method:body?'POST':'GET',
    headers:{'content-type':'application/json'},body:body?JSON.stringify(body):undefined});
  assert.equal(res.status,200);
  return res.json();
}
const inject=(text,update_id,message_id)=>control('inject',{chat_id:111,from_id:222,username:'a9',text,...(update_id===undefined?{}:{update_id}),...(message_id===undefined?{}:{message_id})});
const sent=async()=> (await control('sent?chat_id=111')).messages;
async function expectSent(text,timeout=90000) {
  return poll(async()=> (await sent()).find(m=>m.text===text),'Telegram text '+text,timeout);
}
const copies=Object.fromEntries([...fs.readFileSync(path.join(repo,'src/hub/service/bots/copy.odin'),'utf8').matchAll(/(COPY_\w+) :: "(.*)"/g)].map(m=>[m[1],m[2]]));
async function step(n,name,fn) {
  log('STEP '+n+': '+name);
  const evidence=await fn();
  fs.writeFileSync(path.join(root,'step-'+n+'.json'),JSON.stringify({evidence,telegram:await sent()},null,2));
  log('PASS '+n+': '+name);
}
async function sql(query,params=[]) {
  const output=await run('python3',['-c',
    "import sqlite3,json,sys; c=sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True); c.row_factory=sqlite3.Row; print(json.dumps([dict(r) for r in c.execute(sys.argv[2],json.loads(sys.argv[3]))]))",
    path.join(hubDir,'hub.db'),query,JSON.stringify(params)]);
  return JSON.parse(output);
}
const bridgeDir=name=>path.join(state,'bridges',name);
const bridgeId=name=>fs.readFileSync(path.join(bridgeDir(name),'config.toml'),'utf8').match(/^daemon_id = "([^"]+)"/m)[1];
const bridgeArgs=name=>['--name',name,'--hub','bots-cap-e2e','--port',String(name.endsWith('-a')?aPort:bPort),
  '--local-endpoint-port',String(name.endsWith('-a')?aEp:bEp),'--auto-enroll','--isolated-home','--providers','git','--bin-dir',bin];
const startBridge=name=>run('scripts/local-bridge.sh',['start',...bridgeArgs(name)]);
const stopBridge=name=>run('scripts/local-bridge.sh',['stop','--name',name]);
async function placement(candidates) {
  const current=await request('/bots/me/placement');
  return request('/bots/me/placement','PUT',{expected_revision:current.placement_revision,candidates});
}
const row=(provider,tier='preferred')=>({bridge_id:'*',provider,model:'*',tier});


async function command(commandText,success=true) {
  const before=(await sent()).length;
  await inject('ctl '+commandText);
  const reply=await poll(async()=> (await sent()).slice(before).find(m=>{
    try {JSON.parse(m.text.split('\n')[0]);return true;} catch {return false;}
  }),'CLI reply: '+commandText,120000);
  const result=JSON.parse(reply.text.split('\n')[0]);
  if(success) assert.equal(result.ok,true,commandText+': '+reply.text);
  return {text:reply.text,result};
}
function findField(value,key) {
  if(value && typeof value==='object') {
    if(typeof value[key]==='string') return value[key];
    for(const child of Object.values(value)) {const found=findField(child,key);if(found)return found;}
  }
}
async function writes() {
  const data=await request('/me/agent-writes');
  return data;
}
async function assertWrite(kind,action,id,fields) {
  const rows=await writes();
  const row=rows.find(r=>r.resource_kind===kind&&r.action===action&&r.resource_id===id);
  assert.ok(row,'missing write '+JSON.stringify({kind,action,id,rows}));
  assert.equal(row.actor_agent_instance_id,botInstance);
  if(fields) assert.deepEqual(row.fields,fields);
  return row;
}
let botInstance, botModel, projectId, memoryId, pendingId, coordinator, coordAgent;
try {
  if(!process.env.BOTS_E2E_BIN_DIR) {
    const attrs=['hub','bridge','ctl','pty-host','dev-proxy'];
    const built=(await run('nix',['build',...attrs.map(a=>'.#ham-'+a),'--no-link','--print-out-paths'])).trim().split('\n');
    assert.equal(built.length,attrs.length);
    for(let i=0;i<attrs.length;i++) fs.symlinkSync(path.join(built[i],'bin','ham-'+attrs[i]),path.join(bin,'ham-'+attrs[i]));
  }
  await new Promise(r=>fake.listen(tgPort,'127.0.0.1',r));
  await run('scripts/local-hub.sh',['start','--name','bots-cap-e2e','--hub-port',String(hubPort),
    '--proxy-port',String(proxyPort),'--ui-port',String(uiPort),'--oidc-port',String(oidcPort),'--no-plan-limits','--bin-dir',bin]);
  process.env.HEIMDALL_LOCAL_UI_ORIGIN='http://127.0.0.1:'+uiPort;
  headers=sessionHeaders(await hubLogin(api,''),process.env.HEIMDALL_LOCAL_UI_ORIGIN);
  const {openSeedApprover}=await import('../../scripts/local-runtime/approver.mjs');
  const {importKeyring}=await import('../../src/ui/utils/vaultKeyring.ts');
  const {setActiveVaultKey,decryptVaultText}=await import('../../src/ui/utils/vaultCrypto.ts');
  app=await openSeedApprover({api,key:path.join(hubDir,'approver/device.json')});
  keyring=await importKeyring(app.keyringBytes);
  setActiveVaultKey(keyring);
  globalThis.fetch=(url,init={})=>nativeFetch(String(url).startsWith('/api/v1')?api+url:url,
    {...init,headers:{...headers,...init.headers},signal:init.signal||AbortSignal.timeout(40000)});
  await startBridge('bots-cap-e2e-a');
  const {providerProfilesApi}=await import('../../src/ui/components/providers/providerProfiles.ts');
  async function profile(bridge,profileId,mode) {
    await providerProfilesApi.operate(bridge,profileId,'upsert',{
      provider:'pi',label_enc:'',accent:'',enabled:true,environment:[{name:'BOT_AGENT_MODE',value:mode,sensitive:false}],
      config:{binary_path:path.join(repo,'tools/mock_agent/bot-agent.sh')}});
    await request('/bridges/'+bridge+'/providers/discover','POST',{stage:'providers',profile_id:profileId});
  }
  await profile(bridgeId('bots-cap-e2e-a'),'pi','reply');
  await profile(bridgeId('bots-cap-e2e-a'),'bots-good','ctl');
  await request('/me/experiments/bots','PUT',{enabled:true});
  await request('/bots/me','POST',{},201);
  await placement([row('pi')]);
  const pairing=await request('/bots/me/channels/telegram/pairing','POST',{},201);
  await inject('/start '+new URL(pairing.pairing_url).searchParams.get('start'));
  await expectSent(copies.COPY_PAIRED);
  await poll(async()=> (await request('/bots/me')).telegram.binding?.state==='active','binding');
  // Launch once before recording the actor, and prove this profile is in ctl mode.
  await command('projects list');
  botInstance=(await request('/bots/me')).advanced.agent_instance_id;
  const bot=await request('/agent-instances/'+botInstance);
  assert.equal(bot.provider_profile,'bots-good');
  botModel=bot.model;
  log('ASSUMPTION: bot vault access will be checked by sealed project/memory writes below');

  await step(1,'create project with bot actor',async()=>{
    const reply=await command('projects create --name e2e-proj --default-path /tmp/e2e-proj');
    projectId=findField(reply.result,'project_id');assert.ok(projectId,reply.text);
    const project=await request('/projects/'+projectId);
    assert.equal(await decryptVaultText(project.name),'e2e-proj');
    return {reply,project,write:await assertWrite('project','create',projectId)};
  });
  await step(2,'update and archive project',async()=>{
    const updated=await command('projects update '+projectId+' --description changed');
    const project=await request('/projects/'+projectId);
    assert.equal(await decryptVaultText(project.description),'changed');
    const archived=await command('projects archive '+projectId);
    assert.equal((await request('/projects/'+projectId)).state,'archived');
    return {updated,archived,project,writes:[
      await assertWrite('project','update',projectId),await assertWrite('project','archive',projectId)]};
  });
  await step(3,'create active memory without approval',async()=>{
    const reply=await command('memory create --type fact --title e2e-mem --body "deploys go through deployd"');
    memoryId=findField(reply.result,'memory_id');assert.ok(memoryId,reply.text);
    const memory=await request('/memories/'+memoryId);
    assert.equal(memory.status,'active');
    assert.equal(await decryptVaultText(memory.body),'deploys go through deployd');
    return {reply,memory,write:await assertWrite('memory','create',memoryId)};
  });
  await step(4,'archive active memory',async()=>{
    const reply=await command('memory archive '+memoryId);
    const memory=await request('/memories/'+memoryId);
    assert.equal(memory.status,'archived');
    return {reply,memory};
  });
  await step(5,'pending proposal cannot be archived',async()=>{
    const proposed=await command('memory propose --type fact --title p --body q');
    pendingId=findField(proposed.result,'memory_id');assert.ok(pendingId);
    assert.equal((await request('/memories/'+pendingId)).status,'pending');
    const refused=await command('memory archive '+pendingId,false);
    assert.equal(refused.result.ok,false);
    assert.ok(refused.text.includes('memory_not_active'));
    const memory=await request('/memories/'+pendingId);
    assert.equal(memory.status,'pending');
    return {proposed,refused,memory};
  });
  await step(6,'message wakes stopped coordinator and is read',async()=>{
    // Same script/profile; switch its environment only after the bot process starts.
    await profile(bridgeId('bots-cap-e2e-a'),'bots-good','reply');
    coordAgent=await request('/agents','POST',{name:'e2e-coord',template_id:'tmpl_coordinator'},201);
    coordinator=await request('/agent-instances','POST',{
      agent_id:coordAgent.agent_id,bridge_id:bridgeId('bots-cap-e2e-a'),provider:'pi',provider_profile:'bots-good',model:botModel},201);
    const id=coordinator.agent_instance_id;
    await poll(async()=> (await request('/agent-instances/'+id)).runtime_status==='running','coordinator running');
    await request('/agent-instances/'+id+'/stop','POST',{reason:'test_idle'},202);
    await poll(async()=> (await request('/agent-instances/'+id)).runtime_status==='stopped','coordinator stopped');
    const reply=await command('chat send --to '+id+' --body ping');
    assert.equal(findField(reply.result,'wake'),'started',reply.text);
    await poll(async()=> (await request('/agent-instances/'+id)).runtime_status==='running','coordinator reawakened');
    const read=await poll(async()=>{
      const rows=await sql("SELECT message_id,read_at FROM chat_messages WHERE conversation_id=? AND sender_agent_instance_id=? AND direction='agent_to_agent'",[coordinator.conversation_id,botInstance]);
      return rows.find(r=>r.read_at);
    },'ping read by re-notify',90000);
    await profile(bridgeId('bots-cap-e2e-a'),'bots-good','ctl');
    return {reply,read,instance:await request('/agent-instances/'+id)};
  });
  await step(7,'user stop suppresses wake for 30 seconds',async()=>{
    const id=coordinator.agent_instance_id;
    await request('/agent-instances/'+id+'/stop','POST',{},202);
    await poll(async()=> (await request('/agent-instances/'+id)).runtime_status==='stopped','user stopped');
    const reply=await command('chat send --to '+id+' --body ping2');
    assert.equal(findField(reply.result,'wake'),'user_stopped',reply.text);
    const until=Date.now()+30000;
    do {assert.equal((await request('/agent-instances/'+id)).runtime_status,'stopped');await sleep(500);} while(Date.now()<until);
    return {reply,instance:await request('/agent-instances/'+id)};
  });
  await step(8,'update agent permission mode with actor fields',async()=>{
    const reply=await command('agents identity update '+coordAgent.agent_id+' --permission-mode ask');
    const agent=await request('/agents/'+coordAgent.agent_id);
    assert.equal(agent.permission_mode,'ask');
    return {reply,agent,write:await assertWrite('agent','update',coordAgent.agent_id,['permission_mode'])};
  });
  await step(9,'server preview authenticated GET and kill',async()=>{
    const reply=await command("shell serve --cmd 'python3 -m http.server 18777' --cwd /tmp --port 18777 --label e2e");
    const preview=findField(reply.result,'preview_url'), session=findField(reply.result,'session_id');
    assert.ok(preview);assert.ok(session);
    const previewPath=new URL(preview).pathname;
    assert.equal(previewPath,'/api/v1/preview/'+session+'/');
    // Revision 2: the local Vite dev UI deliberately bypasses preview requests
    // and serves index.html. Check the unchanged returned path on its API upstream.
    // Real deployment preview origins require the separate staging check.
    const checkedPreview=new URL(previewPath,api).href;
    const response=await poll(async()=>{
      const response=await nativeFetch(checkedPreview,{headers,signal:AbortSignal.timeout(30000)});
      if(response.status===502) {await response.text();return false;}
      return response;
    },'local preview socket ready',15000);
    assert.equal(response.status,200);
    const listing=await response.text();assert.match(listing,/Directory listing/);
    const killed=await command('shell kill '+session);
    const terminal=await poll(async()=>{
      const {session:view}=await request('/shells/'+session);
      return ['exited','killed','completed','failed'].includes(view.status)&&view;
    },'shell terminal');
    // Verify section 9.2's marked same-owner cross-bridge server assumption.
    const remotePort=await preferredPort(49631,50100),remoteEp=await preferredPort(49632,50200);
    await run('scripts/local-bridge.sh',['start','--name','bots-cap-e2e-preview','--hub','bots-cap-e2e',
      '--port',String(remotePort),'--local-endpoint-port',String(remoteEp),'--auto-enroll','--isolated-home',
      '--providers','git','--bin-dir',bin]);
    const remoteHttp=await preferredPort(18778,18800);
    const remote=await command("shell serve --bridge "+bridgeId('bots-cap-e2e-preview')+
      " --cmd 'python3 -m http.server "+remoteHttp+"' --cwd /tmp --port "+remoteHttp+" --label e2e-remote");
    const remoteSession=findField(remote.result,'session_id');
    assert.equal((await request('/shells/'+remoteSession)).session.bridge_id,bridgeId('bots-cap-e2e-preview'));
    const remotePath=new URL(findField(remote.result,'preview_url')).pathname;
    assert.equal(remotePath,'/api/v1/preview/'+remoteSession+'/');
    const remoteResponse=await poll(async()=>{
      const response=await nativeFetch(new URL(remotePath,api),{headers,signal:AbortSignal.timeout(30000)});
      // The RPC acknowledges process creation before Python has bound its socket.
      if(response.status===502) {await response.text();return false;}
      return response;
    },'remote preview socket ready',15000);
    assert.equal(remoteResponse.status,200);
    assert.match(await remoteResponse.text(),/Directory listing/);
    await command('shell kill '+remoteSession);
    return {reply,preview,checkedPreview,status:response.status,listing,killed,terminal,remote,remoteStatus:remoteResponse.status};
  });
  await step('9a','new chain requires its own yes and forwards the request',async()=>{
    const reply=await command('projects create --name confirmed-chain-project --default-path /tmp');
    const project=findField(reply.result,'project_id');
    const args='--kind mixed_work --title confirmed-chat-chain --project '+project+' --coordinator '+coordAgent.agent_id+
      ' --bridge '+bridgeId('bots-cap-e2e-a')+' --provider pi --model '+botModel;
    const count=async()=> (await sql('SELECT count(*) AS n FROM task_chains'))[0].n;
    const before=await count();
    async function prompt() {
      const offset=(await sent()).length;
      await inject('confirm chain '+args);
      await poll(async()=> (await sent()).slice(offset).find(m=>m.text==='Confirm chain '+args+'. Reply yes to confirm.'),'chain prompt');
    }
    await prompt();
    assert.equal(await count(),before,'no creation before yes');
    let offset=(await sent()).length;
    await inject('y');
    await poll(async()=> (await sent()).slice(offset).find(m=>m.text==='Cancelled.'),'chain cancellation');
    assert.equal(await count(),before,'y cancels chain creation');
    await prompt();
    offset=(await sent()).length;
    await inject('YES');
    const created=await poll(async()=>{
      for(const m of (await sent()).slice(offset)) {
        try {const result=JSON.parse(m.text);const id=findField(result,'chain_id');if(id)return {id,result};} catch {}
      }
    },'confirmed chain');
    assert.equal(await count(),before+1);
    const chain=await request('/task-chains/'+created.id);
    assert.equal(await decryptVaultText(chain.title),'confirmed-chat-chain');
    assert.ok(chain.coordinator_agent_instance_id);
    const forwarded=await poll(async()=>{
      const rows=await sql("SELECT body FROM chat_messages WHERE conversation_id=(SELECT conversation_id FROM agent_instances WHERE agent_instance_id=?) AND sender_agent_instance_id=? AND direction='agent_to_agent'",
        [chain.coordinator_agent_instance_id,botInstance]);
      for(const row of rows) {
        if((await decryptVaultText(row.body))==='From the user via chat: confirm chain '+args)return true;
      }
    },'original request forwarded');
    return {created,chain,forwarded};
  });
  await step('9b','each foreground command requires a fresh yes',async()=>{
    const args="--cmd 'printf confirmed-command' --cwd /tmp --bridge "+bridgeId('bots-cap-e2e-a');
    const count=async()=> (await sql("SELECT count(*) AS n FROM shell_sessions WHERE kind='run'"))[0].n;
    const before=await count();
    async function prompt() {
      const offset=(await sent()).length;
      await inject('confirm command '+args);
      await poll(async()=> (await sent()).slice(offset).find(m=>m.text==='Confirm command '+args+'. Reply yes to confirm.'),'command confirmation');
    }
    await prompt();
    assert.equal(await count(),before,'no command before yes');
    let offset=(await sent()).length;
    await inject('confirm');
    await poll(async()=> (await sent()).slice(offset).find(m=>m.text==='Cancelled.'),'command cancellation');
    assert.equal(await count(),before,'confirm is not yes');
    await prompt();
    offset=(await sent()).length;
    await inject('yes');
    const result=await poll(async()=>{
      for(const m of (await sent()).slice(offset)) {
        try {const value=JSON.parse(m.text);if(findField(value,'session_id'))return value;} catch {}
      }
    },'foreground command result');
    assert.equal(result.ok,true);
    const rows=await sql("SELECT status,exit_code FROM shell_sessions WHERE session_id=?",[findField(result,'session_id')]);
    assert.equal(rows[0].exit_code,0);
    assert.ok(['completed','exited'].includes(rows[0].status));
    assert.match(JSON.stringify(result),/confirmed-command/);
    assert.equal(await count(),before+1);
    await prompt();
    offset=(await sent()).length;
    await inject('no');
    await poll(async()=> (await sent()).slice(offset).find(m=>m.text==='Cancelled.'),'fresh cancellation');
    assert.equal(await count(),before+1,'previous yes does not authorize another command');
    return {result,rows};
  });
  await step(10,'second owner cannot update project or wake coordinator',async()=>{
    // The mock provider supports login_hint; prove these sessions have different owners.
    const ownerA=await request('/me');
    const savedHeaders=headers;
    headers=sessionHeaders(await hubLogin(api,'paid'),process.env.HEIMDALL_LOCAL_UI_ORIGIN);
    const ownerB=await request('/me');
    assert.notEqual(ownerA.user_id,ownerB.user_id);
    otherApp=await openSeedApprover({api,key:path.join(hubDir,'approver/users/paid/device.json'),user:'paid'});
    setActiveVaultKey(await importKeyring(otherApp.keyringBytes));
    await run('scripts/local-bridge.sh',['start',...bridgeArgs('bots-cap-e2e-b'),'--user','paid']);
    await profile(bridgeId('bots-cap-e2e-b'),'pi','reply');
    await profile(bridgeId('bots-cap-e2e-b'),'bots-good','reply');
    const agent=await request('/agents','POST',{name:'e2e-owner-b',template_id:'tmpl_coordinator'},201);
    const instance=await request('/agent-instances','POST',{
      agent_id:agent.agent_id,bridge_id:bridgeId('bots-cap-e2e-b'),provider:'pi',provider_profile:'bots-good',model:botModel},201);
    await poll(async()=> (await request('/agent-instances/'+instance.agent_instance_id)).runtime_status==='running','B running');
    // Only isolated bootstrap shim is read; credentials are never written to evidence.
    const files=await run('find',[bridgeDir('bots-cap-e2e-b'),'-path','*/'+instance.agent_instance_id+'/bin/ham-ctl']);
    const shim=fs.readFileSync(files.trim(),'utf8');
    const token=shim.match(/HEIMDALL_AGENT_TOKEN='([^']+)'/)[1];
    async function relay(method,route,body) {
      return await new Promise((resolve,reject)=>{
        const socket=net.connect(bEp,'127.0.0.1');
        let output='';
        socket.setTimeout(40000,()=>socket.destroy(new Error('relay timeout')));
        socket.on('error',reject);
        socket.on('connect',()=>socket.write(JSON.stringify({v:1,id:'c6',token,method:'agent.rest.request',params:{http_method:method,path:route,body:JSON.stringify(body)}})+'\n'));
        socket.on('data',chunk=>{
          output+=chunk;
          if(output.includes('\n')) {socket.destroy();resolve(JSON.parse(output.split('\n')[0]));}
        });
      });
    }
    headers=savedHeaders;
    setActiveVaultKey(keyring);
    const before=await request('/projects/'+projectId);
    const beforeMessages=await sql('SELECT count(*) AS n FROM chat_messages WHERE conversation_id=?',[coordinator.conversation_id]);
    const patch=await relay('PATCH','/api/v1/projects/'+projectId,{description:'forbidden'});
    const message=await relay('POST','/api/v1/agent-actions/chat/send-to-agent',{
      agent_instance_id:instance.agent_instance_id,params:{to_instance:coordinator.agent_instance_id,body:'cross owner'}});
    for(const result of [patch,message]) {
      assert.equal(result.ok,false,JSON.stringify(result));
      const error=JSON.parse(result.error.message);
      assert.equal(error.error.code,'not_found',JSON.stringify(result));
    }
    assert.deepEqual(await request('/projects/'+projectId),before);
    assert.deepEqual(await sql('SELECT count(*) AS n FROM chat_messages WHERE conversation_id=?',[coordinator.conversation_id]),beforeMessages);
    assert.equal((await request('/agent-instances/'+coordinator.agent_instance_id)).runtime_status,'stopped');
    return {ownerA:ownerA.user_id,ownerB:ownerB.user_id,patch,message,project:before,instance:await request('/agent-instances/'+coordinator.agent_instance_id)};
  });
  log('PASS: all 12 capabilities steps');
} catch(error) {
  log('FAIL: '+(error.stack||error));process.exitCode=1;
} finally {
  globalThis.fetch=nativeFetch;
  for(const name of ['bots-cap-e2e-a','bots-cap-e2e-b','bots-cap-e2e-preview']) {
    if(fs.existsSync(bridgeDir(name))) {
      try {await run('scripts/local-bridge.sh',['stop','--name',name,'--purge-home']);} catch(e) {log('CLEANUP ERROR '+e.message);process.exitCode=1;}
    }
  }
  if(fs.existsSync(hubDir)) {
    try {await run('scripts/local-hub.sh',['stop','--name','bots-cap-e2e']);} catch(e) {log('CLEANUP ERROR '+e.message);process.exitCode=1;}
  }
  fake.closeAllConnections();
  if(fake.listening) await new Promise(r=>fake.close(r));
  if(app) app.keyringBytes.fill(0);
  if(otherApp) otherApp.keyringBytes.fill(0);
  log('Evidence retained at '+root);
}
