// Cross-OS conversion e2e (P2-7, REQ-CONV-1..5, REQ-OS-1; docs/specs/bridge-supervisor-conversion.md §13).
//
// REAL released legacy bridges (v0.5.77 and v0.5.86, downloaded and SHA-256 verified) are installed by
// their own `ham-bridge setup` against a THROWAWAY hub (real service manager: systemd --user, launchd,
// Task Scheduler), enrolled and connected. Then they are converted by a branch build of the first
// supervisor release (a test build: HEIMDALL_SUPERVISOR_TEST, the e2e signing key trusted, served by
// tools/conversion_release_server as a fake GitHub on loopback):
//   P1 v0.5.77   the old `update --auto-worker` runs the new setup -> converted, journal committed,
//                connected; status/restart work; the worker's late bookkeeping leaves it healthy.
//   P2 v0.5.86   the same for the newest legacy release.
//   P3 v0.5.77   failure injection after every step C2..C7 (rollback to the running legacy bridge, bin/,
//                service definition and credentials identical), abrupt exit of setup at C4 (the
//                rescuer) and at C8 (finalize_conversion), the Q3 agent gate (short test timeout, then
//                forced), ending converted.
//   P4 v0.5.77   a hub-started update converts it; the next hub update becomes an install_version intent.
//   P5 v0.5.77   `install.sh` / `install.ps1` re-run on the legacy instance converts it.
// Test hooks (test builds only): HEIMDALL_CONVERT_FAIL_AFTER / _KILL_AFTER / HEIMDALL_CONVERT_GATE_SECONDS /
// HEIMDALL_SUPERVISOR_TEST_ORIGIN, read from ~/.heimdall-supervisor-test.env because the OS service
// manager starts the processes (src/supervisor/service/test_env.odin). Uses the REAL home (CI runners only).
//
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_CONV_DIR=<conversion-build.sh out dir> HEIMDALL_E2E_SERVICE=1 \
//   node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/conversion_e2e.mjs
//   HEIMDALL_E2E_ONLY=P1,P3 selects phases; HEIMDALL_E2E_LEGACY_TAGS overrides v0.5.77,v0.5.86.

import { startNats } from './natsServer.mjs';
import { spawn as nodeSpawn, spawnSync as nodeSpawnSync } from 'node:child_process';
import crypto from 'node:crypto';
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
import { importKeyring, serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { encryptVaultText } from '../../src/ui/utils/vaultCrypto.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { buildBridgeApproval, buildGenesis, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, pairApproveMac } from '../../src/ui/utils/vaultPairing.ts';

const spawn = (c, a, o = {}) => nodeSpawn(c, a, { ...o, windowsHide: true });
const spawnSync = (c, a, o = {}) => nodeSpawnSync(c, a, { ...o, windowsHide: true });
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const WIN = process.platform === 'win32';
const MAC = process.platform === 'darwin';
const EXE = WIN ? '.exe' : '';
const CONV_DIR = process.env.HEIMDALL_E2E_CONV_DIR;
const NEW_VERSION = process.env.HEIMDALL_E2E_NEW_VERSION || '0.9.0';
const TAGS = (process.env.HEIMDALL_E2E_LEGACY_TAGS || 'v0.5.77,v0.5.86').split(',').map((s) => s.trim()).filter(Boolean);
const OLDEST = TAGS[0];
const NEWEST = TAGS[TAGS.length - 1];
const ONLY = (process.env.HEIMDALL_E2E_ONLY || '').split(',').map((s) => s.trim()).filter(Boolean);
const CACHE = process.env.HEIMDALL_E2E_CACHE || path.join(os.tmpdir(), 'heimdall-legacy-bundles');
const RELEASE_BASES = ['tanmayv/heimdall-releases', 'tanmayv/heimdall-agent-manager'].map((r) => `https://github.com/${r}/releases/download`);

if (process.env.HEIMDALL_E2E_SERVICE !== '1') throw new Error('conversion e2e needs a real service manager and the real home: set HEIMDALL_E2E_SERVICE=1 (CI runners only)');
if (!CONV_DIR || !process.env.HEIMDALL_E2E_HUB_BIN) throw new Error('set HEIMDALL_E2E_HUB_BIN and HEIMDALL_E2E_CONV_DIR');
scrubHeimdallEnv();
const HOME = os.homedir();
refuseLegacyInstall(HOME);
const ENV = { ...process.env };
if (WIN && (!ENV.APPDATA || !ENV.LOCALAPPDATA)) throw new Error('APPDATA/LOCALAPPDATA unset');
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-conv-'));
const BUNDLE = path.join(CONV_DIR, 'bundle');
const NEW_BRIDGE = path.join(BUNDLE, 'bin', `ham-bridge${EXE}`);
const STATE_ROOT = WIN ? path.join(ENV.APPDATA, 'heimdall', 'bridges') : path.join(HOME, '.config', 'heimdall', 'bridges');
const DATA_ROOT = WIN ? path.join(ENV.LOCALAPPDATA, 'heimdall', 'bridges') : path.join(HOME, '.local', 'share', 'heimdall', 'bridges');
const TEST_ENV_FILE = path.join(HOME, '.heimdall-supervisor-test.env');
const children = [];
const profiles = []; // every profile this run installed, for cleanup
const created = []; // bridge ids
const results = [];
class CheckFailed extends Error {}
const expect = (cond, msg) => { if (!cond) throw new CheckFailed(msg); console.log(`    ok - ${msg}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function step(name, fn) {
  if (process.env.HEIMDALL_E2E_CONV_PHASE && !name.startsWith(process.env.HEIMDALL_E2E_CONV_PHASE + ' ')) return;
  const phase = name.split(' ')[0];
  if (ONLY.length && !ONLY.includes(phase)) return;
  console.log(`\n== ${name}`);
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS ${name}`); }
  catch (err) { results.push([name, 'FAIL']); console.log(`    not ok - ${err instanceof CheckFailed ? err.message : (err?.stack || err)}`); console.log(`FAIL ${name}`); }
}
async function until(cond, what, ms = 60_000, every = 500) {
  for (const end = Date.now() + ms; ; await sleep(every)) {
    const v = await cond();
    if (v) return v;
    if (Date.now() > end) throw new CheckFailed(`timed out (${ms / 1000}s) waiting for ${what}`);
  }
}
async function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
  });
}
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const sha = (p) => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
function target() {
  const arch = process.arch === 'arm64' ? 'arm64' : 'amd64';
  return WIN ? 'windows-amd64' : MAC ? `darwin-${arch}` : `linux-${arch}`;
}

