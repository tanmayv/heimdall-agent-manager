// Opt-in, authenticated smoke against a named local Hub/Bridge; never production.
// See docs/codex-app-server-smoke.md for setup and commands.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { hubLogin, sessionHeaders } from './hubOidc.mjs';
import { openSeedApprover } from '../../scripts/local-runtime/approver.mjs';
import { encryptPtyPayload, setPtyBridgeBootId, encodePtyViewerFrame, PTY_WIRE_KIND_INPUT, PTY_WIRE_FLAG_ENCRYPTED } from '../../src/ui/components/shells/ptyWire.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { encryptVaultText, decryptVaultText } from '../../src/ui/utils/vaultContent.ts';
const require = createRequire(import.meta.url);
const WebSocket = require('ws');
const base = process.env.CODEX_SMOKE_API || 'http://127.0.0.1:18880';
if (!['127.0.0.1', 'localhost'].includes(new URL(base).hostname)) throw new Error('Local isolated hub required');
const stateDir = process.env.CODEX_SMOKE_STATE || path.join(process.env.HOME, '.local/state/heimdall-local');
const root = path.resolve(process.env.CODEX_SMOKE_EVIDENCE || '.heimdall/t4-evidence');
fs.mkdirSync(root, {recursive:true, mode:0o700});
const stateFile = path.join(root, 'state.json');
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : {};
const cookie = await hubLogin(base, 'tanmay');
const headers = { ...sessionHeaders(cookie, 'http://127.0.0.1:15873'), 'Content-Type':'application/json' };
const approver = await openSeedApprover({api:base, key:path.join(stateDir,'hubs/t4-codex/approver/device.json'), user:'tanmay'});
const keyring = await importKeyring(approver.keyringBytes); approver.keyringBytes.fill(0);
async function api(method, route, body) {
  const r = await fetch(base+'/api/v1'+route, {method, headers, body:body===undefined?undefined:JSON.stringify(body)});
  const text = await r.text();
  if(!r.ok) throw new Error(method+' '+route+' '+r.status+': '+text);
  return JSON.parse(text).data;
}
async function open(value) {
  if (typeof value === 'string' && value.startsWith('vault:v2:')) return decryptVaultText(value,keyring);
  if(Array.isArray(value)) return Promise.all(value.map(open));
  if(value && typeof value==='object') return Object.fromEntries(await Promise.all(Object.entries(value).map(async ([k,v])=>[k,await open(v)])));
  return value;
}
function record(name, value) { fs.writeFileSync(path.join(root,name+'.json'),JSON.stringify(value,null,2)+'\n',{mode:0o600}); return value; }
const delay = ms=>new Promise(r=>setTimeout(r,ms));
const [mode='status', ...args] = process.argv.slice(2);
const selection = process.env.CODEX_SMOKE_INSTANCE || 'yolo';
if (!['yolo','ask'].includes(selection)) throw new Error('CODEX_SMOKE_INSTANCE must be yolo or ask');
if (!['setup','status','prompt','resolve','reconfigure','journal','interrupt','start','stop'].includes(mode)) throw new Error('Unknown smoke mode: '+mode);
const instance = ()=> {
  if (!state[selection]) throw new Error('Run setup first');
  return state[selection];
};
const route = ()=>'/agent-instances/'+instance();
async function status() {
  const inst = await api('GET',route());
  const chat = await api('GET','/chats/by-instance/'+instance());
  const messages = await open(await api('GET','/chats/'+chat.conversation_id+'/messages?limit=100'));
  const blockers = await open(await api('GET',route()+'/blockers'));
  record(instance()+'-transcript',messages);
  const summary={instance:inst.agent_instance_id,runtime_status:inst.runtime_status,activity_status:inst.activity_status,runtime_transport:inst.runtime_transport,model:inst.model,launch_epoch:inst.launch_epoch,blockers,messages:messages.slice(0,8).map(m=>({message_id:m.message_id,direction:m.direction,body:m.body,message_status:m.message_status,metadata:m.metadata}))};
  record(instance()+'-status',summary); console.log(JSON.stringify(summary,null,2)); return summary;
}
if(mode==='setup') {
  const bridges=await api('GET','/bridges');
  state.bridge=bridges.find(b=>b.label==='local-t4-codex')?.bridge_id;
  if (!state.bridge) throw new Error('Expected isolated local-t4-codex bridge');
  // Back-to-back creation intentionally reproduces the concurrent-admission issue.
  await api('POST','/bridges/'+state.bridge+'/providers/discover',{});
  const providers=await api('GET','/bridges/'+state.bridge+'/provider-status');
  record('provider-status',providers);
  await api('POST','/bridges/'+state.bridge+'/providers/codex/acp-adapter',{action:'install'});
  await delay(3000);
  await api('PUT','/bridges/'+state.bridge+'/providers/codex',{enabled:true,transport:'acp'});
  for(const permission_mode of ['yolo','ask']) {
    if(state[permission_mode]) continue;
    const agent=await api('POST','/agents',{name:'T4 Codex '+permission_mode,slug:'t4-codex-'+permission_mode,permission_mode,instructions:'Isolated Codex protocol smoke fixture. Keep replies below 10 words. Do not inspect files or run tools unless the user requests them. Reply READY to startup. Follow the smoke prompts exactly.'});
    const inst=await api('POST','/agent-instances',{agent_id:agent.agent_id,bridge_id:state.bridge,provider:'codex',model:'gpt-6.1-sol'});
    state[permission_mode]=inst.agent_instance_id;
    record('state',state);
    console.log(permission_mode, inst.agent_instance_id);
  }
} else if(mode==='prompt') {
  const chat=await api('GET','/chats/by-instance/'+instance());
  const ticket=await api('POST','/me/ws-ticket',{});
  const ws=new WebSocket('ws://127.0.0.1:18881/api/v1/user-ws?ticket='+encodeURIComponent(ticket.ticket),{headers:{Origin:'http://127.0.0.1:15873'}});
  const pending=[];
  ws.on('message',bytes=>{try{const v=JSON.parse(bytes); pending.push(open(v).then(o=>fs.appendFileSync(path.join(root,instance()+'-events.jsonl'),JSON.stringify({received_at:new Date().toISOString(),event:o})+'\n')));}catch{}});
  await new Promise((r,j)=>{ws.once('open',r);ws.once('error',j)});
  if (!args.length) throw new Error('prompt requires text');
  const sent=await api('POST','/chats/'+chat.conversation_id+'/messages',{body:await encryptVaultText(args.join(' '),keyring)});
  console.log('sent',sent.message_id);
  await delay(Number(process.env.CODEX_SMOKE_WAIT_MS || 20000));
  ws.close(); await Promise.all(pending); await status();
} else if(mode==='resolve') {
  console.log(await api('POST',route()+'/blockers/'+args[0]+'/resolve',{decision:args[1],message:'T4 '+args[1]+' once'}));
} else if(mode==='reconfigure') {
  const inst=await api('GET',route());
  console.log(await api('POST',route()+'/reconfigurations',{bridge_id:state.bridge,project_id:inst.project_id||'',provider:'codex',model:args[0],expected_revision:inst.configuration_revision,idempotency_key:randomUUID()}));
} else if(mode==='journal') {
  const inst=await api('GET',route());
  const p=path.join(stateDir,'bridges/t4-codex/data/bridge/acp',instance(),inst.launch_epoch,'state.json');
  const header=JSON.parse(fs.readFileSync(p,'utf8'));
  const v=JSON.parse(await decryptVaultText(header.sealed_state,keyring));
  const selected={instance:v.instance,launch_epoch:v.launch_epoch,sessionId:v.sessionId,selected_model:v.selected_model,selected_mode:v.selected_mode,last_stdout_seq:v.last_stdout_seq,runtime:JSON.parse(v.runtime_json),pending_inbound:v.pending_inbound.map(x=>({method:x.method,blocker_id:x.blocker_id})),pending_outbound:v.pending_outbound.map(x=>({method:x.method}))};
  record(instance()+'-journal-summary',selected); console.log(JSON.stringify(selected,null,2));
} else if(mode==='interrupt') {
  await api('PUT','/me/experiments/streaming_terminal_pane',{enabled:true});
  const ticket=await api('POST','/me/ws-ticket',{});
  const ws=new WebSocket('ws://127.0.0.1:18881/api/v1'+route()+'/stream?ticket='+encodeURIComponent(ticket.ticket),{headers:{Origin:'http://127.0.0.1:15873'}});
  try {
    const ready=await new Promise((resolve,reject)=>{
      const timeout=setTimeout(()=>reject(new Error('stream ready timeout')),10000);
      ws.once('error',reject);
      ws.on('message',(bytes,binary)=>{if(binary)return; const v=JSON.parse(bytes); if(v.type==='ready'){clearTimeout(timeout);resolve(v)}});
    });
    setPtyBridgeBootId(instance(),ready.bridge_boot_id);
    const payload=await encryptPtyPayload(new Uint8Array([3]),keyring,instance());
    ws.send(encodePtyViewerFrame(PTY_WIRE_KIND_INPUT,PTY_WIRE_FLAG_ENCRYPTED,payload));
    record(instance()+'-interrupt',{sent_at:new Date().toISOString(),ready});
    await delay(2500); console.log('Ctrl-C sent through encrypted agent stream');
  } finally { ws.close(); }

} else if(mode==='start') {
  console.log(await api('POST',route()+'/start',{}));
} else if(mode==='stop') {
  console.log(await api('POST',route()+'/stop',{}));
} else { await status(); }
