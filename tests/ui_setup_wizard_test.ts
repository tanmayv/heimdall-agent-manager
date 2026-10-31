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

test('project list records load detail mappings before filtering on the selected bridge', async () => {
  // GET /projects uses write_project_json: no bridge_paths on list records.
  const list = { projects: [
    { project_id: 'proj_here', name: 'app', default_path: '/home/me/app' },
    { project_id: 'proj_elsewhere', name: 'other', default_path: '/home/me/other' },
  ] };
  const requests: string[] = [];
  const mappings = await sessions.loadProjectBridgeMappings(list.projects, async (id) => {
    requests.push(id);
    // GET /projects/{id} returns project plus top-level bridge_paths.
    return { project: list.projects.find((p) => p.project_id === id), bridge_paths: [
      { bridge_id: id === 'proj_here' ? 'brg_here' : 'brg_other', path: id === 'proj_here' ? '/home/me/app/' : '/home/me/other' },
    ] };
  });
  const found = ['app', 'other'].map((name) => ({ name, path: '/home/me/' + name, sessions: 1, source: 'Codex' as const }));
  assert.deepEqual(requests.sort(), ['proj_elsewhere', 'proj_here']);
  assert.deepEqual(sessions.newProjectsOnly(found, mappings, 'brg_here').map((p) => p.name), ['other']);
  assert.deepEqual(await sessions.loadProjectBridgeMappings([], async () => { throw new Error('unexpected request'); }), []);
});

test('mapping lookup failure prevents unsafe import candidates', async () => {
  const list = [{ project_id: 'proj_1' }];
  await assert.rejects(sessions.loadProjectBridgeMappings(list, async () => { throw new Error('offline'); }), /offline/);
  await assert.rejects(sessions.loadProjectBridgeMappings(list, async () => ({ project: list[0] })), /Could not check/);
  assert.deepEqual(await sessions.loadProjectBridgeMappings(list, async () => ({ project: { ...list[0], bridge_paths: [] } })), [{ bridge_paths: [] }]);
});

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
  // The failure copy is decided from the bridge list refetched after the failure,
  // never from how far the client got (a POST can commit and still throw).
  assert.doesNotMatch(source, /Nothing was changed/);
  assert.doesNotMatch(source, /approvedId/);
  assert.match(source, /const refreshed = await refetchBridges\(\)\.unwrap\(\)[\s\S]*?prefix = sunsetFailureNote\(sunset, refreshed\);/);
  // The warning matches the hub: restored on any rollback of the pending enrollment,
  // final only once this machine is enrolled.
  assert.match(source, /data-debug-id="setup-identity-sunset-warning"/);
  assert.match(source, /It is paused in the same step that approves this machine, never before\. If the approval is refused or this machine does not finish enrolling, its credentials are restored unless its plan slot is used meanwhile\. It reconnects on its next retry after restoration; an unfinished enrollment expires after 5 minutes\. Once this machine is enrolled, retirement is permanent/);
  assert.doesNotMatch(source, /if the approval is refused or fails, it keeps working/);
});

test('sunset failure note reads the refetched bridge list (REQ-3)', () => {
  const sunset = { bridge_id: 'brg_dawnstar', label: 'dawnstar' };
  // Approval refused, or rolled back and restored by the hub: still listed as active.
  assert.equal(model.sunsetFailureNote(sunset, bridges), 'dawnstar is still active. ');
  // The POST threw on the client but committed on the hub (lost response, proxy 5xx
  // after commit, or no bridge id in the answer): the list shows it revoked, so the
  // note must NOT claim nothing changed.
  const committed = bridges.map((b) => (b.bridge_id === 'brg_dawnstar' ? { ...b, status: 'revoked', revoked_at: '2026-10-31T12:00:00Z' } : b));
  const pending = model.sunsetFailureNote(sunset, committed);
  assert.match(pending, /^dawnstar is retired while this approval is pending\./);
  assert.match(pending, /comes back on its next retry after the enrollment is cancelled or expires/);
  assert.match(pending, /Pending enrollments expire after 5 minutes/);
  assert.doesNotMatch(pending, /within 5 minutes|still active|Nothing was changed/);
  // Gone from the list entirely reads the same as revoked.
  assert.match(model.sunsetFailureNote(sunset, bridges.filter((b) => b.bridge_id !== 'brg_dawnstar')), /^dawnstar is retired/);
  // The refetch itself failed: the outcome is unknown, and the note says so.
  const unknown = model.sunsetFailureNote(sunset, null);
  assert.match(unknown, /^Could not check whether dawnstar is still active; see Bridges\./);
  assert.doesNotMatch(unknown, /is still active\. $/);
});

