// Real `ham-bridge enroll` against THROWAWAY hubs (ephemeral ports, temp DBs), with
// the approval done through the UI's own vault modules (the /device/add code path):
// one pairing code read from the bridge's stdout and typed once; key_mac check;
// signed vault approval; unseal v2 with chain proof + pair_mac to the enrolling
// process. Then the multi-bridge isolation rules on the real binary:
//   - the enrolled runtime starts with its config (bound to that hub);
//   - the same bridge started against another hub (--hub) refuses to start;
//   - a second instance on the same config refuses (instance lock);
//   - a second bridge enrolled against ANOTHER hub on the same machine (its own
//     config/token) works, and the first still starts afterwards.
// Hermetic: HOME/USERPROFILE/APPDATA point into a temp dir (macOS: the real home, see
// HOME below), every port is
// ephemeral. The Windows Credential Manager is real, but every item this run writes
// is scoped to a random-port 127.0.0.1 hub (keystore scope), and all of them are
// deleted at the end (cmdkey). Never touches a running dev hub/bridge.
//
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_BRIDGE_BIN=<ham-bridge> \
//   node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs

import { createHash, randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { hubLogin, sessionHeaders, startMockOidc } from './hubOidc.mjs';
import { refuseLegacyInstall, scrubHeimdallEnv } from './realHomeGuard.mjs';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { buildBridgeApproval, buildGenesis, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, pairApproveMac, pairHubOrigin } from '../../src/ui/utils/vaultPairing.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const USER = 'e2e-real-enroll';
const results = [];
class CheckFailed extends Error {}
const expect = (cond, msg) => { if (!cond) throw new CheckFailed(msg); console.log(`    ok - ${msg}`); };
async function step(name, fn) {
  console.log(`\n== ${name}`);
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS ${name}`); }
  catch (err) { results.push([name, 'FAIL']); console.log(`    not ok - ${err instanceof CheckFailed ? err.message : (err?.stack || err)}`); console.log(`FAIL ${name}`); }
}
const ownerIdForFixture = (prefix) => prefix + randomBytes(12).toString('hex');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
  });
}

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-real-enroll-'));
// macOS: Security resolves the default keychain from the real user's home. Under a
// temp HOME there is none, and SecKeychainAddGenericPassword(nil) blocks in
// makeLoginAuthUI -> AuthorizationCopyRights waiting for a login-keychain prompt
// no CI runner can show (seen with `sample`). Keep the real HOME there; every
// bridge path is passed explicitly and keychain items are named by this run's ids.
// With the real home, enroll's service fallbacks (HEIMDALL_BRIDGE_SERVICE_NAME, then the
// legacy fixed-name unit) resolve against the user's real install: scrub and refuse.
const REAL_HOME = process.platform === 'darwin';
const HOME = REAL_HOME ? os.homedir() : path.join(ROOT, 'home');
scrubHeimdallEnv();
if (REAL_HOME) refuseLegacyInstall(HOME);
fs.mkdirSync(HOME, { recursive: true });
const ENV = { ...process.env, PATH: ROOT + path.delimiter + process.env.PATH, HOME, USERPROFILE: HOME, APPDATA: path.join(HOME, 'AppData'), LOCALAPPDATA: path.join(HOME, 'Local'), XDG_CONFIG_HOME: path.join(HOME, '.config') };
if (process.env.HEIMDALL_E2E_PTY_BIN) ENV.HEIMDALL_HAM_PTY_HOST_BIN=process.env.HEIMDALL_E2E_PTY_BIN;
const children = [];
const CREATED = []; // bridge ids whose scoped credentials this run wrote

async function startHub(label) {
  const bin = process.env.HEIMDALL_E2E_HUB_BIN;
  if (!fs.existsSync(bin)) throw new Error('Hub binary must be visible in the current Nix environment');
  const migrations = path.join(REPO_ROOT, 'src', 'hub', 'repository', 'sqlite', 'migrations');
  const dir = path.join(ROOT, label);
  fs.mkdirSync(dir, { recursive: true });
  const port = await freePort();
  const log = fs.openSync(path.join(dir, 'hub.log'), 'w');
  // Users sign in only with OIDC: each hub gets its own mock provider.
  const mock = await startMockOidc();
  children.push({ kill: mock.stop });
  const base = `http://127.0.0.1:${port}`;
  const child = spawn(bin, ['--listen', `127.0.0.1:${port}`, '--db', path.join(dir, 'hub.db'), '--migrations-dir', migrations, '--ui-origin', base],
    { cwd: dir, env: { ...ENV, ...mock.hubEnv(base) }, stdio: ['ignore', log, log] });
  children.push(child);
  for (const deadline = Date.now() + 30_000; ;) {
    try { if ((await fetch(`${base}/api/v1/health`)).ok) break; } catch { /* starting */ }
    if (Date.now() > deadline) throw new Error(`${label} did not start`);
    await sleep(150);
  }
  return { base, port, session: await hubLogin(base, USER) };
}

async function http(hub, method, p, { body, headers = {} } = {}) {
  const h = { ...sessionHeaders(hub.session, hub.base), ...headers };
  const text = body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body));
  if (text !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${hub.base}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, raw };
}

