// Spec 21.2: isolated hub/bridge with fake WhatsApp and Telegram; no real credentials.
// Run inside nix develop: node tests/e2e/bots_whatsapp_e2e.mjs
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
import {createFakeWhatsApp} from '../../tools/fake_whatsapp/server.mjs';
import {createFakeTelegram} from '../../tools/fake_telegram/server.mjs';
import '../helpers/vaultEndpointHarness.ts';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const root=fs.mkdtempSync(path.join(process.env.BOTS_E2E_EVIDENCE_ROOT || '/var/tmp','bots-whatsapp-e2e-'));
const state=path.join(root,'state'), bin=process.env.BOTS_E2E_BIN_DIR || path.join(root,'bin');
fs.mkdirSync(bin,{recursive:true});
const logFile=path.join(root,'run.log');
const log=(s)=>{console.log(s);fs.appendFileSync(logFile,s+'\n');};
log('W7 evidence: '+root);
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
const ports=await Promise.all(Array.from({length:8},()=>freePort()));
const [hubPort,proxyPort,uiPort,oidcPort,aPort,aEp,tgPort,waPort]=ports;
assert.equal(new Set(ports).size,ports.length);
const api='http://127.0.0.1:'+proxyPort, tg='http://127.0.0.1:'+tgPort;
Object.assign(env,{
  HEIMDALL_TELEGRAM_BOT_TOKEN:'TEST:FAKE',HEIMDALL_TELEGRAM_API_BASE:tg,
  HEIMDALL_BOT_TIMERS_JSON:JSON.stringify({read_ms:15000,idle_no_reply_ms:20000,bot_attempt_silence_ms:30000,bot_disconnect_grace_ms:5000}),
});
const fake=createFakeTelegram({token:'TEST:FAKE',botUsername:'ninjy_test_bot'});
const wa='http://127.0.0.1:'+waPort;
Object.assign(env, {HEIMDALL_WHATSAPP_ACCESS_TOKEN:'TEST-WA-TOKEN',HEIMDALL_WHATSAPP_APP_SECRET:'test-app-secret',HEIMDALL_WHATSAPP_VERIFY_TOKEN:'test-verify-token-0001',HEIMDALL_WHATSAPP_PHONE_NUMBER_ID:'100000000000001',HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID:'200000000000002',HEIMDALL_WHATSAPP_API_BASE:wa});
const fakeWA=createFakeWhatsApp({webhookUrl:'http://127.0.0.1:'+hubPort+'/api/v1/channels/whatsapp/webhook'});
const hubDir=path.join(state,'hubs/bots-wa-e2e');
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
async function step(n,name,fn) {
  log('STEP '+n+': '+name);
  await fn();
  fs.writeFileSync(path.join(root,'step-'+n+'.json'),JSON.stringify({telegram:await sent(),whatsapp:await waSent(),view:n>=1&&n<16?await request('/bots/me'):null},null,2));
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
const startBridge=()=>run('scripts/local-bridge.sh',['start','--name','bots-wa-e2e-a','--hub','bots-wa-e2e','--port',String(aPort),'--local-endpoint-port',String(aEp),'--auto-enroll','--isolated-home','--providers','git','--bin-dir',bin]);
async function placement(candidates) {
  const current=await request('/bots/me/placement');
  return request('/bots/me/placement','PUT',{expected_revision:current.placement_revision,candidates});
}
const row=(provider,tier='preferred')=>({bridge_id:'*',provider,model:'*',tier});


async function waControl(route,body) {
  const res=await nativeFetch(wa+'/_control/'+route,{method:body===undefined?'GET':'POST',
    headers:{'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(40000)});
  assert.equal(res.status,200,'fake WhatsApp control '+route);
  return res.json();
}
const waSent=async()=> (await waControl('sent')).messages;
const waInject=(text,extra={})=>waControl('inject',{text,...extra});
const waText=async text=>poll(async()=> (await waSent()).find(m=>m.type==='text'&&m.text===text),'WhatsApp text '+text);
const view=()=>request('/bots/me');
const held=async()=> (await view()).whatsapp.held_replies;
const templates=async()=> (await waSent()).filter(m=>m.type==='template');
async function pairWA() {
  const pairing=await request('/bots/me/channels/whatsapp/pairing','POST',{},201);
  assert.ok(pairing.pairing_url.startsWith('https://wa.me/15550100001?text=Connect%20Ninjy%20'));
  assert.equal((await waInject(pairing.pairing_text)).status,200);
  await poll(async()=> (await view()).whatsapp.binding?.state==='active','active WhatsApp binding');
  await waText(copies.COPY_WA_PAIRED);
}
try {
  if(!process.env.BOTS_E2E_BIN_DIR) {
    const attrs=['hub','bridge','ctl','pty-host','dev-proxy'];
    const built=(await run('nix',['build',...attrs.map(a=>'.#ham-'+a),'--no-link','--print-out-paths'])).trim().split('\n');
    assert.equal(built.length,attrs.length);
    for(let i=0;i<attrs.length;i++) fs.symlinkSync(path.join(built[i],'bin','ham-'+attrs[i]),path.join(bin,'ham-'+attrs[i]));
  }
  await new Promise(r=>fake.listen(tgPort,'127.0.0.1',r));
  await new Promise(r=>fakeWA.listen(waPort,'127.0.0.1',r));
  await run('scripts/local-hub.sh',['start','--name','bots-wa-e2e','--hub-port',String(hubPort),
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
  await step(0,'experiment off rejects challenge and injection',async()=>{
    assert.equal((await waControl('challenge',{})).status,404);
    assert.equal((await waInject('hi')).status,404);
    assert.ok(hubLog().includes('bots: whatsapp configured'),'A7: inherited WhatsApp environment');
    assert.ok(!hubLog().includes('bots: whatsapp intake started'));
  });
  await startBridge();
  const {providerProfilesApi}=await import('../../src/ui/components/providers/providerProfiles.ts');
  for(const id of ['pi','bots-good']) {
    await providerProfilesApi.operate(bridgeId('bots-wa-e2e-a'),id,'upsert',{
      provider:'pi',label_enc:'',accent:'',enabled:true,environment:[],config:{binary_path:path.join(repo,'tools/mock_agent/bot-agent.sh')}});
    await request('/bridges/'+bridgeId('bots-wa-e2e-a')+'/providers/discover','POST',{stage:'providers',profile_id:id});
  }
  await step(1,'enable experiment and create configured bot',async()=>{
    await request('/me/experiments/bots','PUT',{enabled:true});
    await request('/bots/me','POST',{},201);
    await placement([row('pi')]);
    const configured=await poll(async()=>{const v=await view();return v.whatsapp.phone_display&&v;},'display phone');
    assert.equal(configured.whatsapp.configured,true);
    assert.equal(configured.whatsapp.phone_display,'+15550100001');
    assert.ok(hubLog().includes('bots: whatsapp intake started'));
  });
  await step(2,'verification challenge accepts only configured token',async()=>{
    const good=await waControl('challenge',{});
    assert.equal(good.status,200); assert.equal(good.body,'1158201444');
    assert.match(good.content_type,/^text\/plain/);
    assert.equal((await waControl('challenge',{verify_token:'wrong'})).status,403);
  });
  await step(3,'invalid signatures are rate limited',async()=>{
    // Fixed windows use the hub's monotonic clock, whose phase is unknown.
    // Normally request 21 is throttled. If a window rolls over during the
    // burst, continue within that new window (at most 20 more requests).
    const started=performance.now();
    let throttled=false;
    for(let i=0;i<41;i++) {
      const {status}=await waControl('post',{body:'{}',signature:'sha256='+'0'.repeat(64)});
      if(i<20) assert.equal(status,401);
      else if(status===429) { throttled=true; break; }
      else assert.equal(status,401);
    }
    assert.ok(throttled,'bad-signature budget exhausted within two windows');
    assert.ok(performance.now()-started<60000,'signature burst must fit in 60 seconds');
    // A full interval crosses a boundary regardless of its phase and clears
    // the per-IP budget before the signed pairing POST.
    await sleep(60100);
  });
  await step(4,'pair WhatsApp using a single-use link',pairWA);
  let hi;
  await step(5,'message echoes, marks read and reacts using pinned version',async()=>{
    hi=await waInject('hi'); assert.equal(hi.status,200);
    await waText('echo: hi');
    await poll(async()=> (await waControl('reads')).reads.some(r=>r.message_id===hi.id),'read receipt');
    await poll(async()=> (await waSent()).some(m=>m.reaction==='👀'&&m.reaction_message_id===hi.id),'read reaction');
    assert.deepEqual((await waControl('versions')).versions,['v27.0']);
  });
  await step('5q','busy WhatsApp message gets queued then read reaction',async()=>{
    const hold=await waInject('queued reaction hold');
    await poll(async()=> (await waSent()).some(m=>m.reaction==='👀'&&m.reaction_message_id===hold.id),'hold message read');
    const queued=await waInject('queued after hold');
    await poll(async()=> (await waSent()).some(m=>m.reaction==='⏳'&&m.reaction_message_id===queued.id),'queued reaction');
    await waText('echo: queued after hold');
    const emojis=(await waSent()).filter(m=>m.reaction_message_id===queued.id).map(m=>m.reaction);
    assert.deepEqual(emojis,['⏳','👀']);
  });
  await step(6,'replayed webhook creates one message and one echo',async()=>{
    assert.equal((await waControl('replay',{id:hi.id})).status,200);
    // Intake can idle for five seconds; check both persistence and echo count
    // only after a complete intake interval has elapsed.
    await sleep(6000);
    const rows=await sql("SELECT provider_update_key FROM channel_messages WHERE binding_id IN (SELECT binding_id FROM channel_bindings WHERE provider='whatsapp') AND direction='inbound' AND provider_update_key LIKE ?",['%'+hi.id]);
    assert.equal(rows.length,1);
    assert.equal((await waSent()).filter(m=>m.text==='echo: hi').length,1);
  });
  await step(7,'Telegram and WhatsApp replies stay on their origin channel',async()=>{
    const pairing=await request('/bots/me/channels/telegram/pairing','POST',{},201);
    await inject('/start '+new URL(pairing.pairing_url).searchParams.get('start'));
    await expectSent(copies.COPY_PAIRED);
    await inject('tg?'); await expectSent('echo: tg?');
    await waInject('wa?'); await waText('echo: wa?');
    assert.ok(!(await waSent()).some(m=>m.text==='echo: tg?'));
    assert.ok(!(await sent()).some(m=>m.text==='echo: wa?'));
  });
  await step(8,'sync closed window retains reply and reports unavailable template',async()=>{
    await waControl('templates',{approved:[]}); await waControl('window-mode',{mode:'sync'});
    await waControl('window',{to:'15551230001',open:false});
    await waInject('late?');
    await poll(async()=> (await held()).some(m=>m.body==='echo: late?'),'held reply');
    await poll(async()=> (await view()).whatsapp.reengage_error==='template_unavailable','unavailable template');
    assert.ok(!(await waSent()).some(m=>m.text==='echo: late?'));
    assert.deepEqual(await sql("SELECT send_state FROM channel_messages WHERE binding_id IN (SELECT binding_id FROM channel_bindings WHERE provider='whatsapp') AND body='echo: late?'"),[{send_state:'held'}]);
  });
  await step(9,'approved template is sent once while replies remain held',async()=>{
    await waControl('templates',{approved:['ninjy_reply_waiting']});
    await waInject('late2?');
    await poll(async()=> (await held()).length===2,'two held replies');
    await poll(async()=> (await view()).whatsapp.reengage_sent,'template sent flag');
    assert.equal((await templates()).length,1);
    assert.equal((await templates())[0].template.name,'ninjy_reply_waiting');
    assert.ok((await held()).some(m=>m.body==='echo: late?'));
  });
  await step(10,'new inbound releases held replies in order',async()=>{
    await waControl('window',{to:'15551230001',open:true});
    await waInject('here'); await waText('echo: here');
    assert.deepEqual((await waSent()).filter(m=>['echo: late?','echo: late2?','echo: here'].includes(m.text)).map(m=>m.text),['echo: late?','echo: late2?','echo: here']);
    assert.deepEqual(await held(),[]);
  });
  await step(11,'async closed window status retains accepted reply',async()=>{
    await waControl('window-mode',{mode:'async'}); await waControl('window',{to:'15551230001',open:false});
    await waInject('async?');
    await poll(async()=> (await held()).some(m=>m.body==='echo: async?'),'async held reply');
    assert.deepEqual(await sql("SELECT send_state FROM channel_messages WHERE binding_id IN (SELECT binding_id FROM channel_bindings WHERE provider='whatsapp') AND body='echo: async?'"),[{send_state:'held'}]);
    await poll(async()=> (await templates()).length===2,'second reengagement template');
  });
  await step(12,'async held reply is released before new reply',async()=>{
    const start=(await waSent()).length;
    await waControl('window',{to:'15551230001',open:true}); await waInject('back'); await waText('echo: back');
    assert.deepEqual((await waSent()).slice(start).filter(m=>m.type==='text').map(m=>m.text),['echo: async?','echo: back']);
    assert.deepEqual(await held(),[]);
  });
  await step(13,'unsupported image receives text-only copy',async()=>{
    await waInject('',{type:'image'}); await waText(copies.COPY_UNSUPPORTED);
  });
  await step(14,'Settings shows connected name, confirms disconnect and renders QR',async()=>{
    const {default:puppeteer}=await import(process.env.BOTS_E2E_PUPPETEER || 'puppeteer');
    browser=await puppeteer.launch({headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
    const page=await browser.newPage(); await page.setViewport({width:1440,height:1000});
    await page.setCookie({name:'__Host-heimdall_session',value:headers.Cookie.split('=').slice(1).join('='),domain:'127.0.0.1',path:'/',secure:true,httpOnly:true,sameSite:'Lax'});
    const ui='http://127.0.0.1:'+uiPort;
    await page.goto(ui+'/#/settings',{waitUntil:'networkidle2'});
    await poll(async()=>await page.$('[data-debug-id="device-waiting-code"],[data-debug-id="settings-nav-item-bots"]'),'browser enrollment or settings');
    if(await page.$('[data-debug-id="device-waiting-code"]')) {
      const code=await page.$eval('[data-debug-id="device-waiting-code"]',e=>e.textContent.trim());
      await approveDevice({api,key:path.join(hubDir,'approver/device.json'),code,label:'W7 isolated browser'});
      await page.waitForFunction(()=>!location.hash.includes('/device/'),{timeout:30000});
      await page.goto(ui+'/#/settings',{waitUntil:'networkidle2'});
    }
    const selector=id=>'[data-debug-id="'+id+'"]';
    await page.waitForSelector(selector('settings-nav-item-bots')); await page.click(selector('settings-nav-item-bots'));
    await page.waitForSelector(selector('settings-bots-whatsapp-card'));
    await poll(async()=> (await page.$eval(selector('settings-bots-whatsapp-card'),e=>e.textContent)).includes('Connected to Alice'),'connected name');
    await page.screenshot({path:path.join(root,'whatsapp-connected.png')});
    await page.click(selector('settings-bots-whatsapp-disconnect-btn'));
    await page.waitForSelector(selector('settings-bots-whatsapp-disconnect-dialog'));
    await page.click(selector('settings-bots-whatsapp-disconnect-cancel-btn'));
    assert.equal((await view()).whatsapp.binding.state,'active');
    await page.click(selector('settings-bots-whatsapp-disconnect-btn'));
    await page.click(selector('settings-bots-whatsapp-disconnect-confirm-btn'));
    await page.waitForSelector(selector('settings-bots-whatsapp-connect-btn'));
    await page.click(selector('settings-bots-whatsapp-connect-btn'));
    await page.waitForSelector(selector('settings-bots-whatsapp-qr'));
    assert.ok(await page.$eval(selector('settings-bots-whatsapp-qr'),e=>e.complete&&e.naturalWidth>0));
    await page.screenshot({path:path.join(root,'whatsapp-qr.png')});
  });
  await step(15,'chat disconnect preserves Telegram binding',async()=>{
    await pairWA(); await waInject('disconnect'); await waText(copies.COPY_DISCONNECTED);
    await poll(async()=> (await view()).whatsapp.binding?.state!=='active','disconnected binding');
    assert.equal((await view()).telegram.binding.state,'active');
    const count=(await waSent()).length; await waInject('hi');
    await poll(async()=> (await waSent()).slice(count).some(m=>m.text===copies.COPY_WA_NOT_CONNECTED),'not connected response');
  });
  await step(16,'disable stops intake and hides webhook',async()=>{
    await request('/me/experiments/bots','PUT',{enabled:false});
    assert.equal((await waControl('challenge',{})).status,404);
    assert.equal((await waInject('hi')).status,404);
    assert.ok(hubLog().includes('bots: whatsapp intake stopped'));
  });
  log('PASS: all 17 spec 21.2 steps');
} catch(error) {
  log('FAIL: '+(error.stack||error));
  if(browser) for(const [index,page] of (await browser.pages()).entries()) {
    try {await page.screenshot({path:path.join(root,'failure-'+index+'.png')});} catch {}
  }
  process.exitCode=1;
} finally {
  if(browser) await browser.close();
  globalThis.fetch=nativeFetch;
  for(const [script,name,extra] of [['local-bridge.sh','bots-wa-e2e-a',['--purge-home']],['local-hub.sh','bots-wa-e2e',[]]]) {
    try {await run('scripts/'+script,['stop','--name',name,...extra]);}
    catch(error) {log('CLEANUP ERROR '+error.message);process.exitCode=1;}
  }
  for(const server of [fake,fakeWA]) {
    server.closeAllConnections();
    if(server.listening) await new Promise(r=>server.close(r));
  }
  if(app) app.keyringBytes.fill(0);
  log('Evidence retained at '+root);
}