test('session metadata: resolve Claude, merge Codex cwd, sort by newest session', async () => {
  const fs = fakeFs(['/home', '/home/me', '/home/me/app', '/home/me/blog']);
  const found = await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Claude Code', path: '-home-me-app', sessions: 2, last_session_at: '2026-10-28T10:00:00Z' },
    { source: 'Codex', path: '/home/me/app', sessions: 3, last_session_at: '2026-10-31T10:00:00Z' },
    { source: 'Codex', path: '/home/me/blog', sessions: 10, last_session_at: '2026-10-30T10:00:00Z' },
    { source: 'Codex', path: '/home/me/gone', sessions: 2, last_session_at: '2026-10-31T11:00:00Z' },
    { source: 'Claude Code', path: 'invalid', sessions: 1, last_session_at: 'bad' },
  ] }, fs);
  assert.deepEqual(found.map((p) => [p.path, p.sessions, p.source, p.lastSessionAt]), [
    ['/home/me/app', 5, 'Claude Code + Codex', '2026-10-31T10:00:00Z'],
    ['/home/me/blog', 10, 'Codex', '2026-10-30T10:00:00Z'],
  ]);
});

test('session metadata: empty, failed, malformed and inaccessible history', async () => {
  const fs = fakeFs(['/home', '/home/me', '/home/me/app']);
  assert.deepEqual(await sessions.discoverSessionProjects({ ok: true, projects: [] }, fs), []);
  await assert.rejects(sessions.discoverSessionProjects({ ok: false, projects: [] }, fs), /Could not read/);
  const rows = await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Codex', path: '/home/me/app', sessions: 1, last_session_at: 'invalid' },
    null as any,
    { source: 'Other' as any, path: '/home/me/app', sessions: 4, last_session_at: '' },
  ] }, fs);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].lastSessionAt, undefined);
  assert.equal(sessions.sessionTimeLabel(rows[0].lastSessionAt), 'Last session unknown');
  assert.match(sessions.sessionTimeLabel('2026-10-31T10:00:00Z'), /^Last session .+2026/);
  assert.deepEqual(await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Codex', path: '/home/me/app', sessions: 1, last_session_at: '' },
  ] }, { ...fs, stat: async () => { throw new Error('unreadable'); } }), []);
});

test('import names reserve existing names and same-basename folders', () => {
  const taken = new Set(['app', 'app (2)', 'blog']);
  assert.equal(sessions.reserveProjectName('app', taken), 'app (3)');
  assert.equal(sessions.reserveProjectName('app', taken), 'app (4)');
  assert.equal(sessions.reserveProjectName('Blog', taken), 'Blog (2)');
});

test('project deduplication is scoped to bridge paths', () => {
  const found = [{ name: 'app', path: '/home/me/app', sessions: 1, source: 'Codex' as const }];
  assert.equal(sessions.newProjectsOnly(found, [{ default_path: '/home/me/app', bridge_paths: [{ bridge_id: 'brg_other', path: '/home/me/app' }] }], 'brg_here').length, 1);
});

test('import retries only attach failed rows and preserve unique names and default paths', async () => {
  const chosen = [
    { name: 'app', path: '/home/me/app', sessions: 1, source: 'Codex' as const },
    { name: 'app', path: '/work/app', sessions: 2, source: 'Codex' as const },
  ];
  const created: import('../src/ui/components/setup/sessionProjects.ts').ImportedSessionProjects = {};
  const creations: [string, string][] = [];
  const attachments: [string, string][] = [];
  let fail = true;
  const api = {
    create: async (name: string, path: string) => { creations.push([name, path]); return 'project-' + creations.length; },
    attach: async (id: string, path: string) => {
      attachments.push([id, path]);
      if (fail && path === '/work/app') throw new Error('bridge disconnected');
    },
    errorText: (err: unknown) => (err as Error).message,
  };
  const first = await sessions.importSessionProjects(chosen, ['app'], created, api);
  assert.deepEqual(creations, [['app (2)', '/home/me/app'], ['app (3)', '/work/app']]);
  assert.deepEqual([...first.imported], ['/home/me/app']);
  assert.deepEqual(first.errors, { '/work/app': 'bridge disconnected' });
  fail = false;
  const retry = await sessions.importSessionProjects(chosen.filter((p) => first.errors[p.path]), ['app'], created, api);
  assert.equal(creations.length, 2, 'retry reuses the created project');
  assert.deepEqual(attachments.at(-1), ['project-2', '/work/app']);
  assert.deepEqual([...retry.imported], ['/work/app']);
  assert.deepEqual(retry.errors, {});
});

test('create failures remain visible per row without preventing other imports', async () => {
  const chosen = [
    { name: 'bad', path: '/bad', sessions: 1, source: 'Codex' as const },
    { name: 'good', path: '/good', sessions: 1, source: 'Codex' as const },
  ];
  const result = await sessions.importSessionProjects(chosen, [], {}, {
    create: async (_name, path) => path === '/bad' ? '' : 'id-good',
    attach: async () => {},
    errorText: (err) => (err as Error).message,
  });
  assert.match(result.errors['/bad'], /did not return.*project id/);
  assert.deepEqual([...result.imported], ['/good']);
});