// The approving browser of this hub's account (genesis), holding the keyring.
async function approverFor(hub) {
  const me = await http(hub, 'GET', '/api/v1/me');
  const userId = me.data.user_id;
  const identity = await createDeviceIdentity(memoryDeviceStore(), userId);
  const g = await http(hub, 'POST', '/api/v1/vault/directory/genesis', { body: await buildGenesis(identity, 'e2e approver') });
  if (g.status !== 201) throw new Error(`genesis ${g.status} ${g.raw}`);
  const signed = async (method, p, body = '') => signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, userId, method, p, body);
  const chain = async () => verifyDirectory((await http(hub, 'GET', '/api/v1/vault/directory')).data, userId, null);
  const self = await http(hub, 'GET', '/api/v1/vault/devices/self', { headers: await signed('GET', '/api/v1/vault/devices/self') });
  const parsed = await openVerifiedWrap(self.data.wrap, { userId, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chain() });
  const keyringBytes = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  return { userId, identity, chain, keyringBytes, wrap: self.data.wrap };
}

function bridgeArgs(cfg) {
  return ['--config', cfg.config, '--bridge-token-file', cfg.token, '--port', String(cfg.port), '--data-dir', cfg.data, '--local-run-dir', cfg.local];
}

async function newBridgeDirs(label) {
  const dir = path.join(ROOT, label);
  fs.mkdirSync(dir, { recursive: true });
  return { dir, config: path.join(dir, 'config.toml'), token: path.join(dir, 'bridge.token'), data: path.join(dir, 'data'), local: path.join(dir, 'local'), port: await freePort() };
}

// macOS diagnostics for a stalled child: `sample` prints every thread's stack, which
// names the blocking call (keychain, lock, socket) that the child's own output cannot.
function stackOf(child) {
  if (process.platform !== 'darwin' || child.exitCode !== null) return '';
  const r = spawnSync('sample', [String(child.pid), '3', '-mayDie'], { encoding: 'utf8', timeout: 30_000 });
  return `\n--- sample ${child.pid} ---\n${(r.stdout || '') + (r.stderr || '')}`;
}

