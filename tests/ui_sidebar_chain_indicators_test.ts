// REQ-CHAIN-UI-SIDEBAR-1: Unit Tests for Sidebar Chain Indicators and Filter Icon
//
// RUN: node --test tests/ui_sidebar_chain_indicators_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// 1. Persistence Tests for Sidebar Chain Filter
test('clientPersistence defines sidebar chain filter key and functions', async () => {
  const persistenceFile = path.join(REPO_ROOT, 'src/ui/utils/clientPersistence.ts');
  assert.ok(fs.existsSync(persistenceFile), 'clientPersistence.ts must exist');

  const content = fs.readFileSync(persistenceFile, 'utf8');

  // Verify key and function definitions
  assert.match(content, /SIDEBAR_CHAIN_FILTER_KEY\s*=\s*['"]heimdall:sidebar-chain-filter['"]/, 'SIDEBAR_CHAIN_FILTER_KEY must be heimdall:sidebar-chain-filter');
  assert.match(content, /export function readSidebarChainFilter/, 'readSidebarChainFilter must be exported');
  assert.match(content, /export function writeSidebarChainFilter/, 'writeSidebarChainFilter must be exported');

  // Test functional persistence behavior with a mock localStorage
  const mockStorage: Record<string, string> = {};
  (globalThis as any).window = {
    localStorage: {
      getItem: (key: string) => mockStorage[key] ?? null,
      setItem: (key: string, val: string) => { mockStorage[key] = String(val); },
      removeItem: (key: string) => { delete mockStorage[key]; },
    },
  };

  const { readSidebarChainFilter, writeSidebarChainFilter, SIDEBAR_CHAIN_FILTER_KEY } = await import(
    '../src/ui/utils/clientPersistence.ts'
  );

  assert.equal(SIDEBAR_CHAIN_FILTER_KEY, 'heimdall:sidebar-chain-filter');

  // Default to 'all' when empty
  delete mockStorage['heimdall:sidebar-chain-filter'];
  assert.equal(readSidebarChainFilter(), 'all', 'readSidebarChainFilter should default to all');

  // Write 'active' and read back
  writeSidebarChainFilter('active');
  assert.equal(mockStorage['heimdall:sidebar-chain-filter'], 'active');
  assert.equal(readSidebarChainFilter(), 'active', 'readSidebarChainFilter should return active');

  // Write 'all' and read back
  writeSidebarChainFilter('all');
  assert.equal(mockStorage['heimdall:sidebar-chain-filter'], 'all');
  assert.equal(readSidebarChainFilter(), 'all', 'readSidebarChainFilter should return all');

  // Support legacy or alternate 'active-only' value
  mockStorage['heimdall:sidebar-chain-filter'] = 'active-only';
  assert.equal(readSidebarChainFilter(), 'active', 'readSidebarChainFilter should normalize active-only to active');

  // Fallback to 'all' on unknown value
  mockStorage['heimdall:sidebar-chain-filter'] = 'unexpected_filter_value';
  assert.equal(readSidebarChainFilter(), 'all', 'readSidebarChainFilter should fallback to all on unknown value');
});

// 2. Pure Filtering Logic Tests (filterSidebarChains)
test('filterSidebarChains correctly filters active, completed, and archived chains', async () => {
  const treeFile = path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx');
  assert.ok(fs.existsSync(treeFile), 'ProjectChainTree.tsx must exist');

  const { filterSidebarChains } = await import('../src/ui/utils/clientPersistence.ts');
  assert.equal(typeof filterSidebarChains, 'function', 'filterSidebarChains must be exported function');

  const mockChains: any[] = [
    { chainId: 'c1', title: 'Active Chain 1', status: 'active', projectId: 'p1' },
    { chainId: 'c2', title: 'Completed Chain 2', status: 'completed', projectId: 'p1' },
    { chainId: 'c3', title: 'Paused Chain 3', status: 'paused', projectId: 'p2' },
    { chainId: 'c4', title: 'Cancelled Chain 4', status: 'cancelled', projectId: 'p2' },
    { chainId: 'c5', title: 'Archived Chain 5', status: 'archived', projectId: 'p1' },
    { chainId: 'c6', title: 'Archived Flag Chain 6', status: 'active', archived: true, projectId: 'p1' },
    { chainId: 'c7', title: 'Archived Project Chain 7', status: 'active', projectId: 'p_archived' },
  ];

  const archivedProjects = new Set(['p_archived']);

  // Under 'all' filter: archived chains and archived projects should be excluded, all others kept
  const allFiltered = filterSidebarChains(mockChains, 'all', archivedProjects);
  const allIds = allFiltered.map((c: any) => c.chainId);
  assert.deepEqual(allIds, ['c1', 'c2', 'c3', 'c4'], 'all filter should exclude archived chains and projects, keeping active/completed/paused/cancelled');

  // Under 'active' filter: only non-archived active chains are kept
  const activeFiltered = filterSidebarChains(mockChains, 'active', archivedProjects);
  const activeIds = activeFiltered.map((c: any) => c.chainId);
  assert.deepEqual(activeIds, ['c1'], 'active filter should only include active chains');
});

// 3. ProjectChainTree Component Source Invariants
test('ProjectChainTree.tsx satisfies REQ-CHAIN-UI-SIDEBAR-1 UI requirements', () => {
  const treeFile = path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx');
  const content = fs.readFileSync(treeFile, 'utf8');

  // Acceptance Criterion 1: Filter icon present beside "Chains" header in sidebar
  assert.match(content, /data-debug-id="sidebar-chain-filter-btn"/, 'Filter button must have debug id');
  assert.match(content, /<Icon\s+name="filter"/, 'Filter button must render filter icon');

  // Acceptance Criterion 2: Switching filter between "All" and "Active only"
  assert.match(content, /data-debug-id="sidebar-chain-filter-option-all"/, 'Menu must have option for All chains');
  assert.match(content, /data-debug-id="sidebar-chain-filter-option-active"/, 'Menu must have option for Active only');
  assert.match(content, /data-debug-id="sidebar-chain-filter-badge"/, 'Active badge must be rendered when filter is applied');

  // Acceptance Criterion 3: Active chains with tasks display a subtle % progress indicator (SVG circular ring)
  assert.match(content, /data-debug-id="chain-progress-ring"/, 'Progress ring must have debug id');
  assert.match(content, /strokeDasharray=/, 'Progress ring must use strokeDasharray');
  assert.match(content, /strokeDashoffset=/, 'Progress ring must use strokeDashoffset');

  // Acceptance Criterion 4: Chains blocked on user validation display an amber alert indicator/badge
  assert.match(content, /data-debug-id="chain-user-validation-badge"/, 'User validation badge must have debug id');
  assert.match(content, /title="Awaiting user validation"/, 'User validation badge must have title="Awaiting user validation"');
  assert.match(content, /userValidationCount/, 'ChainRow must check userValidationCount or hasUserValidation');

  // Acceptance Criterion 5: Completed chains display a clear completed visual treatment
  assert.match(content, /data-debug-id="chain-completed-icon"/, 'Completed chain must have completed icon debug id');
  assert.match(content, /name="check"/, 'Completed chain must display checkmark icon');

  // Preservation: pinning up to 10 pinned chains and project collapse/expand
  assert.match(content, /pinnedChains\.length\s*>=\s*10/, 'Pinning limit of 10 must be preserved');
  assert.match(content, /collapsed/, 'Project collapse/expand state must be preserved');
});

// 4. Icon Primitive Invariants
test('Icon.tsx includes filter glyph in IconName and PATHS', () => {
  const iconFile = path.join(REPO_ROOT, 'src/ui/components/ui/primitives/Icon.tsx');
  const content = fs.readFileSync(iconFile, 'utf8');

  assert.match(content, /\|\s*'filter'/, 'IconName union must include filter');
  assert.match(content, /filter:\s*\(/, 'PATHS dictionary must define filter path');
});
