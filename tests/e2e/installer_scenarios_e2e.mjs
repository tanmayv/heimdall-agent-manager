// Installer scenarios e2e (T4, REQ-INSTALL-2, REQ-OS-1): the REAL bootstrap scripts
// (scripts/install.sh on Linux/macOS, scripts/install.ps1 on Windows) with a bundle
// built from the binaries under test, against a THROWAWAY hub (ephemeral port, temp
// DB, mock OIDC, approving browser simulated like /device/add). Every run is
// unattended: no controlling terminal (POSIX: own session; Windows: no console
// input) and stdin is never a terminal. One profile, in this order:
//   1 fresh install, piped like `curl | bash -s --` / `& ([scriptblock]::Create((irm …)))`:
//     the pairing code is approved, the service runs and the bridge connects (S1);
//   2 second run is a no-op: no pairing code, same bridge, same bridge process,
//     binaries and service definition untouched (S2);
//   3 enrollment removed (service stopped, credential deleted): the run re-enrolls
//     in place onto the same bridge id, keeps bin/ and the data dir (S3);
//   4 enrollment revoked on the hub: the running bridge parks and marks the profile;
//     the next run re-enrolls without --reenroll (S4, "hub changed" in place);
//   5 interrupted install (service stopped, bin/ moved away, leftover .staging, an
//     install lock of a dead pid): the run recovers without a new enrollment (S7);
//   6 `install.sh --uninstall --purge` / `install.ps1 -Uninstall --purge`: no profile
//     files, service registration or OS secret-store items of this run remain;
//  6b nor of the bridge step 4 replaced (iss_18eab23e79e956c8, fixed by T4b: the
//     re-enroll wipes it, uninstall --purge wipes any recorded predecessor).
// State rows: docs/specs/bridge-installer-contract.md §3.
//
// The service manager starts the bridge with the user's REAL home, so (like
// bridge_lifecycle_e2e.mjs with HEIMDALL_E2E_SERVICE=1) this uses the real home and
// is meant for ephemeral CI runners or a developer machine: every path, service
// and secret is named by this run's random profile and bridge ids and only those
// are removed. It never touches another bridge.
//
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_BRIDGE_BIN=<dir>/ham-bridge \
//   HEIMDALL_E2E_NATS_BIN=<nats-server> node tests/e2e/installer_scenarios_e2e.mjs
// <dir> must also hold ham-pty-host (ham-ctl / ham-wrapper are optional).

import { spawn as nodeSpawn, spawnSync as nodeSpawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { startNats } from './natsServer.mjs';
import { freePort, hubLogin, sessionHeaders, startMockOidc } from './hubOidc.mjs';
import { refuseLegacyInstall, scrubHeimdallEnv } from './realHomeGuard.mjs';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { buildBridgeApproval, buildGenesis, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, pairApproveMac } from '../../src/ui/utils/vaultPairing.ts';

// Background probes, including on a developer's Windows desktop.
const spawn = (command, args, options = {}) => nodeSpawn(command, args, { ...options, windowsHide: true });
const spawnSync = (command, args, options = {}) => nodeSpawnSync(command, args, { ...options, windowsHide: true });

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const BRIDGE_BIN = process.env.HEIMDALL_E2E_BRIDGE_BIN;
const WIN = process.platform === 'win32';
const MAC = process.platform === 'darwin';
const LINUX = !WIN && !MAC;
const results = [];
class CheckFailed extends Error {}
const expect = (cond, msg) => { if (!cond) throw new CheckFailed(msg); console.log(`    ok - ${msg}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// knownGap: an issue id. The step still runs and its result is printed, but a
// failure is reported as KNOWN-GAP (a GitHub Actions warning) and does not fail the
// run, until the fix lands and the step is made strict (or
// HEIMDALL_E2E_STRICT_KNOWN_GAPS=1 makes every known gap fail now).
const STRICT_GAPS = process.env.HEIMDALL_E2E_STRICT_KNOWN_GAPS === '1';
async function step(name, fn, { knownGap = '' } = {}) {
  console.log(`\n== ${name}${knownGap ? ` (known gap ${knownGap})` : ''}`);
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS ${name}`); }
  catch (err) {
    console.log(`    not ok - ${err instanceof CheckFailed ? err.message : (err?.stack || err)}`);
    if (knownGap && !STRICT_GAPS) {
      results.push([name, `KNOWN-GAP ${knownGap}`]);
      console.log(`KNOWN-GAP ${name} (${knownGap}; not failing the run)`);
      if (process.env.GITHUB_ACTIONS === 'true') console.log(`::warning title=Known installer gap ${knownGap}::${name}`);
    } else {
      results.push([name, 'FAIL']);
      console.log(`FAIL ${name}`);
    }
  }
}