// Runs `ham-bridge enroll`, reads the pairing code from its stdout, approves it like
// the /device/add page (typed once) and delivers the first unseal with the pair_mac.
async function enroll(hub, approver, cfg) {
  const bin = process.env.HEIMDALL_E2E_BRIDGE_BIN;
  let out = '';
  const child = spawn(bin, ['enroll', '--hub', hub.base, '--headless', ...bridgeArgs(cfg)], { cwd: cfg.dir, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  const exited = new Promise((r) => child.once('exit', (code) => r(code)));
  let code = null;
  for (const deadline = Date.now() + 30_000; !code; await sleep(100)) {
    code = (/^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m.exec(out) || [])[1] ?? null;
    if (Date.now() > deadline) throw new CheckFailed(`no pairing code printed:\n${out}`);
  }
  expect(!/code=/.test(out), `ham-bridge printed a pairing code and a code-free link (${code.slice(0, 4)}-…)`);
  // As the approval page does: fetch the public pair_salts, run the pairing stretch
  // per candidate with the hub origin the bridge DECLARED, resolve the matching lookup.
  const salts = await http(hub, 'POST', '/api/v1/device/pair-salts', { body: {} });
  const tried = [];
  for (const c of (salts.data?.candidates ?? []).filter((x) => x.kind === 'bridge')) {
    expect(c.pair_hub_origin === pairHubOrigin(hub.base), `the bridge declares the hub origin it enrolled against (${c.pair_hub_origin})`);
    tried.push({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: c.pair_hub_origin, pairSalt: c.pair_salt }) });
  }
  const ver = await http(hub, 'POST', '/api/v1/device/verify', { body: { pair_lookups: tried.map((c) => c.keys.lookup) } });
  const keys = tried.find((c) => c.salt === ver.data?.pair_salt)?.keys;
  expect(ver.status === 200 && ver.data.kind === 'bridge' && keys, `the typed code resolves the bridge (${ver.status})`);
  await checkBridgeCodeInfo(ver.data, keys);
  const chain = await approver.chain();
  const { vault_approval, statement } = await buildBridgeApproval(approver.identity, chain, ver.data, cfg.dir.split(/[\\/]/).pop());
  const appr = await http(hub, 'POST', '/api/v1/device/approve', { body: { pair_lookup: keys.lookup, approve: true, vault_approval, new_bridge_label: 'real-enroll' } });
  const bridgeId = appr.data?.hub_observed?.bridge_id;
  expect(appr.status === 200 && bridgeId, `approved -> ${bridgeId}`);
  CREATED.push(bridgeId);
  // Wait for the enrolling process's enroll-only connection (it serves the unseal).
  let target = null;
  for (const deadline = Date.now() + 30_000; ; await sleep(250)) {
    const pk = await http(hub, 'GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`);
    if (pk.status === 200 && pk.data?.unseal_key_signature) { target = bridgeUnsealTargetFromRecord(bridgeId, pk.data); break; }
    if (Date.now() > deadline) throw new CheckFailed(`the enrolling bridge never connected:\n${out}${stackOf(child)}`);
  }
  const after = await approver.chain();
  const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
  await deliverKeyringToBridge(bridgeId, after, {
    fetchTarget: async () => target,
    dispatch: async (id, payload) => {
      const r = await http(hub, 'POST', `/api/v1/bridges/${id}/unseal`, { body: payload });
      if (r.status !== 200 || r.data?.ok === false) throw new Error(`unseal refused: ${r.status} ${r.raw}`);
      return r.data;
    },
    withKeyringBytes: async (fn) => { const b = Uint8Array.from(approver.keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
  }, { enrollment: true, expectedPublicKey: target.publicKey, extra: { enrollment: true, expected_public_key: target.publicKey, pair_mac: pairMac } });
  const exitCode = await Promise.race([exited, sleep(30_000).then(() => 'timeout')]);
  expect(/bridge enroll SUCCESS/.test(out) && exitCode === 0, `ham-bridge enroll reports SUCCESS and exits 0 (exit ${exitCode})`);
  if (process.platform === 'win32') expect(/start the bridge with:/.test(out), 'with no service to restart (Windows) enroll prints the command that starts the bridge');
  expect(fs.existsSync(cfg.config) && fs.readFileSync(cfg.config, 'utf8').includes(hub.base), 'the written config points the runtime at exactly that hub');
  return { bridgeId, out };
}

// Starts the runtime; resolves with { refused, out } once it either exits or connects.
async function runtime(cfg, extra = [], waitConnected = null) {
  const bin = process.env.HEIMDALL_E2E_BRIDGE_BIN;
  let out = '';
  const child = spawn(bin, [...bridgeArgs(cfg), ...extra], { cwd: cfg.dir, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  let exitCode = null;
  child.once('exit', (c) => { exitCode = c; });
  for (const deadline = Date.now() + 20_000; ; await sleep(200)) {
    if (exitCode !== null) return { refused: true, exitCode, out, child };
    if (waitConnected && await waitConnected()) return { refused: false, out, child };
    if (!waitConnected && /ham-bridge listening/.test(out)) return { refused: false, out, child };
    if (Date.now() > deadline) return { refused: false, timeout: true, out, child };
  }
}

const online = (hub, bridgeId) => async () => {
  const r = await http(hub, 'GET', '/api/v1/bridges');
  const list = Array.isArray(r.data) ? r.data : (r.data?.bridges ?? []);
  return list.some((b) => b.bridge_id === bridgeId && (b.status === 'online' || b.connected === true));
};

async function main() {
  if (!process.env.HEIMDALL_E2E_HUB_BIN || !process.env.HEIMDALL_E2E_BRIDGE_BIN) throw new Error('set HEIMDALL_E2E_HUB_BIN and HEIMDALL_E2E_BRIDGE_BIN');
  const hubA = await startHub('hub-a');
  const hubB = await startHub('hub-b');
  console.log(`throwaway hubs ${hubA.base} ${hubB.base}; temp root ${ROOT}`);
  const S = {};
  await step('1 real enroll against hub A: one pairing code, first unseal with pair_mac', async () => {
    S.apA = await approverFor(hubA);
    S.cfgA = await newBridgeDirs('bridge-a');
    S.a = await enroll(hubA, S.apA, S.cfgA);
  });
  if (process.env.HEIMDALL_E2E_OWNER_LEASE === '1') {
    const fixture = path.join(ROOT, 'owner-lease-provider');
    fs.writeFileSync(fixture, '#!/usr/bin/env python3\n' +
      'import os,sys,json,subprocess,time\n' +
      "if '--version' in sys.argv: print('codex-cli 0.162.0');sys.exit()\n" +
      "if 'plugin' in sys.argv: print('{\"installed\":[],\"available\":[]}');sys.exit()\n" +
      'i=os.environ.get("HEIMDALL_AGENT_INSTANCE_ID","unknown")\n' +
      'p=' + JSON.stringify(ROOT) + '+"/"+i+".env.json"\n' +
      'open(p,"w").write(json.dumps({k:v for k,v in os.environ.items() if k.startswith("HEIMDALL_")}))\n' +
      'subprocess.run([' + JSON.stringify(process.env.HEIMDALL_E2E_CTL_BIN) + ',"start-success"])\n' +
      'print("Owner lease synthetic child ready",flush=True)\n' +
      'while True: time.sleep(1)\n', { mode: 0o700 });
    const configured = spawnSync('python3', ['-c', `import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("update provider_catalog set binary='owner-lease-provider',base_args='[]',yolo_args='[]',ask_args='[]',extension='{}' where provider='codex'")
c.execute("update provider_catalog_meta set catalog_etag='owner-lease-synthetic'")
c.commit()
`, path.join(ROOT, 'hub-a', 'hub.db')], { encoding: 'utf8' });
    if (configured.status !== 0) throw new Error(configured.stderr);
  }
  await step('2 the enrolled runtime starts bound to hub A and connects', async () => {
    const r = await runtime(S.cfgA, [], online(hubA, S.a.bridgeId));
    expect(!r.refused && !r.timeout, `runtime A is online on hub A (${r.refused ? 'refused: ' + r.out : 'ok'})`);
    S.runA = r.child;
    const second = await runtime({ ...S.cfgA, port: await freePort() });
    expect(second.refused && /another ham-bridge instance/i.test(second.out), 'a second instance on the same config refuses (instance lock)');
  });

  if (process.env.HEIMDALL_E2E_OWNER_LOCAL === '1') {
    await step('owner-local V1 real relay, persistence, retries and offline listing', async () => {
      const { ownerLocalFlow } = await import('./owner_local_flow.ts');
      const registrySaved = new Map();
      await ownerLocalFlow({
        hub: hubA, approver: S.apA, bridgeId: S.a.bridgeId, http, expect,
        otherAccount: async () => ({ ...hubA, session: await hubLogin(hubA.base, 'owner-local-other-account') }),
        cli: async (relay) => {
          const requestPath = path.join(ROOT, 'signed-request.json');
          fs.writeFileSync(requestPath, JSON.stringify(relay), { mode: 0o600 });
          const called = spawnSync(process.env.HEIMDALL_E2E_CTL_BIN, ['agent', 'task-chain', 'owner-local', 'relay', '--request-file', requestPath], {
            env: { ...ENV, HEIMDALL_BRIDGE_ENDPOINT: 'unix:' + path.join(S.cfgA.local, 'bridge.sock'), HEIMDALL_AGENT_TOKEN: S.localToken },
            encoding: 'utf8', timeout: 20000,
          });
          if (called.status !== 0) throw new Error('CLI failed: ' + called.stderr + called.stdout);
          const response = JSON.parse(called.stdout);
          return response.data?.data ?? response.data;
        },
        launchChild: process.env.HEIMDALL_E2E_OWNER_LEASE === '1' ? async (projectPath = '') => {
          const discovered = await http(hubA, 'POST', '/api/v1/bridges/' + S.a.bridgeId + '/providers/discover', {body:{}});
          expect(discovered.status === 200, 'synthetic provider discovered on disposable Bridge');
          const enabled = await http(hubA, 'PUT', '/api/v1/bridges/' + S.a.bridgeId + '/providers/codex', {body:{enabled:true}});
          expect(enabled.status === 200, 'synthetic provider enabled');
          const created = await http(hubA, 'POST', '/api/v1/agents', {body:{name:'Owner lease fixture',slug:ownerIdForFixture('owner-lease-'),instructions:'Disposable integration fixture'}});
          expect(created.status === 200 || created.status === 201, 'created disposable agent');
          const models = spawnSync('python3', ['-c', 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("select model_id from provider_models where provider=\'codex\' and state=\'active\' order by rank limit 1").fetchone()[0])', path.join(ROOT,'hub-a','hub.db')], {encoding:'utf8'});
          if (models.status !== 0) throw new Error(models.stderr);
          let projectId='';
          if (projectPath) {
            const project=await http(hubA,'POST','/api/v1/projects',{body:{name:'Owner-local disposable repository',slug:ownerIdForFixture('local-repo-'),default_path:projectPath,vcs_kind:'git'}});
            expect(project.status===200 || project.status===201,'created disposable project path binding');
            projectId=project.data.project_id;
          }
          const started = await http(hubA, 'POST', '/api/v1/agent-instances', {body:{project_id:projectId,agent_id:created.data.agent_id,bridge_id:S.a.bridgeId,provider:'codex',model:models.stdout.trim(),display_name:'Owner lease child'}});
          expect(started.status === 200 || started.status === 201, 'started actual synthetic PTY child');
          const iid=started.data.agent_instance_id;
          let socket=path.join(S.cfgA.local,'pty-host-'+S.a.bridgeId+'.sock');
          if (Buffer.byteLength(socket)>103) {
            let hash=14695981039346656037n;
            for (const b of Buffer.from(socket)) hash=BigInt.asUintN(64,(hash^BigInt(b))*1099511628211n);
            const tmp=ENV.TMPDIR?.startsWith('/')?ENV.TMPDIR.replace(/\/+$/,''):'/tmp';
            socket=path.join(tmp,'heimdall-'+process.getuid(),hash.toString(16).padStart(16,'0')+'.sock');
          }
          children.push({kill:()=>spawnSync(process.env.HEIMDALL_E2E_PTY_BIN,['--socket',socket,'stop'],{env:ENV,timeout:5000})});
          let env;
          for (const deadline=Date.now()+45000;;await sleep(200)) {
            try {env=JSON.parse(fs.readFileSync(path.join(ROOT,iid+'.env.json'),'utf8'));} catch {}
            const state=await http(hubA,'GET','/api/v1/agent-instances/'+iid);
            if (env && state.data?.runtime_status==='running') break;
            if (Date.now()>deadline) throw new Error('synthetic child never became ready: '+JSON.stringify(state));
          }
          const call = (input) => {
            const filename=path.join(ROOT,'lease-input.json');fs.writeFileSync(filename,JSON.stringify(input),{mode:0o600});
            const called=spawnSync(process.env.HEIMDALL_E2E_CTL_BIN,['agent','task-chain','owner-local','lease','--request-file',filename],{env:{...ENV,...env},encoding:'utf8',timeout:20000});
            const reply=called.stdout.trim()?JSON.parse(called.stdout):{};
            return {status:called.status,reply,data:reply.data?.data ?? reply.data,error:called.stderr};
          };
          return {instanceId:iid,agentId:created.data.agent_id,call,stop:async()=>{await http(hubA,'POST','/api/v1/agent-instances/'+iid+'/stop',{body:{}});await sleep(1500);}};
        } : undefined,
        prepareGit: process.env.HEIMDALL_E2E_OWNER_LIFECYCLE === '1' ? (taskId, conflict=false) => {
          const repo=path.join(HOME,ownerIdForFixture('lifecycle-repo-'));
          fs.mkdirSync(repo,{recursive:true});
          const git=(cwd,...args)=>{
            const r=spawnSync('git',['-c','user.name=Fixture','-c','user.email=fixture@localhost','-C',cwd,...args],{encoding:'utf8',timeout:15000,env:ENV});
            if(r.status!==0) throw new Error('fixture git '+args.join(' ')+': '+r.stderr);
            return r.stdout.trim();
          };
          git(repo,'init','-b','sandbox');fs.writeFileSync(path.join(repo,'shared.txt'),'base\n');
          git(repo,'add','.');git(repo,'commit','-m','base');git(repo,'branch','integration');
          const worktree=path.join(repo,'.heimdall','worktrees',taskId),sourceBranch='heimdall/'+taskId;
          git(repo,'worktree','add','-b',sourceBranch,worktree);
          fs.writeFileSync(path.join(worktree,'shared.txt'),'source\n');git(worktree,'add','.');git(worktree,'commit','-m','source');
          if(conflict){
            const targetWork=path.join(HOME,ownerIdForFixture('target-work-'));
            git(repo,'worktree','add',targetWork,'integration');fs.writeFileSync(path.join(targetWork,'shared.txt'),'target\n');
            git(targetWork,'add','.');git(targetWork,'commit','-m','target');git(repo,'worktree','remove',targetWork);
          }
          return {repository:repo,worktree,sourceBranch,targetBranch:'integration',baseHead:git(repo,'rev-parse','integration'),head:git(worktree,'rev-parse','HEAD'),targetHead:()=>git(repo,'rev-parse','integration')};
        } : undefined,
        stopOwner: async () => {
          S.runA.kill(); await sleep(1500);
          // Seed an authorized disposable transport instance, bypassing provider
          // launch only. The real local token + Hub bridge/instance checks run.
          const iid = ownerIdForFixture('inst_'), epoch = ownerIdForFixture('epoch_');
          const assertion = spawnSync(process.env.HEIMDALL_E2E_IDENTITY_BIN, [iid, epoch], { encoding: 'utf8' });
          if (assertion.status !== 0) throw new Error('fixture assertion encoder failed');
          S.localToken = randomBytes(32).toString('hex');
          const seeded = spawnSync('python3', ['-c', `import sqlite3,sys,datetime
c=sqlite3.connect(sys.argv[1])
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
c.execute("insert into agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,created_at,updated_at,last_seen_at,launch_epoch) values(?,?,?,?,?,?,?,?,?)",(sys.argv[2],sys.argv[3],"agt_owner_fixture",sys.argv[4],"running",now,now,now,sys.argv[5]))
c.commit()
`, path.join(ROOT, 'hub-a', 'hub.db'), iid, S.apA.userId, S.a.bridgeId, epoch], { encoding: 'utf8' });
          if (seeded.status !== 0) throw new Error(seeded.stderr);
          const namespace = S.cfgA.local.replace(/[^a-zA-Z0-9_.-]/g, '_');
          const storeDir = path.join(S.cfgA.data, 'bridge', namespace);
          fs.mkdirSync(storeDir, { recursive: true });
          fs.writeFileSync(path.join(storeDir, 'local-tokens.jsonl'), JSON.stringify({
            token_hash: 'sha1:' + createHash('sha1').update(S.localToken).digest('hex'),
            agent_instance_id: iid, instance_token: assertion.stdout, role: 'agent', run_count: 0,
            issued_at_unix_ms: Date.now(), invalidated_at_unix_ms: 0,
          }) + '\n', { mode: 0o600 });
        },
        restartOwner: async () => {
          const restarted = await runtime({ ...S.cfgA, port: await freePort() }, [], online(hubA, S.a.bridgeId));
          expect(!restarted.refused && !restarted.timeout, 'isolated owner restarted');
          S.runA = restarted.child;
        },
        registryFixture: async (action, chainId) => {
          // Fixture control only: no live DBs or credentials are accepted here.
          if (action === 'publish') {
            const owned = fs.readFileSync(S.cfgA.token, 'utf8').trim();
            const token = owned.includes('\n') ? owned.slice(owned.indexOf('\n') + 1).trim() : owned;
            const response = await fetch(hubA.base + '/api/v1/owner-local/registry', {
              method:'POST', headers:{Authorization:'Bearer ' + token, 'Content-Type':'application/json'},
              body:JSON.stringify(registrySaved.get(chainId).publication),
            });
            return {status:response.status};
          }
          const prior = registrySaved.get(chainId) ?? {};
          const probe = spawnSync('python3', ['-c', `import sqlite3,sys,json
c=sqlite3.connect(sys.argv[1])
action,chain,prior=sys.argv[2],sys.argv[3],json.loads(sys.argv[4])
g=c.execute("select genesis_json from owner_local_chains where chain_id=?",(chain,)).fetchone()[0]
r,rev=c.execute("select registry_json,metadata_revision from owner_local_titles where chain_id=? and task_id=''",(chain,)).fetchone()
if action=="save": out={"previous":{"registry":r,"revision":rev}}
else:
 out={"publication":{"genesis":g,"registry":r}}
 if action=="rewind":
  old=prior["previous"]
  c.execute("update owner_local_titles set registry_json=?,metadata_revision=? where chain_id=? and task_id=''",(old["registry"],old["revision"],chain))
 elif action=="unregister":
  c.execute("delete from owner_local_titles where chain_id=?",(chain,))
  c.execute("delete from owner_local_chains where chain_id=?",(chain,))
 else: raise ValueError(action)
c.commit()
print(json.dumps(out))
`, path.join(ROOT,'hub-a','hub.db'), action, chainId, JSON.stringify(prior)], {encoding:'utf8'});
          if (probe.status !== 0) throw new Error('Synthetic registry fixture failed: ' + probe.stderr);
          registrySaved.set(chainId, {...prior,...JSON.parse(probe.stdout)});
        },
        rekeyOwner: async () => {
          const signed = await signedRequestHeaders(S.apA.identity, S.apA.userId, 'GET', '/api/v1/vault/devices/self', '');
          const self = await http(hubA,'GET','/api/v1/vault/devices/self',{headers:signed});
          S.apA.wrap = self.data.wrap;
          const chain = await S.apA.chain();
          await deliverKeyringToBridge(S.a.bridgeId, chain, {
            fetchTarget: async () => {
              const r = await http(hubA,'GET','/api/v1/bridges/' + S.a.bridgeId + '/public-key');
              return bridgeUnsealTargetFromRecord(S.a.bridgeId,r.data);
            },
            dispatch: async (id,payload) => {
              const r=await http(hubA,'POST','/api/v1/bridges/' + id + '/unseal',{body:payload});
              if(r.status!==200 || r.data?.ok===false) throw new Error('Synthetic rekey refused');
              return r.data;
            },
            withKeyringBytes: async fn => fn(Uint8Array.from(S.apA.keyringBytes)),
          });
        },
        inspectHub: async (chainId) => {
          const probe = spawnSync('python3', ['-c', `import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
assert c.execute("select count(*) from tasks where chain_id=?",(sys.argv[2],)).fetchone()[0]==0
assert c.execute("select count(*) from task_chains where chain_id=?",(sys.argv[2],)).fetchone()[0]==0
r=c.execute("select registry_json from owner_local_titles where chain_id=?",(sys.argv[2],)).fetchall()
assert len(r)==2 and all("owner-private" not in x[0] for x in r)
from pathlib import Path
for dbfile in Path(sys.argv[1]).parent.glob("hub.db*"):
 if dbfile.is_file(): assert all(marker not in dbfile.read_bytes() for marker in (b"owner-private", b"lifecycle-private", b"uniquesearch", b"search-private", b"sharedsearchword"))
assert all(marker not in (Path(sys.argv[1]).parent/"hub.log").read_bytes() for marker in (b"owner-private", b"lifecycle-private", b"uniquesearch", b"search-private", b"sharedsearchword"))
print("metadata-only Hub SQLite and log verified")
`, path.join(ROOT, 'hub-a', 'hub.db'), chainId], { encoding: 'utf8' });
          expect(probe.status === 0, 'Hub SQLite contains no local chain/task bodies: ' + probe.stderr);
        },
      });
    });
  }
  await step('3 the same bridge pointed at another hub refuses to start', async () => {
    S.runA?.kill();
    await sleep(500);
    const r = await runtime({ ...S.cfgA, port: await freePort() }, ['--hub', hubB.base]);
    expect(r.refused && /REFUSING TO START/.test(r.out) && /bound to\s+exactly one hub|holds no readable enrollment/i.test(r.out), `hub mismatch -> refused (exit ${r.exitCode})`);
  });
  await step('4 a second bridge enrolls against hub B on the same machine; bridge A is untouched', async () => {
    const intoA = spawnSync(process.env.HEIMDALL_E2E_BRIDGE_BIN, ['enroll', '--hub', hubB.base, '--headless', ...bridgeArgs(S.cfgA)], { cwd: S.cfgA.dir, env: ENV, encoding: 'utf8', timeout: 20_000 });
    expect(/REFUSED: config .* belongs to a bridge enrolled with/.test(intoA.stdout + intoA.stderr), 'enrolling hub B into bridge A\'s config is refused');
    S.apB = await approverFor(hubB);
    S.cfgB = await newBridgeDirs('bridge-b');
    S.b = await enroll(hubB, S.apB, S.cfgB);
    const rb = await runtime(S.cfgB, [], online(hubB, S.b.bridgeId));
    expect(!rb.refused && !rb.timeout, 'runtime B is online on hub B');
    const ra = await runtime({ ...S.cfgA, port: await freePort() }, [], online(hubA, S.a.bridgeId));
    expect(!ra.refused && !ra.timeout, 'bridge A still starts and connects to hub A after bridge B enrolled');
  });
}

function cleanupCredentials() {
  if (process.platform !== 'win32') return;
  const ids = CREATED;
  const list = spawnSync('cmdkey', ['/list'], { encoding: 'utf8' }).stdout || '';
  let removed = 0;
  for (const m of list.matchAll(/Target:\s*(?:LegacyGeneric:target=)?(\S+)/g)) {
    const target = m[1];
    if (target.startsWith('works.earendil.heimdall-bridge.') && ids.some((id) => target.includes(`:${id}_`))) {
      spawnSync('cmdkey', [`/delete:${target}`]);
      removed += 1;
    }
  }
  console.log(`removed ${removed} scoped credential(s) this run created`);
}

try {
  await main();
} catch (err) {
  results.push(['setup', 'FAIL']);
  console.log(`FAIL setup: ${err?.stack || err}`);
} finally {
  for (const c of children) { try { c.kill(); } catch { /* gone */ } }
  await sleep(500);
  cleanupCredentials();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { console.log(`(could not remove ${ROOT})`); }
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failed = results.filter(([, r]) => r !== 'PASS').length;
console.log(failed ? `${failed} step(s) FAILED` : 'all steps PASSED');
process.exitCode = failed ? 1 : 0;

