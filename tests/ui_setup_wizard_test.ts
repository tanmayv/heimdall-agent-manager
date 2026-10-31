// First-run setup wizard (/setup, desktop app): the pure model
// (components/setup/setupWizardModel.ts) and past-session project discovery
// (components/setup/sessionProjects.ts).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_setup_wizard_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const model = await import('../src/ui/components/setup/setupWizardModel.ts');
const sessions = await import('../src/ui/components/setup/sessionProjects.ts');
const { initialWizard, reduceWizard, startWizard } = await import('../src/ui/bridge/desktopBridge.ts');

const reusable = [
  { bridge_id: 'brg_riverwood', label: 'riverwood', machine_hostname: 'mac.local', status: 'online', last_seen: '' },
  { bridge_id: 'brg_dawnstar', label: 'dawnstar', machine_hostname: 'dawnstar', status: 'online', last_seen: '' },
];
const bridges = [
  { bridge_id: 'brg_riverwood', label: 'riverwood', machine_hostname: 'mac.local', status: 'online' },
  { bridge_id: 'brg_dawnstar', label: 'dawnstar', machine_hostname: 'dawnstar', status: 'offline' },
  { bridge_id: 'brg_old', label: 'old', status: 'revoked', revoked_at: '2026-01-01T00:00:00Z' },
];

test('rail: connected machines show install and identity as done', () => {
  const fresh = model.setupRail('install', false);
  assert.deepEqual(fresh.map((r) => r.state), ['done', 'current', 'todo', 'todo', 'todo']);
  const connected = model.setupRail('agents', true);
  assert.deepEqual(connected.map((r) => r.state), ['done', 'done', 'done', 'current', 'todo']);
  assert.equal(connected[1].hint, 'Already done');
  assert.equal(model.setupRail('machine', true)[1].state, 'done');
});

test('install rows fold ham-bridge steps into Download, Install, Pair', () => {
  let w = startWizard();
  w = reduceWizard(w, { type: 'progress', step: 'download', state: 'ok', message: 'downloaded' });
  w = reduceWizard(w, { type: 'progress', step: 'ports', state: 'start', message: 'bridge 49325' });
  let rows = model.installRows(w);
  assert.deepEqual(rows.map((r) => [r.id, r.state]), [['download', 'ok'], ['install', 'running'], ['pair', 'pending']]);
  w = reduceWizard(w, { type: 'progress', step: 'service', state: 'ok' });
  w = reduceWizard(w, { type: 'progress', step: 'enroll', state: 'start' });
  w = reduceWizard(w, { type: 'pairing', url: 'https://hub/device/add', code: 'ABCD-EFGH-JKLM-NP' });
  rows = model.installRows(w);
  assert.equal(rows[1].state, 'ok');
  assert.equal(rows[2].state, 'running');
  assert.match(rows[2].message, /bridge identity/);
  assert.equal(model.installRows(initialWizard())[0].state, 'pending');
  assert.equal(model.installRowStatus('failed'), 'Failed');
});

test('sunset candidates exclude revoked bridges', () => {
  assert.deepEqual(model.sunsetCandidates(bridges).map((b) => b.bridge_id), ['brg_riverwood', 'brg_dawnstar']);
  assert.deepEqual(model.sunsetCandidates([{ bridge_id: 'not-a-bridge' }]), []);
});

test('identity plan: reuse needs a listed bridge', () => {
  const candidates = model.sunsetCandidates(bridges);
  const none = model.identityPlan(model.EMPTY_IDENTITY_CHOICE, reusable, candidates, true);
  assert.equal(none.ok, false);
  const reuse = model.identityPlan({ mode: 'reuse', reuseId: 'brg_riverwood', sunsetId: '' }, reusable, candidates, true);
  assert.equal(reuse.ok, true);
  assert.equal(reuse.reuse?.bridge_id, 'brg_riverwood');
  assert.equal(reuse.sunset, null);
  assert.equal(reuse.action, 'Use riverwood and finish');
  const unlisted = model.identityPlan({ mode: 'reuse', reuseId: 'brg_other', sunsetId: '' }, reusable, candidates, true);
  assert.equal(unlisted.ok, false);
});

test('identity plan: a new bridge at capacity needs a bridge to sunset', () => {
  const candidates = model.sunsetCandidates(bridges);
  const roomy = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: '' }, reusable, candidates, false);
  assert.equal(roomy.ok, true);
  assert.equal(roomy.sunset, null);
  const full = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: '' }, reusable, candidates, true);
  assert.equal(full.ok, false);
  assert.equal(full.action, 'Choose a bridge to sunset');
  const sunset = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: 'brg_dawnstar' }, reusable, candidates, true);
  assert.equal(sunset.ok, true);
  assert.equal(sunset.reuse, null);
  assert.equal(sunset.sunset?.bridge_id, 'brg_dawnstar');
  assert.equal(sunset.action, 'Register and sunset dawnstar');
  const revoked = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: 'brg_old' }, reusable, candidates, true);
  assert.equal(revoked.ok, false);
});

test('update badge needs an installable artifact', () => {
  assert.equal(model.bridgeHasUpdate({ update_available: true }), true);
  assert.equal(model.bridgeHasUpdate({ update_available: true, update_artifact_available: false }), false);
  assert.equal(model.bridgeHasUpdate(null), false);
});

