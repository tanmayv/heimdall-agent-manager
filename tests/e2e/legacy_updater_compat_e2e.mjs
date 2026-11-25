// Legacy updater compatibility contract (P2-6, REQ-CONV-3, REQ-OS-1).
//
// The first supervisor release must be installable by the updater that is ALREADY in
// the field, with nothing changed in old binaries (docs/specs/bridge-supervisor-conversion.md
// §1, §11). This drives the REAL released `ham-bridge update --auto-worker` of v0.5.77 and
// of the newest legacy release (the same code the bridge's timer spawns) against a stub
// "new bundle" (tools/legacy_update_stub) and asserts what the new setup will be handed:
//   * the preflight `--version` runs and a newer stub is accepted;
//   * setup argv is exactly update_setup_argv's: `setup --hub H [--profile P] --headless
//     [--reinstall] [--json-progress]`, with `--reinstall` absent for v0.5.77 and present
//     for later builds (S10 converts either way: src/lib/bridgesvc/convert_test.odin);
//   * setup runs under the worker's own detached stdio (no terminal), while the worker
//     holds the user-wide ~/.heimdall-auto-update.lock: a second automatic worker is
//     refused for as long as setup runs, and the worker waits with no timeout;
//   * after setup returns the worker's late bookkeeping (<state>/auto-update.json) is
//     written, success or failure, and nothing else in the instance is touched.
// The old fetch is hard-wired to api.github.com, so --bundle is the seam (the fetch half
// is the asset-name invariant in scripts/release tests). Everything lives in a throwaway
// HOME; no service manager is touched, nothing is converted here (see P2-7 for that).
//
//   HEIMDALL_E2E_STUB_BIN=<legacy_update_stub[.exe]> node tests/e2e/legacy_updater_compat_e2e.mjs
//   HEIMDALL_E2E_LEGACY_TAGS=v0.5.77,v0.5.86   (default)  HEIMDALL_E2E_CACHE=<download cache>

import { spawn } from 'node:child_process';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { scrubHeimdallEnv } from './realHomeGuard.mjs';

scrubHeimdallEnv();

// Releases before the migration to the releases repo (v0.5.77 among them) live only in
// the source repo; newer ones are dual-published. Try both, in this order.
const RELEASE_BASES = ['tanmayv/heimdall-releases', 'tanmayv/heimdall-agent-manager'].map((r) => `https://github.com/${r}/releases/download`);
const STUB = process.env.HEIMDALL_E2E_STUB_BIN;
const WIN = process.platform === 'win32';
const EXE = WIN ? '.exe' : '';
const TAGS = (process.env.HEIMDALL_E2E_LEGACY_TAGS || 'v0.5.77,v0.5.86').split(',').map((s) => s.trim()).filter(Boolean);
const CACHE = process.env.HEIMDALL_E2E_CACHE || path.join(os.tmpdir(), 'heimdall-legacy-bundles');
const HOLD_MS = 6000;
const HUB = 'https://hub.example.com';
// Which builds pass --reinstall (update_setup_argv): v0.5.77 does not, every later one does.
const NO_REINSTALL = new Set(['v0.5.77']);
// v0.5.77 predates the worker's outcome text (T16c): it logs nothing and writes no last_result.
const NO_OUTCOME_TEXT = new Set(['v0.5.77']);

const failures = [];
const check = (ok, what) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
  if (!ok) failures.push(what);
};
const eq = (got, want, what) => check(JSON.stringify(got) === JSON.stringify(want), `${what}${JSON.stringify(got) === JSON.stringify(want) ? '' : ` (got ${JSON.stringify(got)}, want ${JSON.stringify(want)})`}`);

function target() {
  const arch = process.arch === 'arm64' ? 'arm64' : 'amd64';
  if (process.platform === 'linux') return `linux-${arch}`;
  if (process.platform === 'darwin') return `darwin-${arch}`;
  if (WIN) return 'windows-amd64';
  throw new Error(`unsupported platform ${process.platform}`);
}

