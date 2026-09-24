// REQ-SEARCH-UI-PANEL-1, REQ-SEARCH-SHORTCUTS-1: executable unit tests for Scoped Search logic.
//
// RUN:  node --test tests/ui_scoped_search_test.ts
// (Node 24 strips TypeScript types natively — no test runner, no dependency, no
// build step. The module under test imports nothing; see src/ui/search/scopedSearchLogic.ts.)

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeFsPath,
  deduplicateSearchScopes,
  deduplicateScopeResultsByRoot,
  globToRegExp,
  matchesFilePattern,
  transformSearchQuery,
  type FsSearchScope,
} from '../src/ui/search/scopedSearchLogic.ts';

// -----------------------------------------------------------------------------
// normalizeFsPath
// -----------------------------------------------------------------------------

test('normalizeFsPath handles empty, null and undefined paths', () => {
  assert.equal(normalizeFsPath(''), '');
  assert.equal(normalizeFsPath(undefined), '');
  assert.equal(normalizeFsPath('   '), '');
});

test('normalizeFsPath converts backslashes to forward slashes', () => {
  assert.equal(normalizeFsPath('C:\\Users\\test\\repo'), 'C:/Users/test/repo');
  assert.equal(normalizeFsPath('src\\ui\\components'), 'src/ui/components');
});

test('normalizeFsPath collapses duplicate slashes and strips trailing slashes', () => {
  assert.equal(normalizeFsPath('/home/user//project///'), '/home/user/project');
  assert.equal(normalizeFsPath('/repo/'), '/repo');
  assert.equal(normalizeFsPath('/'), '/');
});

// -----------------------------------------------------------------------------
// deduplicateSearchScopes
// -----------------------------------------------------------------------------

test('deduplicateSearchScopes preserves disjoint scopes on the same bridge', () => {
  const scopes: FsSearchScope[] = [
    {
      id: 'primary',
      label: 'Primary Project',
      kind: 'primary',
      path: '/home/user/workspace/repo-a',
      bridgeId: 'brg_local',
      scopeArgs: { projectId: 'p1' },
    },
    {
      id: 'chain_dir_1',
      label: 'Chain Dir 1',
      kind: 'chain_directory',
      path: '/home/user/workspace/repo-b',
      bridgeId: 'brg_local',
      scopeArgs: { chainId: 'c1', directoryId: 'd1' },
    },
  ];

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  assert.equal(activeScopes.length, 2);
  assert.equal(deduplicatedOut.length, 0);
  assert.equal(activeScopes[0].id, 'primary');
  assert.equal(activeScopes[1].id, 'chain_dir_1');
});

test('deduplicateSearchScopes removes nested subtrees when parent scope is present', () => {
  const scopes: FsSearchScope[] = [
    {
      id: 'primary',
      label: 'Project Root',
      kind: 'primary',
      path: '/usr/local/home/tanmay/heimdall',
      bridgeId: 'brg_123',
      scopeArgs: { projectId: 'p1' },
    },
    {
      id: 'chain_docs',
      label: 'Docs Dir',
      kind: 'chain_directory',
      path: '/usr/local/home/tanmay/heimdall/docs',
      bridgeId: 'brg_123',
      scopeArgs: { chainId: 'c1', directoryId: 'd_docs' },
    },
    {
      id: 'chain_packages',
      label: 'Packages Core',
      kind: 'chain_directory',
      path: '/usr/local/home/tanmay/heimdall/packages/core',
      bridgeId: 'brg_123',
      scopeArgs: { chainId: 'c1', directoryId: 'd_core' },
    },
  ];

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  assert.equal(activeScopes.length, 1);
  assert.equal(activeScopes[0].id, 'primary');
  assert.equal(deduplicatedOut.length, 2);
  assert.deepEqual(
    deduplicatedOut.map((s) => s.id).sort(),
    ['chain_docs', 'chain_packages'].sort()
  );
});

test('deduplicateSearchScopes subsumes child when parent scope is added after child', () => {
  const scopes: FsSearchScope[] = [
    {
      id: 'child_dir',
      label: 'Child Dir',
      kind: 'chain_directory',
      path: '/home/tanmay/project/submodule',
      bridgeId: 'brg_local',
      scopeArgs: { chainId: 'c1', directoryId: 'd_sub' },
    },
    {
      id: 'parent_dir',
      label: 'Parent Dir',
      kind: 'primary',
      path: '/home/tanmay/project',
      bridgeId: 'brg_local',
      scopeArgs: { projectId: 'p1' },
    },
  ];

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  assert.equal(activeScopes.length, 1);
  assert.equal(activeScopes[0].id, 'parent_dir');
  assert.equal(deduplicatedOut.length, 1);
  assert.equal(deduplicatedOut[0].id, 'child_dir');
});