// A shell the bridge spawned exports HEIMDALL_BRIDGE_SERVICE_NAME etc.; none of the
// caller's own bridge may reach the binaries under test.
scrubHeimdallEnv();
const ENV = { ...process.env };
const HOME = os.homedir();
refuseLegacyInstall(HOME);
if (WIN && (!ENV.APPDATA || !ENV.LOCALAPPDATA)) throw new Error('APPDATA/LOCALAPPDATA unset');
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-installer-e2e-'));
const children = [];
const CREATED = []; // every bridge id this run enrolled
const SCOPES = new Map();

const PROFILE_NAME = `inst${crypto.randomBytes(3).toString('hex')}`;
const STATE_ROOT = WIN ? path.join(ENV.APPDATA, 'heimdall', 'bridges') : path.join(HOME, '.config', 'heimdall', 'bridges');
let P = null; // this run's profile layout, once the hub port is known

// bridgesvc.canonical_hub + service_name + layout_for (src/lib/bridgesvc/bridgesvc.odin).
function profileLayout(hub, name) {
  const u = new URL(hub.base);
  const service = `heimdall-bridge-${u.hostname.replace(/[^a-z0-9-]/g, '-')}-${u.port}_${name}`;
  const data = WIN ? path.join(ENV.LOCALAPPDATA, 'heimdall', 'bridges', service) : path.join(HOME, '.local', 'share', 'heimdall', 'bridges', service);
  return {
    name,
    service,
    dir: path.join(STATE_ROOT, service),
    config: path.join(STATE_ROOT, service, 'config.toml'),
    token: path.join(STATE_ROOT, service, 'bridge-token'),
    marker: path.join(STATE_ROOT, service, 'needs-reenrollment.json'),
    lock: path.join(STATE_ROOT, service, '.install.lock'),
    status: path.join(STATE_ROOT, service, 'runtime-status.json'),
    data,
    bin: path.join(data, 'bin'),
    staging: path.join(data, '.staging'),
    serviceFile: WIN ? '' : MAC ? path.join(HOME, 'Library', 'LaunchAgents', `${service}.plist`) : path.join(HOME, '.config', 'systemd', 'user', `${service}.service`),
  };
}
const exe = (base) => (WIN ? `${base}.exe` : base);

// ---- throwaway hub and approving browser --------------------------------------

async function startHub() {
  const bin = process.env.HEIMDALL_E2E_HUB_BIN;
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
  const child = spawn(bin, ['--listen', `127.0.0.1:${port}`, '--db', path.join(dir, 'hub.db'), '--migrations-dir', migrations, '--ui-origin', base],
    // The hub must never offer the bridge an update during the run.
    { cwd: dir, env: { ...ENV, ...mock.hubEnv(base), ...nats.hubEnv, HEIMDALL_UPDATE_CATALOG_OFFLINE: '1', HEIMDALL_UPDATE_MANIFEST_PATH: path.join(dir, 'update-manifest.json') }, stdio: ['ignore', log, log] });
  children.push(child);
  for (const deadline = Date.now() + 30_000; ;) {
    try { if ((await fetch(`${base}/api/v1/health`)).ok) break; } catch { /* starting */ }
    if (Date.now() > deadline) throw new Error('the throwaway hub did not start');
    await sleep(150);
  }
  return { base, port };
}

async function http(acct, method, p, { body, headers = {} } = {}) {
  const h = { ...sessionHeaders(acct.session, acct.base), ...headers };
  const text = body === undefined ? undefined : JSON.stringify(body);
  if (text !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${acct.base}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, raw };
}

// One signed-in account with its approving browser (vault genesis, keyring).
async function account(hub, user) {
  const acct = { base: hub.base, session: await hubLogin(hub.base, user) };
  const userId = (await http(acct, 'GET', '/api/v1/me')).data.user_id;
  const identity = await createDeviceIdentity(memoryDeviceStore(), userId);
  const g = await http(acct, 'POST', '/api/v1/vault/directory/genesis', { body: await buildGenesis(identity, `installer e2e ${user}`) });
  if (g.status !== 201) throw new Error(`genesis ${g.status} ${g.raw}`);
  const signed = async (m, p) => signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, userId, m, p, '');
  const chain = async () => verifyDirectory((await http(acct, 'GET', '/api/v1/vault/directory')).data, userId, null);
  const self = await http(acct, 'GET', '/api/v1/vault/devices/self', { headers: await signed('GET', '/api/v1/vault/devices/self') });
  const parsed = await openVerifiedWrap(self.data.wrap, { userId, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chain() });
  const keyringBytes = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  return { ...acct, userId, identity, chain, keyringBytes };
}