// ---- hub, account, enrollment (the approving browser; same flow as bridge_lifecycle_e2e.mjs) ----------

async function startHub() {
  const migrations = path.join(REPO_ROOT, 'src', 'hub', 'repository', 'sqlite', 'migrations');
  const dir = path.join(ROOT, 'hub');
  fs.mkdirSync(dir, { recursive: true });
  const port = await freePort();
  const log = fs.openSync(path.join(dir, 'hub.log'), 'w');
  const nats = await startNats(dir);
  children.push({ kill: nats.kill });
  const mock = await startMockOidc();
  children.push({ kill: mock.stop });
  const base = `http://127.0.0.1:${port}`;
  const child = spawn(process.env.HEIMDALL_E2E_HUB_BIN, ['--listen', `127.0.0.1:${port}`, '--db', path.join(dir, 'hub.db'), '--migrations-dir', migrations, '--ui-origin', base],
    { cwd: dir, env: { ...ENV, ...mock.hubEnv(base), ...nats.hubEnv, HEIMDALL_UPDATE_CATALOG_OFFLINE: '1', HEIMDALL_UPDATE_MANIFEST_PATH: path.join(dir, 'update-manifest.json') }, stdio: ['ignore', log, log] });
  children.push(child);
  await until(async () => { try { return (await fetch(`${base}/api/v1/health`)).ok; } catch { return false; } }, 'the hub', 30_000, 150);
  return { base, port, dir };
}
async function http(acct, method, p, { body, headers = {} } = {}) {
  const h = { ...sessionHeaders(acct.session, acct.base), ...headers };
  const text = body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body));
  if (text !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${acct.base}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, raw };
}
async function account(hub, user) {
  const acct = { base: hub.base, session: await hubLogin(hub.base, user) };
  const me = await http(acct, 'GET', '/api/v1/me');
  const userId = me.data.user_id;
  const identity = await createDeviceIdentity(memoryDeviceStore(), userId);
  const g = await http(acct, 'POST', '/api/v1/vault/directory/genesis', { body: await buildGenesis(identity, `e2e approver ${user}`) });
  if (g.status !== 201) throw new Error(`genesis ${g.status} ${g.raw}`);
  const signed = async (m, p, b = '') => signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, userId, m, p, b);
  const chain = async () => verifyDirectory((await http(acct, 'GET', '/api/v1/vault/directory')).data, userId, null);
  const self = await http(acct, 'GET', '/api/v1/vault/devices/self', { headers: await signed('GET', '/api/v1/vault/devices/self') });
  const parsed = await openVerifiedWrap(self.data.wrap, { userId, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chain() });
  const keyringBytes = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  return { ...acct, userId, identity, chain, keyringBytes };
}
async function bridgesOf(acct) {
  const r = await http(acct, 'GET', '/api/v1/bridges');
  return Array.isArray(r.data) ? r.data : (r.data?.bridges ?? []);
}
const online = (acct, id) => async () => (await bridgesOf(acct)).some((b) => b.bridge_id === id && (b.status === 'online' || b.runtime_connected === true));