test('deduplicateSearchScopes drops exact duplicate paths on the same bridge', () => {
  const scopes: FsSearchScope[] = [
    {
      id: 'scope_1',
      label: 'Project Alias 1',
      kind: 'primary',
      path: '/home/tanmay/repo',
      bridgeId: 'brg_local',
      scopeArgs: { projectId: 'p1' },
    },
    {
      id: 'scope_2',
      label: 'Project Alias 2',
      kind: 'chain_directory',
      path: '/home/tanmay/repo/',
      bridgeId: 'brg_local',
      scopeArgs: { chainId: 'c1', directoryId: 'd2' },
    },
  ];

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  assert.equal(activeScopes.length, 1);
  assert.equal(activeScopes[0].id, 'scope_1');
  assert.equal(deduplicatedOut.length, 1);
  assert.equal(deduplicatedOut[0].id, 'scope_2');
});

test('deduplicateSearchScopes does NOT deduplicate identical paths across different bridges', () => {
  const scopes: FsSearchScope[] = [
    {
      id: 'host_a_root',
      label: 'Host A Root',
      kind: 'primary',
      path: '/tmp/work',
      bridgeId: 'brg_host_a',
      scopeArgs: { projectId: 'p1', bridgeId: 'brg_host_a' },
    },
    {
      id: 'host_b_root',
      label: 'Host B Root',
      kind: 'chain_directory',
      path: '/tmp/work',
      bridgeId: 'brg_host_b',
      scopeArgs: { chainId: 'c1', directoryId: 'd1', bridgeId: 'brg_host_b' },
    },
  ];

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  assert.equal(activeScopes.length, 2);
  assert.equal(deduplicatedOut.length, 0);
});

test('deduplicateSearchScopes preserves scopes with missing path', () => {
  const scopes: FsSearchScope[] = [
    {
      id: 'agent_run_1',
      label: 'Agent 1 Run Dir',
      kind: 'agent_run_dir',
      path: '',
      bridgeId: 'brg_local',
      scopeArgs: { agentInstanceId: 'inst_1' },
    },
    {
      id: 'primary',
      label: 'Primary Project',
      kind: 'primary',
      path: '/home/user/repo',
      bridgeId: 'brg_local',
      scopeArgs: { projectId: 'p1' },
    },
  ];

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  assert.equal(activeScopes.length, 2);
  assert.equal(deduplicatedOut.length, 0);
});

// -----------------------------------------------------------------------------
// globToRegExp and matchesFilePattern
// -----------------------------------------------------------------------------

test('matchesFilePattern accepts all files when pattern is empty', () => {
  assert.equal(matchesFilePattern('src/ui/App.tsx', ''), true);
  assert.equal(matchesFilePattern('src/ui/App.tsx', '  '), true);
  assert.equal(matchesFilePattern('src/ui/App.tsx', undefined), true);
});

test('matchesFilePattern filters with positive extension globs', () => {
  const pattern = '*.tsx, *.ts';
  assert.equal(matchesFilePattern('src/ui/App.tsx', pattern), true);
  assert.equal(matchesFilePattern('src/utils/math.ts', pattern), true);
  assert.equal(matchesFilePattern('src/styles/app.css', pattern), false);
  assert.equal(matchesFilePattern('README.md', pattern), false);
});

test('matchesFilePattern excludes files with negative pattern', () => {
  const pattern = '!*.test.ts, !*.spec.tsx';
  assert.equal(matchesFilePattern('src/components/Button.tsx', pattern), true);
  assert.equal(matchesFilePattern('src/components/Button.spec.tsx', pattern), false);
  assert.equal(matchesFilePattern('tests/unit.test.ts', pattern), false);
});

test('matchesFilePattern handles combined include and exclude patterns', () => {
  const pattern = '*.ts, !*.test.ts';
  assert.equal(matchesFilePattern('src/index.ts', pattern), true);
  assert.equal(matchesFilePattern('src/index.test.ts', pattern), false);
  assert.equal(matchesFilePattern('src/index.tsx', pattern), false);
});

test('matchesFilePattern handles directory path globs', () => {
  const pattern = 'src/**/*.ts';
  assert.equal(matchesFilePattern('src/ui/components/Panel.ts', pattern), true);
  assert.equal(matchesFilePattern('scripts/deploy.ts', pattern), false);
});

// -----------------------------------------------------------------------------
// transformSearchQuery
// -----------------------------------------------------------------------------

test('transformSearchQuery escapes regex special characters when regex=false', () => {
  assert.equal(transformSearchQuery('foo.bar', { regex: false }), 'foo\\.bar');
  assert.equal(transformSearchQuery('fn(arg: int)', { regex: false }), 'fn\\(arg: int\\)');
  assert.equal(transformSearchQuery('array[0]', { regex: false }), 'array\\[0\\]');
  assert.equal(transformSearchQuery('$variable', { regex: false }), '\\$variable');
  assert.equal(transformSearchQuery('a+b*c?', { regex: false }), 'a\\+b\\*c\\?');
});

test('transformSearchQuery preserves regex expressions when regex=true', () => {
  assert.equal(transformSearchQuery('foo.*bar', { regex: true }), 'foo.*bar');
  assert.equal(transformSearchQuery('\\d{3}-\\d{4}', { regex: true }), '\\d{3}-\\d{4}');
  assert.equal(transformSearchQuery('^function\\s+\\w+', { regex: true }), '^function\\s+\\w+');
});

