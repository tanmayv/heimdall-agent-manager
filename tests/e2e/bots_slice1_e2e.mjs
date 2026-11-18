// Spec 20.3: real isolated hub and two bridges; no model or Telegram credentials.
// Run inside nix develop: node tests/e2e/bots_slice1_e2e.mjs
// Requires npm ci, Python 3, and Puppeteer with an installed Chromium browser.
// BOTS_E2E_PUPPETEER may name an external Puppeteer module (default: puppeteer).
// BOTS_E2E_BIN_DIR may point at prebuilt binaries; otherwise Nix builds them.
// Logs/screenshots remain in BOTS_E2E_EVIDENCE_ROOT (default: /var/tmp).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {hubLogin, sessionHeaders, freePort} from './hubOidc.mjs';
import {createFakeTelegram} from '../../tools/fake_telegram/server.mjs';
import '../helpers/vaultEndpointHarness.ts';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const root=fs.mkdtempSync(path.join(process.env.BOTS_E2E_EVIDENCE_ROOT || '/var/tmp','bots-slice1-e2e-'));
const state=path.join(root,'state'), bin=process.env.BOTS_E2E_BIN_DIR || path.join(root,'bin');
fs.mkdirSync(bin,{recursive:true});
const logFile=path.join(root,'run.log');
const log=(s)=>{console.log(s);fs.appendFileSync(logFile,s+'\n');};
log('A9 evidence: '+root);
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
const ports=await Promise.all(Array.from({length:9},()=>freePort()));
const [hubPort,proxyPort,uiPort,oidcPort,aPort,aEp,bPort,bEp,tgPort]=ports;
assert.equal(new Set(ports).size,ports.length);
const api='http://127.0.0.1:'+proxyPort, tg='http://127.0.0.1:'+tgPort;
Object.assign(env,{
  HEIMDALL_TELEGRAM_BOT_TOKEN:'TEST:FAKE',HEIMDALL_TELEGRAM_API_BASE:tg,
  HEIMDALL_BOT_TIMERS_JSON:JSON.stringify({read_ms:15000,idle_no_reply_ms:20000,bot_attempt_silence_ms:30000,bot_disconnect_grace_ms:5000}),
});
const fake=createFakeTelegram({token:'TEST:FAKE',botUsername:'ninjy_test_bot'});
const hubDir=path.join(state,'hubs/bots-e2e');
const hubLog=()=>fs.readFileSync(path.join(hubDir,'logs/hub.log'),'utf8');
let headers, keyring, app, browser;
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
const messages=async()=> (await request('/bots/me/channels/telegram/messages?limit=100')).messages;
const deliveries=async()=> (await request('/bots/me/deliveries?limit=100')).deliveries;
async function actedAfter(previous,text,timeout=90000) {
  await expectSent(text,timeout);
  return poll(async()=> (await deliveries()).find(d=>!previous.has(d.delivery_id)&&d.finish_reason==='acted'),'acted delivery');
}
async function step(n,name,fn) {
  log('STEP '+n+': '+name);
  await fn();
  fs.writeFileSync(path.join(root,'step-'+n+'.json'),JSON.stringify({telegram:await sent()},null,2));
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
const bridgeArgs=name=>['--name',name,'--hub','bots-e2e','--port',String(name.endsWith('-a')?aPort:bPort),
  '--local-endpoint-port',String(name.endsWith('-a')?aEp:bEp),'--auto-enroll','--isolated-home','--providers','git','--bin-dir',bin];
const startBridge=name=>run('scripts/local-bridge.sh',['start',...bridgeArgs(name)]);
const stopBridge=name=>run('scripts/local-bridge.sh',['stop','--name',name]);
async function placement(candidates) {
  const current=await request('/bots/me/placement');
  return request('/bots/me/placement','PUT',{expected_revision:current.placement_revision,candidates});
}
const row=(provider,tier='preferred')=>({bridge_id:'*',provider,model:'*',tier});

try {
  if(!process.env.BOTS_E2E_BIN_DIR) {
    const attrs=['hub','bridge','ctl','pty-host','dev-proxy'];
    const built=(await run('nix',['build',...attrs.map(a=>'.#ham-'+a),'--no-link','--print-out-paths'])).trim().split('\n');
    assert.equal(built.length,attrs.length);
    for(let i=0;i<attrs.length;i++) fs.symlinkSync(path.join(built[i],'bin','ham-'+attrs[i]),path.join(bin,'ham-'+attrs[i]));
  }
  await new Promise(r=>fake.listen(tgPort,'127.0.0.1',r));
  await run('scripts/local-hub.sh',['start','--name','bots-e2e','--hub-port',String(hubPort),
    '--proxy-port',String(proxyPort),'--ui-port',String(uiPort),'--oidc-port',String(oidcPort),'--no-plan-limits','--bin-dir',bin]);
  process.env.HEIMDALL_LOCAL_UI_ORIGIN='http://127.0.0.1:'+uiPort;
  headers=sessionHeaders(await hubLogin(api,''),process.env.HEIMDALL_LOCAL_UI_ORIGIN);
  const {openSeedApprover,approveDevice}=await import('../../scripts/local-runtime/approver.mjs');
  const {importKeyring}=await import('../../src/ui/utils/vaultKeyring.ts');
  const {setActiveVaultKey}=await import('../../src/ui/utils/vaultCrypto.ts');
  app=await openSeedApprover({api,key:path.join(hubDir,'approver/device.json')});
  keyring=await importKeyring(app.keyringBytes);
  setActiveVaultKey(keyring);
  globalThis.fetch=(url,init={})=>nativeFetch(String(url).startsWith('/api/v1')?api+url:url,
    {...init,headers:{...headers,...init.headers},signal:init.signal||AbortSignal.timeout(40000)});
  await step(0,'experiment off, API gated and poller absent for 35 seconds',async()=>{
    const off=await request('/bots/me','GET',undefined,403);
    assert.equal(off.error.details.code,'experimental_feature_disabled');
    await sleep(35000);
    assert.deepEqual(await control('offsets'),[]);
    assert.ok(!hubLog().includes('bots:'),'no bot runtime activity while experiment is off');
    assert.deepEqual(await sent(),[]);
  });
  await startBridge('bots-e2e-a');
  await startBridge('bots-e2e-b');
  const {providerProfilesApi}=await import('../../src/ui/components/providers/providerProfiles.ts');
  for(const name of ['bots-e2e-a','bots-e2e-b']) {
    // The local runnable probe resolves the base provider binary. Keep that
    // prerequisite deterministic too; every eligible binary is a fixture script.
    for(const [provider,file] of [['pi','tools/mock_agent/bot-agent.sh'],['claude','tests/e2e/fixtures/bots_failing_provider.sh']]) {
      await providerProfilesApi.operate(bridgeId(name),provider,'upsert',{
        provider,label_enc:'',accent:'',enabled:true,environment:[],config:{binary_path:path.join(repo,file)}});
    }
    for(const [id,provider,file] of [['bots-good','pi','tools/mock_agent/bot-agent.sh'],['bots-bad','claude','tests/e2e/fixtures/bots_failing_provider.sh']]) {
      await providerProfilesApi.operate(bridgeId(name),id,'upsert',{
        provider,label_enc:'',accent:'',enabled:true,environment:[],config:{binary_path:path.join(repo,file)}});
    }
    for(const profile_id of ['bots-good','bots-bad','pi','claude'])
      await request('/bridges/'+bridgeId(name)+'/providers/discover','POST',{stage:'providers',profile_id});
    const found=await providerProfilesApi.operate(bridgeId(name),'bots-good','get');
    assert.equal(found.config.binary_path,path.join(repo,'tools/mock_agent/bot-agent.sh'));
  }
  log('ASSUMPTION: custom binary profiles created through sealed profile API on both bridges');
  await step(1,'enable experiment and create bot',async()=>{
    await request('/me/experiments/bots','PUT',{enabled:true});
    const created=await request('/bots/me','POST',{},201);
    assert.equal(created.status,'new');
    await placement([row('pi')]);
    assert.deepEqual(await sent(),[]);
  });
  await step(2,'pair Telegram',async()=>{
    const pairing=await request('/bots/me/channels/telegram/pairing','POST',{},201);
    const code=new URL(pairing.pairing_url).searchParams.get('start');
    assert.ok(code);
    await inject('/start '+code);
    await expectSent(copies.COPY_PAIRED);
    await poll(async()=> (await request('/bots/me')).telegram.binding?.state==='active','active binding');
  });
  await step(3,'hi is acted and inbound is marked replied',async()=>{
    const previous=new Set((await deliveries()).map(d=>d.delivery_id));
    const inboundMessageId=10001;
    await inject('hi',undefined,inboundMessageId);
    await actedAfter(previous,'echo: hi');
    const reactions=(await control('reactions?chat_id=111')).reactions.filter(r=>r.message_id===inboundMessageId);
    assert.deepEqual(reactions,[{chat_id:111,message_id:inboundMessageId,reaction:[{type:'emoji',emoji:'👀'}]}]);
    assert.ok((await messages()).find(m=>m.direction==='inbound'&&m.body==='hi'&&m.replied_at));
    const view=await request('/bots/me');
    assert.equal(view.advanced.bridge_id,bridgeId('bots-e2e-a'));
    const instance=await request('/agent-instances/'+view.advanced.agent_instance_id);
    assert.equal(instance.provider_profile,'bots-good');
    log('ASSUMPTION: hub launched the custom binary profile as an ordinary provider');
  });
  await step(4,'status question reads seeded sample chain',async()=>{
    const {encryptVaultText}=await import('../../src/ui/utils/vaultCrypto.ts');
    await request('/task-chains','POST',{title:await encryptVaultText('Sample: A9 status fixture'),description:await encryptVaultText('Isolated E2E sample chain')},201);
    const previous=new Set((await deliveries()).map(d=>d.delivery_id));
    await inject('status?');
    await poll(async()=> (await sent()).find(m=>m.text.startsWith('chains: Sample: ')),'seeded chain reply');
    await poll(async()=> (await deliveries()).find(d=>!previous.has(d.delivery_id)&&d.finish_reason==='acted'),'status acted');
  });

  const originalBot=await request('/bots/me');
  const instanceId=originalBot.advanced.agent_instance_id;
  const originalInstance=await request('/agent-instances/'+instanceId);

  await step(5,'bridge A offline, relocate to B with stable instance/conversation',async()=>{
    const previous=new Set((await deliveries()).map(d=>d.delivery_id));
    await stopBridge('bots-e2e-a');
    await inject('still there?');
    const delivery=await actedAfter(previous,'echo: still there?');
    assert.ok(delivery.attempts.some(a=>a.bridge_id===bridgeId('bots-e2e-b')&&a.state==='acted'));
    for(const attempt of delivery.attempts.filter(a=>a.bridge_id===bridgeId('bots-e2e-a')))
      assert.equal(attempt.state,'disconnected');
    const moved=await request('/bots/me');
    assert.equal(moved.advanced.agent_instance_id,instanceId);
    assert.equal(moved.advanced.bridge_id,bridgeId('bots-e2e-b'));
    const instance=await request('/agent-instances/'+instanceId);
    assert.equal(instance.conversation_id,originalInstance.conversation_id);
    const ops=await request('/agent-instances/'+instanceId+'/reconfigurations');
    assert.ok(ops.operations.some(o=>(o.phase===4||String(o.phase).toLowerCase()==='ready')&&o.destination.bridge_id===bridgeId('bots-e2e-b')),'relocation ready');
  });
  await step(6,'no machines: saved message resumes when bridge B returns',async()=>{
    const previous=new Set((await deliveries()).map(d=>d.delivery_id));
    await stopBridge('bots-e2e-b');
    await inject('anyone?');
    await expectSent(copies.COPY_NO_MACHINE);
    await poll(async()=> (await deliveries()).find(d=>!previous.has(d.delivery_id)&&d.state==='waiting'),'waiting delivery');
    await startBridge('bots-e2e-b');
    // Normal startup restores this isolated bridge's persisted vault keyring.
    await actedAfter(previous,'echo: anyone?');
    assert.equal((await request('/bots/me')).advanced.agent_instance_id,instanceId);
  });
  await step(7,'first provider fails at launch, second provider acts',async()=>{
    await placement([row('claude'),row('pi','allowed')]);
    // Clear the existing live-provider stickiness so a fresh preferred launch is tested.
    await request('/agent-instances/'+instanceId+'/stop','POST',{force:true,reason:'bot_idle'},202);
    await poll(async()=> {
      const i=await request('/agent-instances/'+instanceId);
      return ['stopped','terminated','failed'].includes(i.runtime_status);
    },'bot stopped before preferred provider launch');
    const previous=new Set((await deliveries()).map(d=>d.delivery_id));
    await inject('retry provider');
    const delivery=await actedAfter(previous,'echo: retry provider',180000);
    // R2 closes the attempt inside channel send; the later terminal report is
    // acknowledged without replacing its stored progress. Observe the real
    // bridge's successfully sent terminal report through its diagnostic log.
    const report=await poll(()=>{
      const text=fs.readFileSync(path.join(bridgeDir('bots-e2e-b'),'logs/bridge.log'),'utf8');
      return text.split('\n').filter(line=>line.startsWith('bots: terminal report '))
        .map(line=>JSON.parse(line.slice('bots: terminal report '.length)))
        .find(r=>r.delivery_id===delivery.delivery_id&&r.state==='acted');
    },'sent terminal report with candidate outcomes');
    assert.ok(delivery.attempts.some(a=>a.attempt_id===report.attempt_id));
    fs.writeFileSync(path.join(root,'step-7-report.json'),JSON.stringify(report,null,2));
    log('TERMINAL REPORT '+JSON.stringify(report));
    assert.deepEqual(report.outcomes.map(o=>o.outcome),['launch_failed','acted']);
    assert.deepEqual(report.outcomes.map(o=>o.provider),['claude','pi']);
  });
  await step(8,'duplicate Telegram update creates one channel message',async()=>{
    const previous=new Set((await deliveries()).map(d=>d.delivery_id));
    const duplicateId=8000;
    await Promise.all([inject('dedupe',duplicateId),inject('dedupe',duplicateId)]);
    await actedAfter(previous,'echo: dedupe');
    const rows=await sql("SELECT provider_update_key FROM channel_messages WHERE direction='inbound' AND provider_update_key LIKE '%:8000'");
    assert.equal(rows.length,1);
    assert.equal((await messages()).filter(m=>m.direction==='inbound'&&m.body==='dedupe').length,1);
    assert.equal((await sent()).filter(m=>m.text==='echo: dedupe').length,1);
  });
  await step(9,'disconnect purges bodies and rejects new messages',async()=>{
    await request('/bots/me/channels/telegram','DELETE');
    await expectSent(copies.COPY_DISCONNECTED);
    const rows=await sql("SELECT body,body_purged FROM channel_messages");
    assert.ok(rows.length>0);
    assert.ok(rows.every(r=>r.body===''&&r.body_purged===1));
    assert.ok((await messages()).every(m=>m.body===''&&m.body_purged));
    await inject('after disconnect');
    await expectSent(copies.COPY_NOT_CONNECTED);
  });
  const {default:puppeteer}=await import(process.env.BOTS_E2E_PUPPETEER || 'puppeteer');
  browser=await puppeteer.launch({headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  const page=await browser.newPage();
  await page.setViewport({width:1440,height:1000});
  const cookie=headers.Cookie.split('=').slice(1).join('=');
  await page.setCookie({name:'__Host-heimdall_session',value:cookie,domain:'127.0.0.1',path:'/',secure:true,httpOnly:true,sameSite:'Lax'});
  const ui='http://127.0.0.1:'+uiPort;
  await page.goto(ui+'/#/settings',{waitUntil:'networkidle2'});
  await poll(async()=>await page.$('[data-debug-id="device-waiting-code"],[data-debug-id="settings-nav-item-bots"]'),'browser enrollment or Settings');
  if(await page.$('[data-debug-id="device-waiting-code"]')) {
    const code=await page.$eval('[data-debug-id="device-waiting-code"]',e=>e.textContent.trim());
    await approveDevice({api,key:path.join(hubDir,'approver/device.json'),code,label:'A9 isolated browser'});
    await page.waitForFunction(()=>!location.hash.includes('/device/'),{timeout:30000});
    await page.goto(ui+'/#/settings',{waitUntil:'networkidle2'});
  }
  await page.waitForSelector('[data-debug-id="settings-nav-item-bots"]',{timeout:30000});
  await page.screenshot({path:path.join(root,'bots-enabled.png')});
  log('Browser positive control: Settings Bots entry is present');

  await step(10,'disable abandons open delivery, stops workers and hides Settings Bots',async()=>{
    // Re-pair solely to arrange an open waiting delivery for the disable assertion.
    const pairing=await request('/bots/me/channels/telegram/pairing','POST',{},201);
    await inject('/start '+new URL(pairing.pairing_url).searchParams.get('start'));
    await poll(async()=> (await request('/bots/me')).telegram.binding?.state==='active','re-paired binding');
    await stopBridge('bots-e2e-b');
    await inject('pending at disable');
    const waiting=await poll(async()=> (await deliveries()).find(d=>d.state==='waiting'),'open delivery before disable');
    await request('/me/experiments/bots','PUT',{enabled:false});
    const rows=await sql("SELECT state,finish_reason FROM bot_deliveries WHERE delivery_id=?",[waiting.delivery_id]);
    assert.deepEqual(rows,[{state:'abandoned',finish_reason:'experiment_disabled'}]);
    assert.ok(hubLog().includes('bots: runtime stopped'));
    const offsets=await control('offsets');
    const sentAtDisable=await sent();
    await sleep(35000);
    assert.deepEqual(await control('offsets'),offsets);
    assert.deepEqual(await sent(),sentAtDisable);
    await request('/bots/me','GET',undefined,403);
    await page.reload({waitUntil:'networkidle2'});
    await page.waitForSelector('[data-debug-id="settings-modal-container"]');
    await poll(async()=> await page.evaluate(async()=> {
      const r=await fetch('/api/v1/me/experiments');
      const body=await r.json();
      return body.data.experiments.find(e=>e.key==='bots')?.enabled===false;
    }),'browser observes disabled experiment');
    assert.equal(await page.$('[data-debug-id="settings-nav-item-bots"]'),null);
    await page.screenshot({path:path.join(root,'bots-disabled.png')});
  });
  log('PASS: all 11 spec 20.3 steps');

} catch(error) {
  log('FAIL: '+(error.stack||error));
  if(browser) for(const [index,page] of (await browser.pages()).entries()) {
    try {
      log('Browser '+page.url()+' '+(await page.evaluate(()=>document.body.innerText)).slice(0,2500));
      await page.screenshot({path:path.join(root,'failure-'+index+'.png')});
    } catch {}
  }
  process.exitCode=1;
} finally {
  if(browser) await browser.close();
  globalThis.fetch=nativeFetch;
  for(const name of ['bots-e2e-a','bots-e2e-b']) {
    try {await run('scripts/local-bridge.sh',['stop','--name',name,'--purge-home']);} catch(e) {log('CLEANUP ERROR '+e.message);process.exitCode=1;}
  }
  try {await run('scripts/local-hub.sh',['stop','--name','bots-e2e']);} catch(e) {log('CLEANUP ERROR '+e.message);process.exitCode=1;}
  fake.closeAllConnections();
  if(fake.listening) await new Promise(r=>fake.close(r));
  if(app) app.keyringBytes.fill(0);

  log('Evidence retained at '+root);
}