const PAIRING_CODE = /^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m;

// Approve the pairing code the installer printed, like /device/add (code typed once,
// signed vault approval, first unseal with pair_mac). reuse: approve onto that id.
async function approve(hub, acct, run, { reuse = '' } = {}) {
  let code = null;
  for (const deadline = Date.now() + 90_000; !(code = (PAIRING_CODE.exec(run.out()) || [])[1]); await sleep(100)) {
    if (run.exitCode() !== null) throw new CheckFailed(`the installer exited (${run.exitCode()}) without a pairing code:\n${run.out()}`);
    if (Date.now() > deadline) throw new CheckFailed(`no pairing code printed:\n${run.out()}`);
  }
  const salts = await http(acct, 'POST', '/api/v1/device/pair-salts', { body: {} });
  const tried = [];
  for (const c of (salts.data?.candidates ?? []).filter((x) => x.kind === 'bridge')) {
    tried.push({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: c.pair_hub_origin, pairSalt: c.pair_salt }) });
  }
  const ver = await http(acct, 'POST', '/api/v1/device/verify', { body: { pair_lookups: tried.map((c) => c.keys.lookup) } });
  const keys = tried.find((c) => c.salt === ver.data?.pair_salt)?.keys;
  expect(ver.status === 200 && ver.data.kind === 'bridge' && keys, `the printed code resolves the enrolling bridge (${ver.status})`);
  await checkBridgeCodeInfo(ver.data, keys);
  const { vault_approval, statement } = await buildBridgeApproval(acct.identity, await acct.chain(), ver.data, P.service);
  const body = { pair_lookup: keys.lookup, approve: true, vault_approval, ...(reuse ? { target_bridge_id: reuse } : { new_bridge_label: 'installer-e2e' }) };
  const appr = await http(acct, 'POST', '/api/v1/device/approve', { body });
  const bridgeId = appr.data?.hub_observed?.bridge_id;
  expect(appr.status === 200 && bridgeId, `approved -> ${bridgeId} (${appr.status} ${appr.status === 200 ? '' : appr.raw})`);
  if (!CREATED.includes(bridgeId)) CREATED.push(bridgeId);
  SCOPES.set(bridgeId, `${bridgeId}_${crypto.createHash('sha256').update(`heimdall-bridge-scope/v1|${hub.base}|${bridgeId}`).digest('hex').slice(0, 32)}`);
  let target = null;
  for (const deadline = Date.now() + 60_000; ; await sleep(250)) {
    const pk = await http(acct, 'GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`);
    if (pk.status === 200 && pk.data?.unseal_key_signature) { target = bridgeUnsealTargetFromRecord(bridgeId, pk.data); break; }
    if (Date.now() > deadline) throw new CheckFailed(`the enrolling bridge never connected:\n${run.out()}`);
  }
  const after = await acct.chain();
  const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
  await deliverKeyringToBridge(bridgeId, after, {
    fetchTarget: async () => target,
    dispatch: async (id, payload) => {
      const r = await http(acct, 'POST', `/api/v1/bridges/${id}/unseal`, { body: payload });
      if (r.status !== 200 || r.data?.ok === false) throw new Error(`unseal refused: ${r.status} ${r.raw}`);
      return r.data;
    },
    withKeyringBytes: async (fn) => { const b = Uint8Array.from(acct.keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
  }, { enrollment: true, identityPublicKey: ver.data.bridge_identity_public_key, expectedPublicKey: target.publicKey, extra: { enrollment: true, expected_public_key: target.publicKey, pair_mac: pairMac } });
  return bridgeId;
}

async function bridgesOf(acct) {
  const r = await http(acct, 'GET', '/api/v1/bridges');
  return Array.isArray(r.data) ? r.data : (r.data?.bridges ?? []);
}
const isActive = (b) => !b.revoked_at && b.status !== 'revoked';
const isOnline = async (acct, id) => (await bridgesOf(acct)).some((b) => b.bridge_id === id && (b.status === 'online' || b.runtime_connected === true));
async function waitOnline(acct, id, what, ms = 90_000) {
  for (const deadline = Date.now() + ms; !(await isOnline(acct, id)); await sleep(500)) {
    if (Date.now() > deadline) throw new CheckFailed(`${what}: ${id} never came online`);
  }
}

// ---- the bundle and the installer ---------------------------------------------

// A release-shaped bundle of the binaries under test: heimdall-local-<target>-<tag>
// with bin/ham-bridge (+ siblings), and a SHA256SUMS naming it, as the release
// workflow publishes them. install.sh/ps1 verify it before running anything.
function buildBundle() {
  const arch = { x64: 'amd64', arm64: 'arm64' }[process.arch];
  const target = `${WIN ? 'windows' : MAC ? 'darwin' : 'linux'}-${arch}`;
  const stage = path.join(ROOT, 'bundle-stage');
  fs.mkdirSync(path.join(stage, 'bin'), { recursive: true });
  const src = path.dirname(BRIDGE_BIN);
  for (const base of ['ham-bridge', 'ham-pty-host', 'ham-ctl', 'ham-wrapper']) {
    const from = path.join(src, exe(base));
    if (!fs.existsSync(from)) { if (base === 'ham-bridge' || base === 'ham-pty-host') throw new Error(`${from} is missing`); continue; }
    fs.copyFileSync(from, path.join(stage, 'bin', exe(base)));
    fs.chmodSync(path.join(stage, 'bin', exe(base)), 0o755);
  }
  const name = `heimdall-local-${target}-v0.0.0-installer-e2e.${WIN ? 'zip' : 'tar.gz'}`;
  const archive = path.join(ROOT, name);
  const r = WIN
    ? spawnSync('powershell.exe', ['-NoProfile', '-Command', `Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory('${stage}', '${archive}')`], { encoding: 'utf8' })
    : spawnSync('tar', ['-czf', archive, '-C', stage, 'bin'], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`cannot pack the bundle: ${r.stdout}${r.stderr}`);
  const sums = path.join(ROOT, 'SHA256SUMS');
  fs.writeFileSync(sums, `${crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex')}  ${name}\n`);
  return { archive, sums, bridge: path.join(stage, 'bin', exe('ham-bridge')) };
}

// Run the bootstrap the way an operator's one-liner does, with no terminal:
//   piped: install.sh read from stdin (`curl … | bash -s -- …`) / install.ps1 as a
//          scriptblock (`& ([scriptblock]::Create((irm …))) …`);
//   else:  the script file.
// POSIX runs get their own session (detached), so there is no controlling terminal
// a prompt could open. Returns live accessors; await done for the exit code.
function installer(args, { piped = false } = {}) {
  let out = '';
  let code = null;
  let child;
  if (WIN) {
    const ps1 = path.join(REPO_ROOT, 'scripts', 'install.ps1');
    // Started from PowerShell 7 (the CI step's shell), Windows PowerShell 5.1 would
    // inherit pwsh's PSModulePath and fail to load its own modules (Get-FileHash
    // "not recognized"); an operator's 5.1 console has its default path.
    const psEnv = Object.fromEntries(Object.entries(ENV).filter(([k]) => k.toUpperCase() !== 'PSMODULEPATH'));
    // Parameter names stay bare: a quoted '-Hub' would bind as a positional string.
    const q = (s) => (/^-[A-Za-z]+$/.test(s) ? s : `'${String(s).replace(/'/g, "''")}'`);
    if (piped) {
      const cmd = `& ([scriptblock]::Create([IO.File]::ReadAllText(${q(ps1)}))) ${args.map(q).join(' ')}; exit $LASTEXITCODE`;
      child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', cmd], { cwd: ROOT, env: psEnv, stdio: ['ignore', 'pipe', 'pipe'] });
    } else {
      child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1, ...args], { cwd: ROOT, env: psEnv, stdio: ['ignore', 'pipe', 'pipe'] });
    }
  } else {
    const sh = path.join(REPO_ROOT, 'scripts', 'install.sh');
    const bash = process.env.INSTALLER_BASH || 'bash';
    child = piped
      ? spawn(bash, ['-s', '--', ...args], { cwd: ROOT, env: ENV, stdio: ['pipe', 'pipe', 'pipe'], detached: true })
      : spawn(bash, [sh, ...args], { cwd: ROOT, env: ENV, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    if (piped) child.stdin.end(fs.readFileSync(sh));
  }
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  const done = new Promise((resolve) => child.once('close', (c) => { code = c; resolve(c); }));
  return { out: () => out, exitCode: () => code, done };
}
async function finished(run, what, ms = 300_000) {
  const code = await Promise.race([run.done, sleep(ms).then(() => 'timeout')]);
  console.log(run.out().split('\n').map((l) => `      | ${l}`).join('\n'));
  if (code === 'timeout') throw new CheckFailed(`${what}: the installer did not finish in ${ms / 1000}s`);
  return code;
}

// The script-level flags for this run's bundle and profile (same names on both;
// install.ps1 takes -Bundle / -ChecksumFile / -Hub / -Profile / -Uninstall).
function installArgs(hub, bundle, extra = []) {
  return WIN
    ? ['-Bundle', bundle.archive, '-ChecksumFile', bundle.sums, '-Hub', hub.base, '-Profile', PROFILE_NAME, ...extra]
    : ['--bundle', bundle.archive, '--checksum-file', bundle.sums, '--hub', hub.base, '--profile', PROFILE_NAME, ...extra];
}

// ---- local observations ---------------------------------------------------------

const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const mtime = (p) => { try { return fs.statSync(p).mtimeMs; } catch { return 0; } };
// bridgesvc.credential_bridge_id: the last field of the credential header line.
const credentialId = () => {
  let line = '';
  try { line = fs.readFileSync(P.token, 'utf8').split('\n')[0].trim(); } catch { return ''; }
  const id = line.split(/\s+/).pop() || '';
  return id.startsWith('brg_') ? id : '';
};
function serviceRegistered() {
  if (WIN) return spawnSync('schtasks', ['/Query', '/TN', P.service], { encoding: 'utf8' }).status === 0;
  if (MAC) return spawnSync('launchctl', ['print', `gui/${process.getuid()}/${P.service}`]).status === 0;
  return spawnSync('systemctl', ['--user', 'list-unit-files', `${P.service}.service`], { encoding: 'utf8' }).stdout.includes(P.service);
}
function serviceDefinition() {
  if (P.serviceFile) return fs.existsSync(P.serviceFile) ? fs.readFileSync(P.serviceFile, 'utf8') : '';
  const q = spawnSync('schtasks', ['/Query', '/TN', P.service, '/XML'], { encoding: 'utf8' });
  return q.status === 0 ? q.stdout : '';
}
function bridgeService(verb) {
  const r = spawnSync(BRIDGE_BIN, ['service', verb, '--service', P.service], { env: ENV, encoding: 'utf8', timeout: 60_000 });
  expect(r.status === 0, `ham-bridge service ${verb} ${P.service} (exit ${r.status}) ${r.stdout}${r.stderr}`.trim());
}
// The bridge process is gone once runtime-status.json's pid no longer runs.
async function waitStopped() {
  for (const deadline = Date.now() + 30_000; ; await sleep(250)) {
    const pid = readJson(P.status)?.pid;
    let alive = false;
    if (pid) { try { process.kill(pid, 0); alive = true; } catch { alive = false; } }
    if (!alive) return;
    if (Date.now() > deadline) throw new CheckFailed(`bridge pid ${pid} still runs after service stop`);
  }
}
function deadPid() {
  const r = spawnSync(process.execPath, ['-e', '']);
  return r.pid;
}

// OS secret-store items named by one bridge id (keystore_<os>.odin).
function secretItems(bridgeId) {
  if (WIN) {
    const list = spawnSync('cmdkey', ['/list'], { encoding: 'utf8' }).stdout || '';
    return [...list.matchAll(/Target:\s*(?:LegacyGeneric:target=)?(\S+)/g)].map((m) => m[1])
      .filter((t) => t.startsWith('works.earendil.heimdall-bridge.') && t.includes(bridgeId));
  }
  if (MAC) {
    const found = [];
    for (const svc of ['vault-keyring', 'vault-identity', 'vault-epoch-floor', 'vault-identity-previous', 'vault-epoch-floor-previous']) {
      const r = spawnSync('security', ['find-generic-password', '-s', `works.earendil.heimdall-bridge.${svc}`, '-a', SCOPES.get(bridgeId) || bridgeId], { encoding: 'utf8' });
      if (r.status === 0) found.push(`${svc}:${bridgeId}`);
    }
    return found;
  }
  let keys = '';
  try { keys = fs.readFileSync('/proc/keys', 'utf8'); } catch { /* no procfs */ }
  return keys.split('\n').filter((l) => l.includes('heimdall:') && l.includes(bridgeId))
    .filter((l) => !/[RD]/.test(l.trim().split(/\s+/)[1] || ''));
}
const bridgeSecretDirs = (id) => (fs.existsSync(STATE_ROOT) ? fs.readdirSync(STATE_ROOT) : []).filter((d) => d === id || d.startsWith(`${id}_`));

// ---- scenarios ------------------------------------------------------------------

async function main() {
  if (!process.env.HEIMDALL_E2E_HUB_BIN || !BRIDGE_BIN) throw new Error('set HEIMDALL_E2E_HUB_BIN and HEIMDALL_E2E_BRIDGE_BIN');
  const hub = await startHub();
  P = profileLayout(hub, PROFILE_NAME);
  console.log(`throwaway hub ${hub.base}; profile ${PROFILE_NAME} (service ${P.service}); temp root ${ROOT}`);
  const A = await account(hub, 'installer-e2e');
  const bundle = buildBundle();
  const S = {};
  const noPairing = (run) => !PAIRING_CODE.test(run.out());

  await step('1 fresh install, piped and unattended, enrolls and starts the service (S1)', async () => {
    expect(!fs.existsSync(P.dir) && !fs.existsSync(P.data), 'nothing of this profile exists yet');
    const run = installer(installArgs(hub, bundle), { piped: true });
    S.id = await approve(hub, A, run);
    const code = await finished(run, 'fresh install');
    expect(code === 0, `the installer exits 0 (exit ${code})`);
    expect(run.out().includes(`Installed ${P.service} v`) && run.out().includes(`enrolled as ${S.id}, connected to ${hub.base}.`), 'final line: Installed … enrolled … connected');
    expect(fs.existsSync(path.join(P.bin, exe('ham-bridge'))) && fs.existsSync(path.join(P.bin, exe('ham-pty-host'))), 'bin/ holds the bundle binaries');
    expect(Buffer.compare(fs.readFileSync(path.join(P.bin, exe('ham-bridge'))), fs.readFileSync(bundle.bridge)) === 0, 'the installed ham-bridge is the verified bundle\'s');
    expect(credentialId() === S.id, 'the profile credential names the approved bridge');
    expect(serviceRegistered(), `the service ${P.service} is registered`);
    expect(!fs.existsSync(P.staging) && !fs.existsSync(P.lock), 'no staging dir or install lock is left');
    await waitOnline(A, S.id, 'installed service');
  });

  await step('2 second run is a no-op (S2)', async () => {
    const before = { status: readJson(P.status), bin: mtime(path.join(P.bin, exe('ham-bridge'))), unit: serviceDefinition(), config: fs.readFileSync(P.config, 'utf8'), token: fs.readFileSync(P.token, 'utf8') };
    expect(before.status?.pid > 0, `the service runs (pid ${before.status?.pid})`);
    const run = installer(installArgs(hub, bundle));
    const code = await finished(run, 'second run');
    expect(code === 0, `the installer exits 0 (exit ${code})`);
    expect(run.out().includes(`is already installed, enrolled as ${S.id} and connected; nothing changed.`), 'final line: already installed … nothing changed');
    expect(noPairing(run), 'no pairing code was printed (no enrollment)');
    expect(readJson(P.status)?.pid === before.status.pid, 'the same bridge process still runs (not restarted)');
    expect(mtime(path.join(P.bin, exe('ham-bridge'))) === before.bin, 'bin/ham-bridge was not rewritten');
    expect(serviceDefinition() === before.unit, 'the service definition is unchanged');
    expect(fs.readFileSync(P.config, 'utf8') === before.config && fs.readFileSync(P.token, 'utf8') === before.token, 'config and credential are unchanged');
    const active = (await bridgesOf(A)).filter(isActive);
    expect(active.length === 1 && active[0].bridge_id === S.id, `exactly one active bridge on the hub (${active.map((b) => b.bridge_id)})`);
    await waitOnline(A, S.id, 'after the no-op');
  });

  await step('3 enrollment removed: the run re-enrolls in place, keeping binaries and data (S3)', async () => {
    const keep = path.join(P.data, 'installer-e2e-keep.txt');
    fs.writeFileSync(keep, 'user data');
    const binBefore = mtime(path.join(P.bin, exe('ham-bridge')));
    bridgeService('stop');
    await waitStopped();
    for (const f of [P.token, `${P.token}.refresh`]) fs.rmSync(f, { force: true });
    expect(credentialId() === '', 'the credential is gone');
    const run = installer(installArgs(hub, bundle));
    const id = await approve(hub, A, run, { reuse: S.id });
    const code = await finished(run, 're-enroll');
    expect(code === 0, `the installer exits 0 (exit ${code})`);
    expect(id === S.id && credentialId() === S.id, `re-enrolled onto the same bridge ${S.id} (got ${id})`);
    expect(run.out().includes(`Enrolled ${P.service} as ${S.id}; connected to ${hub.base}.`), 'final line: Enrolled … connected');
    expect(mtime(path.join(P.bin, exe('ham-bridge'))) === binBefore, 'bin/ was kept (no reinstall)');
    expect(fs.readFileSync(keep, 'utf8') === 'user data', 'the data dir was kept');
    await waitOnline(A, S.id, 're-enrolled service');
  });

  await step('4 enrollment revoked on the hub: the next run re-enrolls without --reenroll (S4)', async () => {
    const rv = await http(A, 'POST', `/api/v1/bridges/${S.id}/revoke`, { body: {} });
    expect(rv.status === 200, `the hub revokes ${S.id} (${rv.status} ${rv.status === 200 ? '' : rv.raw})`);
    for (const deadline = Date.now() + 120_000; !fs.existsSync(P.marker); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed(`the running bridge never marked the profile (${P.marker})`);
    }
    expect(readJson(P.marker)?.reason === 'revoked' || fs.readFileSync(P.marker, 'utf8').includes('revoked'), 'the marker names reason revoked');
    const run = installer(installArgs(hub, bundle));
    const id = await approve(hub, A, run);
    const code = await finished(run, 're-enroll after revoke');
    expect(code === 0, `the installer exits 0 (exit ${code})`);
    expect(run.out().includes(`Re-enrolled ${P.service} (was ${S.id}, reason revoked) as ${id}; connected.`), 'final line: Re-enrolled … (was …, reason revoked)');
    expect(credentialId() === id && !fs.existsSync(P.marker), 'the new credential is saved and the marker cleared');
    S.id = id;
    await waitOnline(A, S.id, 're-enrolled service after revoke');
  });

  await step('5 interrupted install recovers without a new enrollment (S7)', async () => {
    bridgeService('stop');
    await waitStopped();
    // The states an install killed between Stage and Binaries leaves (setup.odin
    // Partial_Install / Stale_Lock): bin/ moved aside, a half-written staging dir, and
    // the lock of the setup process that died.
    fs.renameSync(P.bin, path.join(P.data, 'bin.bak-e2e'));
    fs.mkdirSync(P.staging, { recursive: true });
    fs.writeFileSync(path.join(P.staging, exe('ham-bridge')), 'partial');
    fs.writeFileSync(P.lock, `${deadPid()} ${Math.floor(Date.now() / 1000)}\n`);
    const run = installer(installArgs(hub, bundle));
    const code = await finished(run, 'recovery');
    expect(code === 0, `the installer exits 0 (exit ${code})`);
    expect(run.out().includes(`Recovered an interrupted install of ${P.service}:`), 'final line: Recovered an interrupted install …');
    expect(noPairing(run), 'no pairing code was printed (credential kept)');
    expect(Buffer.compare(fs.readFileSync(path.join(P.bin, exe('ham-bridge'))), fs.readFileSync(bundle.bridge)) === 0, 'bin/ was reinstalled from the verified bundle');
    expect(!fs.existsSync(P.staging) && !fs.existsSync(P.lock), 'staging dir and stale lock are gone');
    expect(credentialId() === S.id, 'the credential was kept');
    await waitOnline(A, S.id, 'recovered service');
    // bin.bak-e2e stays: on Windows the PTY daemon (it outlives service restarts by
    // design) still runs from it. Step 6's uninstall --purge must remove it too.
  });

  await step('6 uninstall through the installer leaves nothing of the profile', async () => {
    const run = installer(installArgs(hub, bundle, WIN ? ['-Uninstall', '--purge', '--yes'] : ['--uninstall', '--purge', '--yes']));
    const code = await finished(run, 'uninstall', 180_000);
    expect(code === 0, `the installer exits 0 (exit ${code})`);
    // The Windows uninstall re-executes from %TEMP% and returns first; let it finish.
    for (const deadline = Date.now() + 60_000; (fs.existsSync(P.dir) || fs.existsSync(P.data)) && Date.now() < deadline; await sleep(500));
    expect(!fs.existsSync(P.dir), `profile state dir removed (${P.dir})`);
    expect(!fs.existsSync(P.data), `profile data dir removed (${P.data})`);
    if (P.serviceFile) expect(!fs.existsSync(P.serviceFile), `service file removed (${P.serviceFile})`);
    expect(!serviceRegistered(), 'the service is no longer registered');
    if (LINUX) expect(spawnSync('systemctl', ['--user', 'is-active', `${P.service}.service`], { encoding: 'utf8' }).stdout.trim() !== 'active', 'the systemd user service is not running');
    expect(secretItems(S.id).length === 0, `no OS secret-store item of the installed bridge ${S.id} (${secretItems(S.id)})`);
    expect(bridgeSecretDirs(S.id).length === 0, `no per-bridge secret dir of ${S.id} (${bridgeSecretDirs(S.id)})`);
    const active = (await bridgesOf(A)).filter(isActive).map((b) => b.bridge_id);
    expect(active.length === 1 && active[0] === S.id, `the bridge stays on the hub, not revoked (uninstall never revokes) (${active})`);
  });

  // Step 4 re-enrolled onto a NEW bridge id (the revoked one cannot be reused).
  // Nothing of the revoked predecessor may stay on the machine either.
  await step('6b nothing of the revoked predecessor bridge remains after re-enroll + uninstall', async () => {
    const old = CREATED.filter((id) => id !== S.id);
    expect(old.length > 0, `step 4 enrolled a new bridge (${CREATED})`);
    const left = old.flatMap((id) => [...secretItems(id).map((i) => `secret-store ${i.trim()}`), ...bridgeSecretDirs(id).map((d) => `dir ${path.join(STATE_ROOT, d)}`)]);
    expect(left.length === 0, `no OS secret-store item or secret dir of ${old} remains${left.length ? `:\n      ${left.join('\n      ')}` : ''}`);
  });
}

// On failure: remove this run's service, files and secret-store items (named by its
// own profile and bridge ids only).
function cleanup() {
  if (!P) return;
  spawnSync(BRIDGE_BIN, ['uninstall', '--service', P.service, '--purge', '--yes', '--headless'], { env: ENV, timeout: 60_000 });
  for (const id of CREATED) {
    for (const item of secretItems(id)) {
      if (WIN) spawnSync('cmdkey', [`/delete:${item}`]);
      else if (MAC) { const [svc] = item.split(':'); spawnSync('security', ['delete-generic-password', '-s', `works.earendil.heimdall-bridge.${svc}`, '-a', SCOPES.get(id) || id]); }
      else { const kid = item.trim().split(/\s+/)[0]; spawnSync('keyctl', ['unlink', `0x${kid}`, '@u']); }
    }
    for (const d of bridgeSecretDirs(id)) { try { fs.rmSync(path.join(STATE_ROOT, d), { recursive: true, force: true }); } catch { /* gone */ } }
  }
  for (const p of [P.dir, P.data, P.serviceFile].filter(Boolean)) { try { fs.rmSync(p, { recursive: true, force: true }); } catch { /* gone */ } }
  if (LINUX) { spawnSync('systemctl', ['--user', 'daemon-reload']); spawnSync('systemctl', ['--user', 'reset-failed', `${P.service}.service`]); }
}

try {
  await main();
} catch (err) {
  results.push(['setup', 'FAIL']);
  console.log(`FAIL setup: ${err?.stack || err}`);
} finally {
  // A known gap leaves this run's secrets behind too: clean up on anything but PASS.
  const failed = results.some(([, r]) => r !== 'PASS');
  if (failed) {
    const log = path.join(ROOT, 'hub', 'hub.log');
    if (process.env.HEIMDALL_E2E_SHOW_HUB_LOG === '1' && fs.existsSync(log)) console.log(fs.readFileSync(log, 'utf8').split('\n').slice(-80).join('\n'));
    cleanup();
  }
  for (const c of children) { try { c.kill(); } catch { /* gone */ } }
  await sleep(500);
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { console.log(`(could not remove ${ROOT})`); }
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failedCount = results.filter(([, r]) => r === 'FAIL').length;
const gaps = results.filter(([, r]) => r.startsWith('KNOWN-GAP')).length;
console.log(failedCount ? `${failedCount} step(s) FAILED` : `all installer scenarios PASSED${gaps ? ` (${gaps} known gap(s) reported above)` : ''}`);
process.exitCode = failedCount ? 1 : 0;