async function get(url) {
  const res = await fetch(url, { redirect: 'follow', headers: { 'user-agent': 'heimdall-e2e' } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

// The real legacy ham-bridge of a release, SHA-256 verified against the release's SHA256SUMS.
async function legacyBridge(tag) {
  const dir = path.join(CACHE, `${tag}-${target()}`);
  const exe = path.join(dir, 'bin', `ham-bridge${EXE}`);
  if (fs.existsSync(exe)) return exe;
  const name = `heimdall-local-${target()}-${tag}${WIN ? '.zip' : '.tar.gz'}`;
  let base = '';
  let sums = '';
  for (const candidate of RELEASE_BASES) {
    try {
      sums = (await get(`${candidate}/${tag}/SHA256SUMS`)).toString('utf8');
      base = candidate;
      break;
    } catch { /* next repo */ }
  }
  if (!base) throw new Error(`${tag}: no SHA256SUMS in ${RELEASE_BASES.join(' or ')}`);
  const line = sums.split(/\r?\n/).filter((l) => l.trim().endsWith(` ${name}`) || l.trim().endsWith(`*${name}`));
  if (line.length !== 1) throw new Error(`${tag}: SHA256SUMS lists ${name} ${line.length} times`);
  const body = await get(`${base}/${tag}/${name}`);
  const digest = crypto.createHash('sha256').update(body).digest('hex');
  if (digest !== line[0].trim().split(/\s+/)[0].toLowerCase()) throw new Error(`${name}: digest mismatch`);
  fs.mkdirSync(dir, { recursive: true });
  const archive = path.join(dir, name);
  fs.writeFileSync(archive, body);
  const r = spawnSync('tar', ['-xf', archive, '-C', dir], { encoding: 'utf8', windowsHide: true });
  if (r.status !== 0) throw new Error(`cannot unpack ${name}: ${r.stderr}`);
  for (const cand of [exe, path.join(dir, `ham-bridge${EXE}`)]) if (fs.existsSync(cand)) return cand;
  throw new Error(`${name} has no bin/ham-bridge${EXE}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(cond, what, ms = 30000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (cond()) return true;
    await sleep(100);
  }
  check(false, `timed out waiting for ${what}`);
  return false;
}

function worker(bin, env, args, tag) {
  const out = fs.openSync(path.join(env.HOME, `${tag}.out`), 'w');
  const child = spawn(bin, args, { env, stdio: ['ignore', out, out], windowsHide: true });
  const done = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal, at: Date.now() })));
  return { child, done, log: () => fs.readFileSync(path.join(env.HOME, `${tag}.out`), 'utf8') };
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

async function scenario(tag, oldBin, { setupExit, profile, jsonProgress }) {
  const label = `${tag} setup_exit=${setupExit}${profile ? ` profile=${profile}` : ''}`;
  console.log(`\n== ${label}`);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-compat-'));
  const service = `heimdall-bridge-compat${profile ? `_${profile}` : ''}`;
  const env = {
    ...process.env, HOME: home, USERPROFILE: home,
    APPDATA: path.join(home, 'AppData', 'Roaming'), LOCALAPPDATA: path.join(home, 'AppData', 'Local'),
    STUB_VERSION: '99.0.0', STUB_HOLD_MS: String(HOLD_MS), STUB_EXIT: String(setupExit),
  };
  const stateDir = WIN ? path.join(env.APPDATA, 'heimdall', 'bridges', service) : path.join(home, '.config', 'heimdall', 'bridges', service);
  const dataDir = WIN ? path.join(env.LOCALAPPDATA, 'heimdall', 'bridges', service) : path.join(home, '.local', 'share', 'heimdall', 'bridges', service);
  const installed = path.join(dataDir, 'bin', `ham-bridge${EXE}`);
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    fs.mkdirSync(path.dirname(installed), { recursive: true });
    fs.copyFileSync(oldBin, installed);
    fs.chmodSync(installed, 0o755);
    fs.writeFileSync(path.join(stateDir, 'hub-url'), `${HUB}\n`);
    if (profile) fs.writeFileSync(path.join(stateDir, 'profile'), `${profile}\n`);
    fs.writeFileSync(path.join(stateDir, 'config.toml'), '[bridge]\nauto_update_enabled = true\n');
    const bundle = path.join(home, 'bundle', 'bin');
    fs.mkdirSync(bundle, { recursive: true });
    fs.copyFileSync(STUB, path.join(bundle, `ham-bridge${EXE}`));
    fs.chmodSync(path.join(bundle, `ham-bridge${EXE}`), 0o755);
    const binBefore = fs.readFileSync(installed);
    const record = path.join(home, 'setup-record.json');
    const args = ['update', '--bundle', path.join(home, 'bundle'), '--service', service, '--auto-worker'];
    if (jsonProgress) args.push('--json-progress');

    const w1 = worker(installed, { ...env, STUB_RECORD: record }, args, 'worker1');
    const started = Date.now();
    if (!(await until(() => fs.existsSync(record), 'the old worker to run the new setup'))) {
      console.log(`worker output:\n${w1.log()}`);
      w1.child.kill();
      return;
    }
    const rec = readJson(record);
    const wantArgv = ['setup', '--hub', HUB];
    if (profile) wantArgv.push('--profile', profile);
    wantArgv.push('--headless');
    if (!NO_REINSTALL.has(tag)) wantArgv.push('--reinstall');
    if (jsonProgress) wantArgv.push('--json-progress');
    eq(rec && rec.argv, wantArgv, `${label}: setup argv is update_setup_argv's`);
    check(rec && rec.argv.includes('--reinstall') === !NO_REINSTALL.has(tag), `${label}: --reinstall ${NO_REINSTALL.has(tag) ? 'absent (S8b shape)' : 'present'}`);
    eq(rec && [rec.stdin_tty, rec.stdout_tty, rec.stderr_tty], [false, false, false], `${label}: setup has no terminal`);
    check(fs.existsSync(path.join(home, '.heimdall-auto-update.lock')), `${label}: the user-wide auto-update lock file exists while setup runs`);

    // The worker holds the lock for as long as setup runs: a second automatic worker is refused.
    const probeRecord = path.join(home, 'probe-record.json');
    const w2 = worker(installed, { ...env, STUB_RECORD: probeRecord }, args, 'worker2');
    const second = await w2.done;
    check(second.code !== 0 && !fs.existsSync(probeRecord), `${label}: a second automatic worker is refused while setup runs (exit ${second.code})`);
    check(w1.child.exitCode === null, `${label}: the first worker is still waiting for setup`);

    // Wait forever: the worker returns only after setup does, with setup's verdict.
    const first = await w1.done;
    check(first.at - started >= HOLD_MS - 500, `${label}: the worker waited for setup (${first.at - started} ms)`);
    eq(first.code === 0, setupExit === 0, `${label}: the worker's exit follows setup's (${first.code})`);
    if (!NO_OUTCOME_TEXT.has(tag)) check(w1.log().includes(setupExit === 0 ? 'succeeded' : 'failed'), `${label}: the worker reports ${setupExit === 0 ? 'success' : 'failure'}`);

    // Late bookkeeping, written after setup returned.
    const state = readJson(path.join(stateDir, 'auto-update.json'));
    check(!!state, `${label}: <state>/auto-update.json written after setup`);
    if (state) {
      eq(state.pending_version || '', '', `${label}: pending_version cleared`);
      if (setupExit === 0) {
        eq(state.failures || 0, 0, `${label}: failures 0`);
        if (!NO_OUTCOME_TEXT.has(tag)) check(/succeeded/.test(state.last_result || ''), `${label}: last_result records success`);
      } else {
        check((state.failures || 0) >= 1, `${label}: failures counted for the old backoff`);
        if (!NO_OUTCOME_TEXT.has(tag)) check(/failed/.test(state.last_result || ''), `${label}: last_result records the failure`);
      }
      check((state.next_check_ms || 0) > Date.now(), `${label}: next check scheduled`);
    }
    check(Buffer.compare(fs.readFileSync(installed), binBefore) === 0, `${label}: the worker itself never touched bin/ham-bridge`);
    // The lock was the worker's: released at exit (the kernel/handle), so a third worker may run.
    const w3 = worker(installed, { ...env, STUB_RECORD: path.join(home, 'third.json'), STUB_HOLD_MS: '0', STUB_EXIT: '0' }, args, 'worker3');
    const third = await w3.done;
    eq(third.code === 0 || fs.existsSync(path.join(home, 'third.json')), true, `${label}: the lock is free again after the worker exits`);
  } finally {
    fs.rmSync(home, { recursive: true, force: true, maxRetries: 5 });
  }
}

async function main() {
  if (!STUB || !fs.existsSync(STUB)) throw new Error('HEIMDALL_E2E_STUB_BIN must name the built tools/legacy_update_stub binary');
  if (process.platform === 'darwin' && process.arch !== 'arm64') {
    console.log('skip: no legacy macOS Intel bundle exists');
    return;
  }
  for (const tag of TAGS) {
    const oldBin = await legacyBridge(tag);
    const v = spawnSync(oldBin, ['--version'], { encoding: 'utf8', windowsHide: true });
    check(v.status === 0 && v.stdout.includes(tag.replace(/^v/, '')), `${tag}: real legacy binary runs: ${(v.stdout || '').trim()}`);
    await scenario(tag, oldBin, { setupExit: 0, profile: '', jsonProgress: false });
    await scenario(tag, oldBin, { setupExit: 1, profile: 'work', jsonProgress: true });
  }
  if (failures.length) {
    console.error(`\n${failures.length} check(s) failed`);
    process.exit(1);
  }
  console.log('\nlegacy updater compatibility contract holds');
}

main().catch((e) => { console.error(e); process.exit(1); });