test('setup is remembered per account', () => {
  const store = new Map<string, string>();
  const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); } };
  assert.equal(model.setupSeen('usr_a', storage), false);
  model.markSetupSeen('usr_a', storage);
  assert.equal(model.setupSeen('usr_a', storage), true);
  assert.equal(model.setupSeen('usr_b', storage), false);
  assert.equal(model.setupSeen('', storage), true, 'no account: never redirect');
});

// --- past-session projects -------------------------------------------------

function fakeFs(dirs: string[], listings: Record<string, { name: string; is_dir: boolean }[]> = {}) {
  const set = new Set(dirs);
  let stats = 0;
  return {
    get stats() { return stats; },
    stat: async (path: string) => { stats += 1; return { ok: true, exists: set.has(path), is_dir: set.has(path) }; },
    list: async (path: string) => (listings[path] ? { ok: true, path: path.replace('~', '/home/me'), entries: listings[path] } : null),
  };
}

test('parse Claude project folder names', () => {
  assert.deepEqual(sessions.parseClaudeProjectDir('-home-me-app'), { root: '/', sep: '/', tokens: ['home', 'me', 'app'] });
  assert.deepEqual(sessions.parseClaudeProjectDir('C--Users-me-app'), { root: 'C:\\', sep: '\\', tokens: ['Users', 'me', 'app'] });
  assert.equal(sessions.parseClaudeProjectDir('memory'), null);
});

test('resolve an ambiguous name against folders that exist', async () => {
  const fs = fakeFs(['/home', '/home/me', '/home/me/code', '/home/me/code/heimdall-agent-manager', '/home/me/code/heimdall']);
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me-code-heimdall-agent-manager', fs.stat), '/home/me/code/heimdall-agent-manager');
  const dotted = fakeFs(['/home', '/home/me', '/home/me/.config', '/home/me/.config/nvim', '/home/me/site.io']);
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me--config-nvim', dotted.stat), '/home/me/.config/nvim');
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me-site-io', dotted.stat), '/home/me/site.io');
  const win = fakeFs(['C:\\Users', 'C:\\Users\\me', 'C:\\Users\\me\\my_app']);
  assert.equal(await sessions.resolveClaudeProjectDir('C--Users-me-my-app', win.stat), 'C:\\Users\\me\\my_app');
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me-gone', fs.stat), '');
});

test('resolution gives up after a bounded number of stats', async () => {
  const fs = fakeFs([]);
  const name = '-' + Array.from({ length: 30 }, (_, i) => `p${i}`).join('-');
  assert.equal(await sessions.resolveClaudeProjectDir(name, fs.stat), '');
  assert.ok(fs.stats <= 48, `stats: ${fs.stats}`);
});

test('discover projects with sessions, skip ones already in Ninjy', async () => {
  const root = '/home/me/.claude/projects';
  const fs = fakeFs(['/home', '/home/me', '/home/me/app', '/home/me/blog', '/home/me/empty'], {
    '~/.claude/projects': [
      { name: '-home-me-app', is_dir: true },
      { name: '-home-me-blog', is_dir: true },
      { name: '-home-me-empty', is_dir: true },
      { name: '-home-me-gone', is_dir: true },
      { name: 'notes.txt', is_dir: false },
    ],
    [`${root}/-home-me-app`]: [{ name: 'a.jsonl', is_dir: false }, { name: 'b.jsonl', is_dir: false }],
    [`${root}/-home-me-blog`]: [{ name: 'c.jsonl', is_dir: false }],
    [`${root}/-home-me-empty`]: [],
    [`${root}/-home-me-gone`]: [{ name: 'd.jsonl', is_dir: false }],
  });
  const found = await sessions.discoverClaudeProjects(fs);
  assert.deepEqual(found.map((p) => [p.name, p.path, p.sessions]), [['app', '/home/me/app', 2], ['blog', '/home/me/blog', 1]]);
  const fresh = sessions.newProjectsOnly(found, [{ bridge_paths: [{ bridge_id: 'brg_1', path: '/home/me/app/' }] }], 'brg_1');
  assert.deepEqual(fresh.map((p) => p.name), ['blog']);
  assert.equal(sessions.newProjectsOnly(found, [{ bridge_paths: [{ bridge_id: 'brg_2', path: '/home/me/app' }] }], 'brg_1').length, 2);
  assert.deepEqual(await sessions.discoverClaudeProjects(fakeFs([])), []);
});

test('identity step: a sunset rides on the approval, never a revoke up front (REQ-3)', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(new URL('../src/ui/components/setup/SetupWizardPage.tsx', import.meta.url), 'utf8');
  // No UI-side revoke: the hub retires the bridge atomically with the approval.
  assert.doesNotMatch(source, /useRevokeBridgeMutation|revokeBridge\(/);
  assert.match(source, /await approveBridgeEnrollment\(\{[\s\S]*?target: plan\.reuse,[\s\S]*?sunset: sunset \? \{ bridge_id: sunset\.bridge_id, label: sunset\.label \} : null,/);
  // A failure before the hub approved says nothing changed; after, that the sunset is final.
  assert.match(source, /Nothing was changed and \$\{sunset\.label\} is still active\./);
  assert.match(source, /was sunset when the hub approved this machine, but finishing enrollment failed/);
  // The warning describes atomic semantics.
  assert.match(source, /data-debug-id="setup-identity-sunset-warning"/);
  assert.match(source, /It is revoked in the same step that approves this machine, never before: if the approval is refused or fails, it keeps working\./);
});