// Approve the pairing code that `ham-bridge setup` (a child process) prints, like /device/add.
async function approveSetup(hub, acct, child, label) {
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  const exited = new Promise((r) => child.once('exit', (code) => r(code)));
  const code = await until(() => (/^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m.exec(out) || [])[1], `a pairing code from setup\n${out}`, 120_000, 100);
  const salts = await http(acct, 'POST', '/api/v1/device/pair-salts', { body: {} });
  const tried = [];
  for (const c of (salts.data?.candidates ?? []).filter((x) => x.kind === 'bridge')) {
    tried.push({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: c.pair_hub_origin, pairSalt: c.pair_salt }) });
  }
  const ver = await http(acct, 'POST', '/api/v1/device/verify', { body: { pair_lookups: tried.map((c) => c.keys.lookup) } });
  const keys = tried.find((c) => c.salt === ver.data?.pair_salt)?.keys;
  expect(ver.status === 200 && ver.data.kind === 'bridge' && keys, `the typed code resolves the bridge (${ver.status})`);
  await checkBridgeCodeInfo(ver.data, keys);
  const { vault_approval, statement } = await buildBridgeApproval(acct.identity, await acct.chain(), ver.data, label);
  const appr = await http(acct, 'POST', '/api/v1/device/approve', { body: { pair_lookup: keys.lookup, approve: true, vault_approval, new_bridge_label: label } });
  const bridgeId = appr.data?.hub_observed?.bridge_id;
  expect(appr.status === 200 && bridgeId, `approved -> ${bridgeId} (${appr.status} ${appr.status === 200 ? '' : appr.raw})`);
  created.push(bridgeId);
  let target_ = null;
  await until(async () => {
    const pk = await http(acct, 'GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`);
    if (pk.status === 200 && pk.data?.unseal_key_signature) { target_ = bridgeUnsealTargetFromRecord(bridgeId, pk.data); return true; }
    return false;
  }, 'the enrolling bridge to connect', 60_000, 250);
  const after = await acct.chain();
  const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
  await deliverKeyringToBridge(bridgeId, after, {
    fetchTarget: async () => target_,
    dispatch: async (id, payload) => {
      const r = await http(acct, 'POST', `/api/v1/bridges/${id}/unseal`, { body: payload });
      if (r.status !== 200 || r.data?.ok === false) throw new Error(`unseal refused: ${r.status} ${r.raw}`);
      return r.data;
    },
    withKeyringBytes: async (fn) => { const b = Uint8Array.from(acct.keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
  }, { enrollment: true, identityPublicKey: ver.data.bridge_identity_public_key, expectedPublicKey: target_.publicKey, extra: { enrollment: true, expected_public_key: target_.publicKey, pair_mac: pairMac } });
  const exitCode = await Promise.race([exited, sleep(240_000).then(() => 'timeout')]);
  expect(exitCode === 0, `legacy setup exits 0 (exit ${exitCode})${exitCode === 0 ? '' : `\n${out}`}`);
  return bridgeId;
}

// ---- layouts ------------------------------------------------------------------------------------------------

function layout(hub, name) {
  const u = new URL(hub.base);
  const service = `heimdall-bridge-${u.hostname.replace(/[^a-z0-9-]/g, '-')}-${u.port}_${name}`;
  return {
    name, service, state: path.join(STATE_ROOT, service), data: path.join(DATA_ROOT, service),
    unit: WIN ? '' : MAC ? path.join(HOME, 'Library', 'LaunchAgents', `${service}.plist`) : path.join(HOME, '.config', 'systemd', 'user', `${service}.service`),
    bin: path.join(DATA_ROOT, service, 'bin', `ham-bridge${EXE}`),
  };
}
const hubArgs = (hub, L) => ['--hub', hub.base, '--profile', L.name];

// ---- the real legacy release ----------------------------------------------------------------------------

async function get(url) {
  const res = await fetch(url, { redirect: 'follow', headers: { 'user-agent': 'heimdall-e2e' } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}
async function legacyBundle(tag) {
  const dir = path.join(CACHE, `${tag}-${target()}`);
  const exe = path.join(dir, 'bin', `ham-bridge${EXE}`);
  if (fs.existsSync(exe)) return dir;
  const name = `heimdall-local-${target()}-${tag}${WIN ? '.zip' : '.tar.gz'}`;
  let base = '';
  let sums = '';
  for (const c of RELEASE_BASES) {
    try { sums = (await get(`${c}/${tag}/SHA256SUMS`)).toString('utf8'); base = c; break; } catch { /* next repo */ }
  }
  if (!base) throw new Error(`${tag}: no SHA256SUMS`);
  const line = sums.split(/\r?\n/).filter((l) => l.trim().endsWith(` ${name}`) || l.trim().endsWith(`*${name}`));
  if (line.length !== 1) throw new Error(`${tag}: SHA256SUMS lists ${name} ${line.length} times`);
  const body = await get(`${base}/${tag}/${name}`);
  if (crypto.createHash('sha256').update(body).digest('hex') !== line[0].trim().split(/\s+/)[0].toLowerCase()) throw new Error(`${name}: digest mismatch`);
  fs.mkdirSync(dir, { recursive: true });
  const archive = path.join(dir, name);
  fs.writeFileSync(archive, body);
  const r = spawnSync('tar', ['-xf', archive, '-C', dir], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`cannot unpack ${name}: ${r.stderr}`);
  if (!fs.existsSync(exe)) throw new Error(`${name} has no bin/ham-bridge${EXE}`);
  return dir;
}

// Install the REAL legacy release as a profile: its own `setup`, enrolled and connected.
async function installLegacy(hub, acct, tag, name) {
  const dir = await legacyBundle(tag);
  const L = layout(hub, name);
  profiles.push(L);
  const child = spawn(path.join(dir, 'bin', `ham-bridge${EXE}`), ['setup', ...hubArgs(hub, L), '--headless', '--no-tray'], { cwd: ROOT, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  L.bridgeId = await approveSetup(hub, acct, child, name);
  await until(online(acct, L.bridgeId), `${tag} to connect`, 90_000);
  const v = spawnSync(L.bin, ['--version'], { encoding: 'utf8' });
  expect(`${v.stdout}`.includes(tag.slice(1)), `${name}: installed ham-bridge is ${tag} (${v.stdout.trim()})`);
  expect(!fs.existsSync(path.join(L.data, 'instance.json')), `${name}: a legacy install has no instance.json`);
  return L;
}

// ---- the fake release repo and the test hooks -------------------------------------------------------------

let RELEASE = null; // { origin, assetPath, sumsPath, tag }
async function startRelease() {
  const portFile = path.join(ROOT, 'release.port');
  const out = path.join(ROOT, 'release');
  const tag = `v${NEW_VERSION}`;
  const child = spawn(path.join(CONV_DIR, 'tools', `conversion_release_server${EXE}`), ['--dir', BUNDLE, '--tag', tag, '--port-file', portFile, '--out', out], { cwd: ROOT, env: ENV, stdio: ['ignore', 'inherit', 'inherit'] });
  children.push(child);
  await until(() => fs.existsSync(portFile), 'the fake release repo', 60_000, 200);
  const asset = fs.readdirSync(out).find((f) => f.startsWith('heimdall-local-'));
  const sums = path.join(out, 'SHA256SUMS');
  fs.writeFileSync(sums, `${sha(path.join(out, asset))}  ${asset}\n`);
  RELEASE = { origin: `http://127.0.0.1:${fs.readFileSync(portFile, 'utf8').trim()}`, assetPath: path.join(out, asset), sumsPath: sums, tag };
  const v = spawnSync(NEW_BRIDGE, ['--version'], { encoding: 'utf8' });
  expect(v.stdout.includes(NEW_VERSION), `the bundle's ham-bridge is ${NEW_VERSION} (${v.stdout.trim()})`);
}
function hooks(extra = {}) {
  const lines = [`HEIMDALL_SUPERVISOR_TEST_ORIGIN=${RELEASE.origin}`, ...Object.entries(extra).map(([k, v]) => `${k}=${v}`)];
  fs.writeFileSync(TEST_ENV_FILE, `${lines.join('\n')}\n`);
}

// ---- observations ---------------------------------------------------------------------------------------

function treeHashes(dir, skip = () => false, rel = '') {
  const out = {};
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (skip(r)) continue;
    if (e.isDirectory()) Object.assign(out, treeHashes(path.join(dir, e.name), skip, r));
    else if (e.isFile()) out[r] = sha(path.join(dir, e.name));
  }
  return out;
}
function serviceDefHashes(L) {
  if (L.unit) return fs.existsSync(L.unit) ? { [L.unit]: sha(L.unit) } : {};
  return treeHashes(L.data, (r) => r.includes('/') || !/^(run|task)/.test(r)); // run.cmd, run.vbs, task.xml
}
const snapshot = (L) => ({
  bin: treeHashes(path.join(L.data, 'bin'), (r) => r.startsWith('ham-ctl-')), // the generated wrapper may differ (spec §13.2)
  service: serviceDefHashes(L),
  credentials: treeHashes(L.state, (r) => !/^bridge-token/.test(r)),
  config: fs.existsSync(path.join(L.state, 'config.toml')) ? sha(path.join(L.state, 'config.toml')) : '',
});
const runtimePid = (L) => readJson(path.join(L.state, 'runtime-status.json'))?.pid || 0;
const readOps = (journalDir) => {
  try { const lines = fs.readFileSync(path.join(journalDir, 'ops.jsonl'), 'utf8').trim().split('\n'); return lines.map((l) => JSON.parse(l)); } catch { return []; }
};

const lastOp = (L) => readOps(path.join(L.data, 'supervisor', 'journal'));

async function assertConverted(acct, L, what) {
  await until(() => !fs.existsSync(path.join(L.data, 'conversion.json')) && fs.existsSync(path.join(L.data, 'instance.json')), `${what}: conversion finished`, 600_000, 1000);
  const kg = readJson(path.join(L.data, 'known-good.json'));
  expect(kg?.committed_op?.startsWith('op_convert_'), `${what}: known-good.json is committed by ${kg?.committed_op}`);
  expect(fs.readdirSync(path.join(L.data, 'releases')).some((t) => t === kg.tree), `${what}: releases/${kg.tree} exists`);
  const ops = lastOp(L);
  expect(ops.some((op) => op.op_id === kg.committed_op && op.state === 'committed'), `${what}: the journal has a committed operation`);
  expect(fs.existsSync(path.join(L.data, 'launcher', `ham-launcher${EXE}`)), `${what}: launcher installed`);
  await until(online(acct, L.bridgeId), `${what}: connected to the hub`, 120_000);
  expect(true, `${what}: connected to the hub`);
}
async function assertRolledBack(acct, L, before, what, oldTag) {
  await until(() => !fs.existsSync(path.join(L.data, 'conversion.json')), `${what}: conversion.json removed`, 120_000, 500);
  for (const f of ['instance.json', 'releases', 'launcher', 'known-good.json']) expect(!fs.existsSync(path.join(L.data, f)), `${what}: no ${f}`);
  const v = spawnSync(L.bin, ['--version'], { encoding: 'utf8' });
  expect(v.stdout.includes(oldTag.slice(1)), `${what}: ham-bridge --version is still ${oldTag}`);
  await until(online(acct, L.bridgeId), `${what}: the legacy bridge is running and connected again`, 120_000);
  const now = snapshot(L);
  for (const k of Object.keys(before)) expect(JSON.stringify(now[k]) === JSON.stringify(before[k]), `${what}: ${k} identical to before`);
}

// The old worker, exactly as the legacy bridge's timer spawns it (P2-6): --bundle is the only seam the
// old fetch has; setup (the NEW binary) downloads and verifies the release from the fake origin.
function startWorker(L) {
  const log = fs.openSync(path.join(ROOT, `worker-${L.name}.out`), 'w');
  const child = spawn(L.bin, ['update', '--bundle', BUNDLE, '--service', L.service, '--auto-worker'], { cwd: ROOT, env: ENV, stdio: ['ignore', log, log] });
  children.push(child);
  const done = new Promise((r) => child.once('exit', (code) => r(code)));
  return { child, done, log: () => fs.readFileSync(path.join(ROOT, `worker-${L.name}.out`), 'utf8') };
}

// ---- hub-started update -------------------------------------------------------------------------------

async function hubUpdate(hub, acct, L, body) {
  return http(acct, 'POST', `/api/v1/bridges/${L.bridgeId}/update`, { body });
}
function publishHubManifest(hub, bridge) {
  const work = path.join(ROOT, 'hub-update');
  fs.rmSync(work, { recursive: true, force: true });
  fs.cpSync(BUNDLE, path.join(work, 'pkg'), { recursive: true });
  const tarball = path.join(work, 'ham-bridge-conv-update.tar.gz');
  const tar = spawnSync('tar', ['-czf', path.basename(tarball), '-C', 'pkg', '.'], { cwd: work, encoding: 'utf8' });
  expect(tar.status === 0, `packed the hub update bundle ${tar.stderr}`);
  fs.writeFileSync(path.join(hub.dir, 'update-manifest.json'), JSON.stringify({ version: NEW_VERSION, commit_sha: '', targets: { [bridge.target]: { tarball_url: tarball, sha256: sha(tarball) } } }));
}

// ---- main ---------------------------------------------------------------------------------------------------

async function main() {
  const hub = await startHub();
  const acct = await account(hub, 'e2e-conversion');
  await startRelease();
  console.log(`hub ${hub.base}; fake release ${RELEASE.origin} (${RELEASE.tag}); legacy ${TAGS.join(', ')}`);
  const suffix = crypto.randomBytes(2).toString('hex');
  let L;

  await step(`P1 ${OLDEST} auto-update converts (success path)`, async () => {
    hooks();
    L = await installLegacy(hub, acct, OLDEST, `c1${suffix}`);
    const pidBefore = runtimePid(L);
    const w = startWorker(L);
    await assertConverted(acct, L, 'P1');
    expect(runtimePid(L) !== pidBefore, 'P1: a new runtime process (the supervised one) serves the bridge');
    const code = await Promise.race([w.done, sleep(300_000).then(() => 'timeout')]);
    expect(code === 0, `P1: the old worker exits 0 after setup returned (exit ${code})\n${w.log()}`);
    await sleep(3000); // its late auto-update.json bookkeeping must leave the converted instance healthy
    await until(online(acct, L.bridgeId), 'P1: still connected after the worker finished', 60_000);
    expect(!fs.existsSync(path.join(L.data, 'conversion.json')), 'P1: no conversion.json after the worker finished');
    const st = spawnSync(NEW_BRIDGE, ['status', ...hubArgs(hub, L)], { env: ENV, encoding: 'utf8', timeout: 30_000 });
    expect(st.status === 0 && /running/i.test(st.stdout), `P1: ham-bridge status reports it running (exit ${st.status}) ${st.stdout}${st.stderr}`);
    const rs = spawnSync(NEW_BRIDGE, ['service', 'restart', ...hubArgs(hub, L), '--json'], { env: ENV, encoding: 'utf8', timeout: 120_000 });
    expect(rs.status === 0, `P1: service restart works on the converted instance (exit ${rs.status}) ${rs.stdout}${rs.stderr}`);
    await until(online(acct, L.bridgeId), 'P1: reconnected after restart', 120_000);
  });

  await step(`P2 ${NEWEST} (newest legacy) auto-update converts`, async () => {
    hooks();
    const L2 = await installLegacy(hub, acct, NEWEST, `c2${suffix}`);
    const w = startWorker(L2);
    await assertConverted(acct, L2, 'P2');
    const code = await Promise.race([w.done, sleep(300_000).then(() => 'timeout')]);
    expect(code === 0, `P2: the old worker exits 0 (exit ${code})\n${w.log()}`);
  });

  await step(`P3 ${OLDEST} failure injection, gate, kill after C8`, async () => {
    L = await installLegacy(hub, acct, OLDEST, `c3${suffix}`);
    const before = snapshot(L);
    // Returned error after each step: the transaction rolls back to the running legacy bridge.
    for (const c of ['C2', 'C3', 'C4', 'C5', 'C6', 'C6b', 'C6c', 'C7']) {
      hooks({ HEIMDALL_CONVERT_FAIL_AFTER: c });
      const w = startWorker(L);
      await Promise.race([w.done, sleep(300_000).then(() => 'timeout')]);
      await assertRolledBack(acct, L, before, `fail after ${c}`, OLDEST);
    }
    // Setup dies abruptly at C4 (no rollback code runs): the rescuer restarts the legacy bridge.
    hooks({ HEIMDALL_CONVERT_KILL_AFTER: 'C4' });
    await Promise.race([startWorker(L).done, sleep(300_000).then(() => 'timeout')]);
    await assertRolledBack(acct, L, before, 'abrupt exit after C4 (rescuer)', OLDEST);

    // Q3 agent gate: a running agent makes a timer conversion wait, then the test timeout forces it.
    hooks({ HEIMDALL_CONVERT_GATE_SECONDS: 45, HEIMDALL_CONVERT_KILL_AFTER: 'C8' });
    const probe = await startAgent(acct, L);
    const w = startWorker(L);
    const status = await until(() => readJson(path.join(L.state, 'conversion-status.json')), 'the gate countdown file', 60_000, 250);
    expect(status.state === 'waiting' && status.agents >= 1 && status.force_at > 0, `gate waiting for ${status.agents} agent(s), force_at ${status.force_at}`);
    expect(probe.pid() === probe.originalPid, 'the agent is untouched while the gate waits');
    expect(!fs.existsSync(path.join(L.data, 'instance.json')), 'nothing was changed while the gate waits');
    // The forced conversion stops the agent, converts, and (test hook) setup dies right after C8.
    await Promise.race([w.done, sleep(300_000).then(() => 'timeout')]);
    expect(probe.pid() === 0, 'the agent was stopped by the forced conversion');
    expect(fs.existsSync(path.join(L.data, 'conversion.json')) || fs.existsSync(path.join(L.data, 'instance.json')), 'conversion progressed past the gate');
    await probe.close();
    // Kill after C8: the supervised bridge is up; finalize_conversion (C9 without setup) completes it.
    hooks();
    await assertConverted(acct, L, 'kill after C8');
    await until(() => !fs.existsSync(path.join(L.data, 'conversion.json')), 'finalize_conversion removed conversion.json', 180_000, 1000);
    expect(!fs.existsSync(path.join(L.data, `.convert-${(readJson(path.join(L.data, 'known-good.json')) || {}).tree}`)), 'finalize left no backup dir');
  });

  await step(`P4 ${OLDEST} hub-started update converts; the next update is an intent`, async () => {
    hooks();
    const L4 = await installLegacy(hub, acct, OLDEST, `c4${suffix}`);
    const b = (await bridgesOf(acct)).find((x) => x.bridge_id === L4.bridgeId);
    expect(b?.version && b?.target, `the hub knows the bridge version/target (${JSON.stringify(b)})`);
    publishHubManifest(hub, b);
    const res = await hubUpdate(hub, acct, L4, { target_version: 'latest', force: true, drain_timeout_seconds: 30 });
    expect(res.status === 202, `hub dispatched the update (HTTP ${res.status}) ${res.raw}`);
    await assertConverted(acct, L4, 'P4 hub-started');
    // The converted bridge now routes a hub update to the supervisor as an install_version intent.
    const inbox = path.join(L4.data, 'intents');
    const res2 = await hubUpdate(hub, acct, L4, { target_version: RELEASE.tag, force: true, drain_timeout_seconds: 30 });
    expect(res2.status === 202, `hub dispatched the second update (HTTP ${res2.status}) ${res2.raw}`);
    await until(() => {
      const seen = (d) => fs.existsSync(d) && fs.readdirSync(d).some((f) => f.endsWith('.json') && fs.readFileSync(path.join(d, f), 'utf8').includes('install_version'));
      return seen(path.join(inbox, 'inbox')) || seen(path.join(inbox, 'done')) || seen(path.join(inbox, 'processed')) || JSON.stringify(lastOp(L4)).includes('install_version');
    }, 'an install_version intent for the second hub update', 120_000, 1000);
    await until(online(acct, L4.bridgeId), 'P4: still connected after the intent', 120_000);
  });

  await step(`P5 ${OLDEST} installer re-run converts`, async () => {
    hooks();
    const L5 = await installLegacy(hub, acct, OLDEST, `c5${suffix}`);
    // The released legacy bridge and the ad hoc test bundle have different
    // macOS signing identities. Grant the staged CDHash access only to P5's
    // records in the dedicated, disposable CI keychain.
    const fixtureKeychain = process.env.HEIMDALL_E2E_P5_KEYCHAIN;
    if (MAC && fixtureKeychain) {
      expect(process.env.GITHUB_ACTIONS === 'true' &&
        fixtureKeychain === path.join(process.env.RUNNER_TEMP || '', 'e2e.keychain-db'),
        'P5: Keychain pre-authorization is confined to the CI fixture');
      const signature = spawnSync('/usr/bin/codesign', ['-dv', '--verbose=4', NEW_BRIDGE], { encoding: 'utf8', timeout: 10_000 });
      const cdHash = signature.stderr?.match(/^CDHash=([a-f0-9]{40})$/im)?.[1];
      expect(signature.status === 0 && cdHash, 'P5: identified the staged runtime CDHash');
      const partitions = 'teamid:8TSXLYJZN3,cdhash:' + cdHash;
      const security = (args) => spawnSync('/usr/bin/security', args, { encoding: 'utf8', timeout: 15_000 });
      // Metadata only. Never use dump-keychain -d or find-generic-password -g/-w.
      const dump = security(['dump-keychain', fixtureKeychain]);
      const fixtureRecords = (dump.stdout || '').split(/(?=^keychain: )/m).flatMap((entry) => {
        const keychain = entry.match(/^keychain: "([^"]+)"/m)?.[1];
        const service = entry.match(/^\s*"svce"<blob>="(works\.earendil\.heimdall-bridge\.vault-[a-z-]+)"\s*$/m)?.[1];
        const account = entry.match(/^\s*"acct"<blob>="([^"]+)"\s*$/m)?.[1];
        return keychain && service && account ? [{ keychain, service, account }] : [];
      });
      expect(dump.status === 0, 'P5: read disposable Keychain metadata (' + (dump.stderr?.trim() || dump.status) + ')');
      // Mirror keystore_scope_name_for_hub for the harness's canonical loopback base.
      const scope = crypto.createHash('sha256')
        .update(`heimdall-bridge-scope/v1|${hub.base}|${L5.bridgeId}`).digest('hex').slice(0, 32);
      const records = fixtureRecords.filter((record) => record.account === `${L5.bridgeId}_${scope}`);
      expect(records.length > 0, 'P5: found legacy vault items for the fixture account');
      for (const { keychain, service, account } of records) {
        expect(keychain === fixtureKeychain, 'P5: ' + service + ' is in the disposable CI Keychain (' + keychain + ')');
        const acl = security(['set-generic-password-partition-list', '-a', account, '-s', service,
          '-S', partitions, '-k', 'e2e', keychain]);
        expect(acl.status === 0, 'P5: pre-authorized ' + service + ' (status ' + acl.status +
          ', stderr ' + (acl.stderr?.trim() || acl.error?.code || 'none') + ')');
      }
    }
    const pidBefore = runtimePid(L5);
    const args = ['--hub', hub.base, '--profile', L5.name, '--bundle', RELEASE.assetPath, '--checksum-file', RELEASE.sumsPath];
    let r;
    const macReports = {};
    const collectMac = MAC && Boolean(process.env.HEIMDALL_E2E_P5_DIAGNOSTICS && process.env.HEIMDALL_E2E_P5_PUBLIC_KEY);
    const commandReport = (cmd, args) => {
      const probe = spawnSync(cmd, args, { encoding: 'utf8', timeout: 8_000 });
      return JSON.stringify({ status: probe.status, error: probe.error?.code, stdout: probe.stdout, stderr: probe.stderr });
    };
    if (collectMac) macReports['codesign-legacy'] = commandReport('/usr/bin/codesign', ['-dv', '--verbose=4', L5.bin]);
    if (WIN) {
      const ps = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(REPO_ROOT, 'scripts', 'install.ps1'), '-Hub', hub.base, '-Profile', L5.name, '-Bundle', RELEASE.assetPath, '-ChecksumFile', RELEASE.sumsPath];
      const env = { ...ENV }; delete env.PSModulePath;
      r = spawnSync('powershell.exe', ps, { env, encoding: 'utf8', timeout: 900_000 });
    } else if (MAC) {
      // Observe the managed runtime before rollback can remove its process records.
      const child = spawn('bash', [path.join(REPO_ROOT, 'scripts', 'install.sh'), ...args], { env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
      const seen = new Set();
      let sampleRun;
      let samplePid;

      const observe = () => {
        const root = L5.data;
        const procs = readJson(path.join(root, 'supervisor', 'procs.json'));
        const runtime = readJson(path.join(L5.state, 'runtime-status.json'));
        const control = readJson(path.join(root, 'run', 'supervisor-control.json'));
        let logBytes = null;
        try { logBytes = fs.statSync(path.join(root, 'logs', 'runtime.log')).size; } catch {}
        const managed = procs?.procs?.find((proc) => proc.role === 'runtime');
        if (collectMac && managed?.pid && !sampleRun && control?.pid !== managed.pid) {
          if (samplePid !== managed.pid) {
            samplePid = managed.pid;
            macReports['codesign-managed'] = commandReport('/usr/bin/codesign', ['-dv', '--verbose=4', path.join(root, 'releases', managed.tree, 'bin', 'ham-bridge')]);
          } else {
            // This is a CI-owned runtime. Wait for a second observation before sampling.
            const sampled = spawn('/usr/bin/sample', [String(managed.pid), '3', '10'], { stdio: ['ignore', 'pipe', 'pipe'] });
            let output = '';
            sampled.stdout.on('data', (chunk) => { output += chunk; });
            sampled.stderr.on('data', (chunk) => { output += chunk; });
            const limit = setTimeout(() => sampled.kill(), 10_000);
            sampleRun = new Promise((resolve) => {
              sampled.once('error', (err) => { clearTimeout(limit); resolve(String(err)); });
              sampled.once('close', (code) => { clearTimeout(limit); resolve('exit ' + code + '\n' + output); });
            });
          }
        }
        const summary = JSON.stringify({
          processes: (procs?.procs || []).map(({ role, pid }) => ({ role, pid })),
          runtimePid: runtime?.pid, connected: runtime?.connected,
          controlPid: control?.pid, logBytes,
        });
        seen.add(summary);
      };
      let stdout = '', stderr = '';
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      const interval = setInterval(observe, 500);
      const timeout = setTimeout(() => child.kill(), 900_000);
      try {
        const status = await new Promise((resolve, reject) => {
          child.once('close', resolve);
          child.once('error', reject);
        });
        r = { status, stdout, stderr };
      } finally {
        clearInterval(interval);
        clearTimeout(timeout);
      }
      if (r.status !== 0) for (const summary of seen) console.log('    P5 startup sample:', summary);
      if (collectMac && r.status !== 0) {
        if (sampleRun) macReports['runtime-sample'] = await sampleRun;
        macReports['securityd-log'] = commandReport('/usr/bin/log', ['show', '--last', '3m', '--style', 'compact', '--predicate', 'process == "securityd" AND (eventMessage CONTAINS[c] "ACL" OR eventMessage CONTAINS[c] "interaction" OR eventMessage CONTAINS[c] "prompt")']);
      }
    } else {
      r = spawnSync('bash', [path.join(REPO_ROOT, 'scripts', 'install.sh'), ...args], { env: ENV, encoding: 'utf8', timeout: 900_000, input: '' });
    }
    const diagnostics = process.env.HEIMDALL_E2E_P5_DIAGNOSTICS;
    const publicKey = process.env.HEIMDALL_E2E_P5_PUBLIC_KEY;
    if (diagnostics && publicKey) {
      // This repository is public. Keep raw fixture log contents out of public artifacts.
      fs.mkdirSync(diagnostics, { recursive: true });
      const save = (name, content) => {
        const key = crypto.randomBytes(32);
        const iv = crypto.randomBytes(12);
        const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
        const ciphertext = Buffer.concat([cipher.update(content), cipher.final()]);
        const wrapped = crypto.publicEncrypt({ key: Buffer.from(publicKey, 'base64').toString('utf8'), oaepHash: 'sha256' }, key);
        fs.writeFileSync(path.join(diagnostics, name + '.json'), JSON.stringify({
          wrapped: wrapped.toString('base64'), iv: iv.toString('base64'),
          tag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64'),
        }));
      };
      const collect = (name, file) => { if (fs.existsSync(file)) save(name, fs.readFileSync(file)); };
      collect('runtime.log', path.join(L5.data, 'logs', 'runtime.log'));
      collect('live-ops.jsonl', path.join(L5.data, 'supervisor', 'journal', 'ops.jsonl'));
      for (const name of fs.readdirSync(L5.data).filter((entry) => entry.startsWith('conversion-failed-'))) {
        collect(name + '-ops.jsonl', path.join(L5.data, name, 'journal', 'ops.jsonl'));
        collect(name + '-launcher-status', path.join(L5.data, name, 'launcher-status.json'));
      }
      if (MAC) {
        for (const [name, report] of Object.entries(macReports)) save(name, report);
        save('installer.stdout', r.stdout || '');
        save('installer.stderr', r.stderr || '');
      }
    }
    if (r.status !== 0) {
      const active = lastOp(L5);
      const archived = fs.readdirSync(L5.data)
        .filter((name) => name.startsWith('conversion-failed-'))
        .flatMap((name) => readOps(path.join(L5.data, name, 'journal')));
      const states = (active.length ? active : archived).map(({ state, sub, error, note }) => ({ state, sub, error, note }));
      console.log('    P5 journal transitions:', JSON.stringify(states));
      for (const dir of [L5.data, L5.state, path.join(L5.data, 'logs')]) {
        if (fs.existsSync(dir)) console.log('    P5 files:', dir, fs.readdirSync(dir).join(', '));
      }
      for (const file of ['runtime.log', 'bridge.err.log']) {
        const logPath = path.join(L5.data, 'logs', file);
        if (!fs.existsSync(logPath)) continue;
        const log = fs.readFileSync(logPath, 'utf8');
        // Print known diagnostic markers only, never the log's credential-bearing values.
        const markers = log.match(/SecKeychain\w*|errSec\w+|keychain|vault|supervisor-control|permission denied|address already in use|file name too long|no such file|connection refused|timed out|panic/gi) || [];
        console.log('    P5 log markers:', file, Buffer.byteLength(log), JSON.stringify(markers.slice(-60)));
      }
      const status = readJson(path.join(L5.state, 'runtime-status.json'));
      console.log('    P5 runtime status:', JSON.stringify(status && { pid: status.pid, connected: status.connected, updated_at: status.updated_at }));
    }
    expect(r.status === 0, `the installer re-run exits 0 (exit ${r.status})\n${r.stdout}${r.stderr}`);
    await assertConverted(acct, L5, 'P5');
    expect(runtimePid(L5) !== pidBefore, 'P5: the supervised runtime replaced the legacy process');
  });
}

// ---- a live agent (PTY shell) on the profile's PTY daemon, as bridge_lifecycle_e2e's restart probe ----------

function ptySocket(L, bridgeId) {
  const intended = `${L.data}/run/pty-host-${bridgeId}.sock`;
  if (Buffer.byteLength(intended) <= 103) return intended;
  let hash = 14695981039346656037n;
  for (const b of Buffer.from(intended)) hash = BigInt.asUintN(64, (hash ^ BigInt(b)) * 1099511628211n);
  const tmp = WIN ? os.tmpdir() : ENV.TMPDIR?.startsWith('/') ? ENV.TMPDIR.replace(/\/+$/, '') : '/tmp';
  return `${tmp}/${WIN ? 'heimdall-run' : `heimdall-${process.getuid()}`}/${hash.toString(16).padStart(16, '0')}.sock`;
}
async function startAgent(acct, L) {
  const sessionId = `sh_${crypto.randomBytes(16).toString('hex')}`;
  const pub = await http(acct, 'GET', `/api/v1/bridges/${L.bridgeId}/public-key`);
  const keyring = await importKeyring(Uint8Array.from(acct.keyringBytes), acct.userId);
  const enc_spec = await encryptVaultText(JSON.stringify({ cmd: '', cwd: HOME, timestamp: Date.now(), nonce: crypto.randomBytes(16).toString('hex'),
    bridge_id: L.bridgeId, session_id: sessionId, kind: 'shell', boot_id: pub.data.unseal_boot_id }), keyring);
  const created_ = await http(acct, 'POST', `/api/v1/bridges/${L.bridgeId}/shells`, { body: { session_id: sessionId, kind: 'shell', enc_spec } });
  expect(created_.status === 201 || created_.status === 200, `live agent shell accepted (${created_.status} ${created_.raw})`);
  const ptyBin = path.join(path.dirname(L.bin), `ham-pty-host${EXE}`);
  const socket = ptySocket(L, L.bridgeId);
  const pid = () => {
    const listed = spawnSync(ptyBin, ['--socket', socket, 'list'], { env: ENV, encoding: 'utf8', timeout: 5000 });
    const row = String(listed.stdout || '').split('\n').find((l) => l.startsWith(sessionId));
    return listed.status === 0 && row?.includes('alive') ? Number(/pid=(\d+)/.exec(row)?.[1] || 0) : 0;
  };
  const originalPid = await until(() => pid(), 'the agent shell to start on the PTY daemon', 60_000, 200);
  return { originalPid, pid, close: async () => { await http(acct, 'DELETE', `/api/v1/shells/${sessionId}`); spawnSync(ptyBin, ['--socket', socket, 'stop'], { env: ENV, timeout: 5000 }); } };
}

// ---- cleanup ------------------------------------------------------------------------------------------------

function cleanup() {
  try { fs.rmSync(TEST_ENV_FILE, { force: true }); } catch { /* gone */ }
  for (const L of profiles) {
    // A converted instance uninstalls through its own tree; a legacy one through bin/.
    const bins = [path.join(L.data, 'bin', `ham-bridge${EXE}`), NEW_BRIDGE].filter((b) => fs.existsSync(b));
    for (const b of bins) { if (spawnSync(b, ['uninstall', '--service', L.service, '--purge', '--yes', '--headless'], { env: ENV, timeout: 120_000 }).status === 0) break; }
    for (const p of [L.state, L.data, L.unit].filter(Boolean)) { try { fs.rmSync(p, { recursive: true, force: true }); } catch { /* gone */ } }
  }
  if (!WIN && !MAC) spawnSync('systemctl', ['--user', 'daemon-reload']);
}

try {
  await main();
} catch (err) {
  results.push(['setup', 'FAIL']);
  console.log(`FAIL setup: ${err?.stack || err}`);
} finally {
  for (const c of children) { try { c.kill(); } catch { /* gone */ } }
  await sleep(500);
  cleanup();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { console.log(`(could not remove ${ROOT})`); }
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failed = results.filter(([, r]) => r === 'FAIL').length;
console.log(failed ? `${failed} step(s) FAILED` : 'all steps PASSED');
process.exitCode = failed ? 1 : 0;
