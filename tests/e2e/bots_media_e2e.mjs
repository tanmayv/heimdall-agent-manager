// Spec 19.2: isolated hub/bridge with fake WhatsApp and Telegram; no real credentials.
// Run inside nix develop: node tests/e2e/bots_media_e2e.mjs
// Requires npm ci, Python 3, and Puppeteer with an installed Chromium browser.
// BOTS_E2E_PUPPETEER may name an external Puppeteer module (default: puppeteer).
// BOTS_E2E_BIN_DIR may point at prebuilt binaries; otherwise Nix builds them.
// Logs/screenshots remain in BOTS_E2E_EVIDENCE_ROOT (default: /var/tmp).
import {createHash} from 'node:crypto';
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
const root=fs.mkdtempSync(path.join(process.env.BOTS_E2E_EVIDENCE_ROOT || '/var/tmp','bots-media-e2e-'));
const hubName=path.basename(root).toLowerCase(), bridgeName=hubName+'-a';
const state=path.join(root,'state'), bin=process.env.BOTS_E2E_BIN_DIR || path.join(root,'bin');
fs.mkdirSync(bin,{recursive:true});
const logFile=path.join(root,'run.log');
const log=(s)=>{console.log(s);fs.appendFileSync(logFile,s+'\n');};
log('D7 evidence: '+root);
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
  HEIMDALL_BOT_TIMERS_JSON:JSON.stringify({read_ms:120000,idle_no_reply_ms:120000,bot_attempt_silence_ms:180000,bot_disconnect_grace_ms:5000}),
});
const fake=createFakeTelegram({token:'TEST:FAKE',botUsername:'ninjy_test_bot'});
let tgGetFiles=0;
fake.on('request',req=>{if(new URL(req.url,tg).pathname.endsWith('/getFile')) tgGetFiles++;});
const wa='http://127.0.0.1:'+waPort;
Object.assign(env, {HEIMDALL_WHATSAPP_ACCESS_TOKEN:'TEST-WA-TOKEN',HEIMDALL_WHATSAPP_APP_SECRET:'test-app-secret',HEIMDALL_WHATSAPP_VERIFY_TOKEN:'test-verify-token-0001',HEIMDALL_WHATSAPP_PHONE_NUMBER_ID:'100000000000001',HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID:'200000000000002',HEIMDALL_WHATSAPP_API_BASE:wa});
const fakeWA=createFakeWhatsApp({webhookUrl:'http://127.0.0.1:'+hubPort+'/api/v1/channels/whatsapp/webhook'});
const hubDir=path.join(state,'hubs',hubName);
const hubLog=()=>fs.readFileSync(path.join(hubDir,'logs/hub.log'),'utf8');
let headers, keyring, app;
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
  fs.writeFileSync(path.join(root,'step-'+n+'.json'),JSON.stringify({telegram:await sent(),whatsapp:await waSent(),view:n<16?await request('/bots/me'):null},null,2));
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
const startBridge=()=>run('scripts/local-bridge.sh',['start','--name',bridgeName,'--hub',hubName,'--port',String(aPort),'--local-endpoint-port',String(aEp),'--auto-enroll','--isolated-home','--providers','git','--bin-dir',bin]);
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
async function pairWA() {
  const pairing=await request('/bots/me/channels/whatsapp/pairing','POST',{},201);
  assert.ok(pairing.pairing_url.startsWith('https://wa.me/15550100001?text=Connect%20Ninjy%20'));
  assert.equal((await waInject(pairing.pairing_text)).status,200);
  await poll(async()=> (await view()).whatsapp.binding?.state==='active','active WhatsApp binding');
  await waText(copies.COPY_WA_PAIRED);
}