test('transformSearchQuery wraps word boundaries when wholeWord=true', () => {
  assert.equal(transformSearchQuery('hello', { regex: false, wholeWord: true }), '\\bhello\\b');
  assert.equal(transformSearchQuery('myVar123', { regex: false, wholeWord: true }), '\\bmyVar123\\b');
});

test('transformSearchQuery combines regex and wholeWord options', () => {
  assert.equal(transformSearchQuery('get[A-Z]\\w+', { regex: true, wholeWord: true }), '\\bget[A-Z]\\w+\\b');
});

test('transformSearchQuery handles non-word characters at query boundaries with wholeWord', () => {
  // Query starting with '$' shouldn't add leading '\b' because '$' is not a word char
  const res = transformSearchQuery('$count', { regex: false, wholeWord: true });
  assert.equal(res, '\\$count\\b');
});

// -----------------------------------------------------------------------------
// deduplicateScopeResultsByRoot
// -----------------------------------------------------------------------------

test('deduplicateScopeResultsByRoot removes nested agent run dir inside project root on same bridge', () => {
  const results = [
    {
      scope: {
        id: 'primary',
        label: 'Project Root',
        kind: 'primary' as const,
        bridgeId: 'brg_1',
        scopeArgs: { projectId: 'p1' },
      },
      root: '/home/tanmay/repo',
      matches: [],
    },
    {
      scope: {
        id: 'agent_run_1',
        label: 'Agent Run Dir',
        kind: 'agent_run_dir' as const,
        bridgeId: 'brg_1',
        scopeArgs: { agentInstanceId: 'inst_1' },
      },
      root: '/home/tanmay/repo/.agents/inst_1',
      matches: [],
    },
  ];

  const { activeResults, subsumedScopes } = deduplicateScopeResultsByRoot(results);
  assert.equal(activeResults.length, 1);
  assert.equal(activeResults[0].scope.id, 'primary');
  assert.equal(subsumedScopes.length, 1);
  assert.equal(subsumedScopes[0].id, 'agent_run_1');
});

test('deduplicateScopeResultsByRoot preserves disjoint roots on same bridge', () => {
  const results = [
    {
      scope: {
        id: 'primary',
        label: 'Project Root',
        kind: 'primary' as const,
        bridgeId: 'brg_1',
        scopeArgs: { projectId: 'p1' },
      },
      root: '/home/tanmay/repo',
      matches: [],
    },
    {
      scope: {
        id: 'chain_dir_2',
        label: 'Chain Dir 2',
        kind: 'chain_directory' as const,
        bridgeId: 'brg_1',
        scopeArgs: { chainId: 'c1', directoryId: 'd2' },
      },
      root: '/tmp/other/checkout',
      matches: [],
    },
  ];

  const { activeResults, subsumedScopes } = deduplicateScopeResultsByRoot(results);
  assert.equal(activeResults.length, 2);
  assert.equal(subsumedScopes.length, 0);
});

test('deduplicateScopeResultsByRoot does NOT deduplicate nested paths across different bridges', () => {
  const results = [
    {
      scope: {
        id: 'primary',
        label: 'Project Root',
        kind: 'primary' as const,
        bridgeId: 'bridge_a',
        scopeArgs: { projectId: 'p1' },
      },
      root: '/home/tanmay/repo',
      matches: [],
    },
    {
      scope: {
        id: 'agent_run_1',
        label: 'Agent Run Dir',
        kind: 'agent_run_dir' as const,
        bridgeId: 'bridge_b',
        scopeArgs: { agentInstanceId: 'inst_1' },
      },
      root: '/home/tanmay/repo/.agents/inst_1',
      matches: [],
    },
  ];

  const { activeResults, subsumedScopes } = deduplicateScopeResultsByRoot(results);
  assert.equal(activeResults.length, 2);
  assert.equal(subsumedScopes.length, 0);
});

test('deduplicateScopeResultsByRoot subsumes exact duplicate roots on same bridge prioritizing primary', () => {
  const results = [
    {
      scope: {
        id: 'primary',
        label: 'Project Root',
        kind: 'primary' as const,
        bridgeId: 'brg_1',
        scopeArgs: { projectId: 'p1' },
      },
      root: '/home/tanmay/repo',
      matches: [],
    },
    {
      scope: {
        id: 'alias_dir',
        label: 'Alias Dir',
        kind: 'chain_directory' as const,
        bridgeId: 'brg_1',
        scopeArgs: { chainId: 'c1', directoryId: 'd_alias' },
      },
      root: '/home/tanmay/repo/',
      matches: [],
    },
  ];

  const { activeResults, subsumedScopes } = deduplicateScopeResultsByRoot(results);
  assert.equal(activeResults.length, 1);
  assert.equal(activeResults[0].scope.id, 'primary');
  assert.equal(subsumedScopes.length, 1);
  assert.equal(subsumedScopes[0].id, 'alias_dir');
});