const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
function fixture(name,head,size=2048) {
  const bytes=Buffer.alloc(size,0x61); Buffer.from(head).copy(bytes);
  fs.mkdirSync(path.join(root,'fixtures'),{recursive:true});
  fs.writeFileSync(path.join(root,'fixtures',name),bytes); return bytes;
}
const jpeg=fixture('marker.jpg',Buffer.concat([Buffer.from([255,216,255,224]),Buffer.from('NINJY-MEDIA-MARKER-1')]));
const png=fixture('image.png',Buffer.from([137,80,78,71,13,10,26,10]));
const pdf=fixture('invoice.pdf','%PDF-1.4'), ogg=fixture('voice.ogg','OggS');
const mp4=fixture('video.mp4',Buffer.from([0,0,0,24,102,116,121,112,109,112,52,50]));
const large=fixture('large.pdf','%PDF-1.4',10000000);
fixture('archive.zip',Buffer.from([80,75,3,4]));
const tgMedia=(type,bytes,extra={},sender={})=>control('inject',{chat_id:111,from_id:222,...sender,media:{type,bytes_base64:bytes.toString('base64'),...extra}});
const waMedia=(type,bytes,extra={})=>waInject('',{type,media:{bytes_base64:bytes.toString('base64'),...extra}});
const attachments=provider=>sql("SELECT a.*,m.body,m.send_state,m.provider_update_key FROM channel_attachments a JOIN channel_messages m USING(message_id) JOIN channel_bindings b ON b.binding_id=a.binding_id WHERE b.provider=? ORDER BY a.created_at,a.attachment_id",[provider]);
async function tgReply(method,bytes,caption) {
  return poll(async()=> (await sent()).find(m=>m.method===method&&m.sha256===digest(bytes)&&m.caption===caption),method+' '+caption);
}
async function noInbound(provider,fn) {
  const query="SELECT count(*) AS n FROM channel_messages m JOIN channel_bindings b USING(binding_id) WHERE b.provider=? AND m.direction='inbound'";
  const before=await sql(query,[provider]); await fn();
  await sleep(6000); assert.deepEqual(await sql(query,[provider]),before);
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
  await run('scripts/local-hub.sh',['start','--name',hubName,'--hub-port',String(hubPort),
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

  await step(0,'setup and pair both providers',async()=>{
    await startBridge();
    const {providerProfilesApi}=await import('../../src/ui/components/providers/providerProfiles.ts');
    for(const id of ['pi','bots-good']) {
      await providerProfilesApi.operate(bridgeId(bridgeName),id,'upsert',{
        provider:'pi',label_enc:'',accent:'',enabled:true,
        environment:[{name:'BOT_AGENT_MODE',value:'media',sensitive:false}],
        config:{binary_path:path.join(repo,'tools/mock_agent/bot-agent.sh')}});
      await request('/bridges/'+bridgeId(bridgeName)+'/providers/discover','POST',{stage:'providers',profile_id:id});
    }
    await request('/me/experiments/bots','PUT',{enabled:true});
    await request('/bots/me','POST',{},201); await placement([row('pi')]);
    const pairing=await request('/bots/me/channels/telegram/pairing','POST',{},201);
    await inject('/start '+new URL(pairing.pairing_url).searchParams.get('start'));
    await expectSent(copies.COPY_PAIRED); await pairWA();
    const v=await view(); assert.equal(v.telegram.binding.state,'active'); assert.equal(v.whatsapp.binding.state,'active');
  });
  await step(1,'Telegram photo stored encrypted and relayed natively',async()=>{
    await tgMedia('photo',jpeg); await tgReply('sendPhoto',jpeg,'got image');
    const rows=await attachments('telegram');
    const inbound=rows.filter(a=>a.direction==='inbound'); assert.equal(inbound.length,1);
    assert.equal(inbound[0].state,'stored'); assert.match(inbound[0].artifact_id,/^art_/);
    assert.equal(rows.filter(a=>a.direction==='outbound'&&a.state==='native').length,1);
    const content=await sql('SELECT content FROM artifacts WHERE artifact_id=?',[inbound[0].artifact_id]);
    assert.match(content[0].content,/^vault:v2:/);
    for(const file of [path.join(hubDir,'hub.db'),path.join(hubDir,'hub.db-wal')]) {
      assert.ok(fs.existsSync(file),'database evidence exists: '+file);
      assert.equal(fs.readFileSync(file).includes(Buffer.from('NINJY-MEDIA-MARKER-1')),false);
      const result=await run('sh',['-c','grep -a -c NINJY-MEDIA-MARKER-1 "$1"; test "$?" -eq 1','marker-check',file]);
      assert.equal(result.trim(),'0'); log('marker count '+file+': 0');
    }
  });
  await step(2,'Telegram document preserves filename and caption',async()=>{
    await tgMedia('document',pdf,{file_name:'invoice.pdf',mime_type:'application/pdf',caption:'please read'});
    assert.equal((await tgReply('sendDocument',pdf,'got document')).filename,'invoice.pdf');
  });
  await step(3,'Telegram voice',async()=>{await tgMedia('voice',ogg,{mime_type:'audio/ogg'});await tgReply('sendVoice',ogg,'got voice');});
  await step(4,'Telegram video maps to document',async()=>{
    await tgMedia('video',mp4,{mime_type:'video/mp4'}); await tgReply('sendDocument',mp4,'got document');
    assert.ok((await attachments('telegram')).some(a=>a.direction==='inbound'&&a.mime==='video/mp4'&&a.kind==='document'));
  });
  await step(5,'Telegram 10000000 byte relay',async()=>{
    await tgMedia('document',large,{file_name:'large.pdf',mime_type:'application/pdf'});
    assert.equal((await tgReply('sendDocument',large,'got document')).size,10000000);
  });
  await step(6,'Telegram sticker produces notice only',async()=>{
    await noInbound('telegram',async()=>{await tgMedia('sticker',png);await expectSent(copies.COPY_UNSUPPORTED);});
  });
  await step(7,'Telegram declared oversized file skips getFile',async()=>{
    const before=tgGetFiles;
    await noInbound('telegram',async()=>{
      await tgMedia('document',pdf,{declare_size:16777216,mime_type:'application/pdf'});
      await expectSent(copies.COPY_MEDIA_TOO_LARGE);
    });
    assert.equal(tgGetFiles,before);
  });
  await step(8,'Telegram other sender ignored',async()=>{
    const count=(await sent()).length;
    await noInbound('telegram',()=>tgMedia('photo',jpeg,{}, {from_id:333}));
    assert.equal((await sent()).length,count);
  });
  await step(9,'WhatsApp image uploaded and relayed',async()=>{
    await waMedia('image',png,{mime_type:'image/png'});
    await poll(async()=> (await waSent()).some(m=>m.type==='image'&&m.caption==='got image'&&m.sha256===digest(png)),'WhatsApp image');
    assert.ok((await waControl('uploads')).uploads.some(u=>u.sha256===digest(png)));
  });
  await step(10,'WhatsApp voice and separate caption',async()=>{
    const start=(await waSent()).length;
    await waMedia('audio',ogg,{mime_type:'audio/ogg',voice:true}); await waText('got voice');
    const messages=(await waSent()).slice(start);
    const voice=messages.findIndex(m=>m.type==='audio'&&m.voice===true&&m.sha256===digest(ogg));
    assert.ok(voice>=0); assert.ok(!messages[voice].caption);
    assert.ok(messages.findIndex(m=>m.text==='got voice')>voice);
  });
  await step(11,'WhatsApp video falls back to artifact link',async()=>{
    await waMedia('video',mp4,{mime_type:'video/mp4'});
    await poll(async()=> (await waSent()).some(m=>m.type==='text'&&m.text.includes('got document')&&/\/library\/artifacts\/art_|find artifact art_/.test(m.text)),'video link');
    const rows=await attachments('whatsapp');
    assert.ok(rows.some(a=>a.direction==='inbound'&&a.mime==='video/mp4'&&a.kind==='document'));
    assert.ok(rows.some(a=>a.direction==='outbound'&&a.state==='link'));
  });
  await step(12,'WhatsApp expired media keeps caption',async()=>{
    await waMedia('document',pdf,{mime_type:'application/pdf',expired:true,caption:'lost'});await waText('echo: lost');
    assert.ok((await attachments('whatsapp')).some(a=>a.body==='lost'&&a.state==='unavailable'));
  });
  await step(13,'WhatsApp oversized media notices exactly once',async()=>{
    const start=(await waSent()).length;
    await waMedia('document',pdf,{mime_type:'application/pdf',declare_size:16777216,caption:'big'});await waText('echo: big');
    assert.ok((await attachments('whatsapp')).some(a=>a.body==='big'&&a.state==='too_large'));
    assert.equal((await waSent()).slice(start).filter(m=>m.text===copies.COPY_MEDIA_TOO_LARGE).length,1);
  });
  await step(14,'WhatsApp held link releases before new reply',async()=>{
    await waControl('window',{to:'15551230001',open:false});
    // A fresh inbound opens the Hub window; the fake rejects only after upload.
    const sentBefore=(await waSent()).length;
    await waMedia('image',png,{mime_type:'image/png',caption:'late'});
    const heldRow=await poll(async()=> (await held()).find(m=>/art_/.test(m.body)),'held media link');
    assert.ok(!(await waSent()).slice(sentBefore).some(m=>['image','document','audio','video'].includes(m.type)));
    const rows=await sql("SELECT send_state,body FROM channel_messages WHERE message_id=?",[heldRow.message_id]);
    assert.equal(rows[0].send_state,'held'); assert.match(rows[0].body,/art_/);
    const start=(await waSent()).length;
    await waControl('window',{to:'15551230001',open:true});await waInject('here');await waText('echo: here');
    const text=(await waSent()).slice(start).filter(m=>m.type==='text').map(m=>m.text);
    assert.ok(text.indexOf(heldRow.body)>=0);assert.ok(text.indexOf(heldRow.body)<text.indexOf('echo: here'));
  });
  await step(15,'Telegram history includes native artifact metadata',async()=>{
    const start=(await sent()).length;
    // Global history includes both providers; cover the run (coordinator clarification).
    await inject('ctl channel history --limit 100');
    await poll(async()=> (await sent()).slice(start).some(m=>m.text?.includes('"sent_as":"native"')&&m.text.includes('"artifact_id":"art_')),'history metadata');
  });
  await step(16,'unchanged Telegram and WhatsApp regression suites',async()=>{
    for(const script of ['bots_slice1_e2e.mjs','bots_whatsapp_e2e.mjs']) {
      await run('nix',['develop','-c','node','tests/e2e/'+script],{env:{...env,BOTS_E2E_BIN_DIR:bin}});
    }
  });
  log('PASS: all 17 spec 19.2 steps');
} catch(error) {
  log('FAIL: '+(error.stack||error));process.exitCode=1;
} finally {
  globalThis.fetch=nativeFetch;
  for(const [script,name,extra] of [['local-bridge.sh',bridgeName,['--purge-home']],['local-hub.sh',hubName,[]]]) {
    try {await run('scripts/'+script,['stop','--name',name,...extra]);}
    catch(error) {log('CLEANUP ERROR '+error.message);process.exitCode=1;}
  }
  for(const server of [fake,fakeWA]) {
    server.closeAllConnections();if(server.listening) await new Promise(r=>server.close(r));
  }
  if(app) app.keyringBytes.fill(0);
  log('Evidence retained at '+root);
}
