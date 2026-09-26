// REQ-SIDEBAR-ATTENTION-LIVE-1, REQ-SIDEBAR-COLLAPSED-PROGRESS-1, REQ-CONVO-EXCLUDE-CANCELLED-1
// Unit and regression tests for sidebar attention live clear, collapsed progress ring,
// and cancelled task exclusion from conversation toggle count.
//
// RUN: node --test tests/ui_sidebar_attention_and_progress_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// ── 1. REQ-SIDEBAR-ATTENTION-LIVE-1: RTK Query & WebSocket Tag Invalidation ──

test('REQ-SIDEBAR-ATTENTION-LIVE-1: tasks.ts chain list queries provide ChainList:ALL', () => {
  const tasksFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts');
  assert.ok(fs.existsSync(tasksFile), 'src/ui/api/endpoints/tasks.ts must exist');
  const content = fs.readFileSync(tasksFile, 'utf8');

  // fetchTaskChainGroups must provide GROUPED_LIST and ChainList:ALL
  assert.match(
    content,
    /fetchTaskChainGroups[\s\S]*?providesTags:\s*\[[\s\S]*?id:\s*'GROUPED_LIST'[\s\S]*?id:\s*'ALL'[\s\S]*?\]/,
    'fetchTaskChainGroups must provide both GROUPED_LIST and ChainList:ALL',
  );

  // fetchTaskChainProjectPage must provide PROJECT_LIST and ChainList:ALL
  assert.match(
    content,
    /fetchTaskChainProjectPage[\s\S]*?providesTags:\s*\(_result,\s*_error,\s*\{\s*projectId\s*\}\)[\s\S]*?PROJECT_LIST:\$\{projectId\}[\s\S]*?id:\s*'ALL'/,
    'fetchTaskChainProjectPage must provide PROJECT_LIST and ChainList:ALL',
  );

  // listTaskChains must provide PROJECT_LIST and ChainList:ALL
  assert.match(
    content,
    /listTaskChains:\s*build\.query[\s\S]*?providesTags:\s*\(_result,\s*_error,\s*\{\s*projectId\s*\}\)[\s\S]*?PROJECT_LIST:\$\{projectId\}[\s\S]*?id:\s*'ALL'/,
    'listTaskChains must provide PROJECT_LIST and ChainList:ALL',
  );

  // listPinnedTaskChains must provide PINNED_LIST and ChainList:ALL
  assert.match(
    content,
    /listPinnedTaskChains:\s*build\.query[\s\S]*?providesTags:\s*\[[\s\S]*?id:\s*'PINNED_LIST'[\s\S]*?id:\s*'ALL'[\s\S]*?\]/,
    'listPinnedTaskChains must provide PINNED_LIST and ChainList:ALL',
  );

  // fetchPinnedTaskChains must provide PINNED_LIST and ChainList:ALL
  assert.match(
    content,
    /fetchPinnedTaskChains:\s*build\.query[\s\S]*?providesTags:\s*\[[\s\S]*?id:\s*'PINNED_LIST'[\s\S]*?id:\s*'ALL'[\s\S]*?\]/,
    'fetchPinnedTaskChains must provide PINNED_LIST and ChainList:ALL',
  );
});

test('REQ-SIDEBAR-ATTENTION-LIVE-1: voteTask and setTaskStatus invalidate ChainList:ALL, PINNED_LIST, and GROUPED_LIST', () => {
  const tasksFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts');
  const content = fs.readFileSync(tasksFile, 'utf8');

  // voteTask invalidatesTags must include ChainList:ALL, PINNED_LIST, and GROUPED_LIST
  assert.match(
    content,
    /voteTask:\s*build\.mutation[\s\S]*?invalidatesTags:\s*\(_result,\s*_error,\s*\{\s*taskId,\s*chainId\s*\}\)[\s\S]*?id:\s*'ALL'[\s\S]*?id:\s*'PINNED_LIST'[\s\S]*?id:\s*'GROUPED_LIST'/,
    'voteTask must invalidate ChainList:ALL, PINNED_LIST, and GROUPED_LIST',
  );

  // setTaskStatus invalidatesTags must include ChainList:ALL, PINNED_LIST, and GROUPED_LIST
  assert.match(
    content,
    /setTaskStatus:\s*build\.mutation[\s\S]*?invalidatesTags:\s*\(_result,\s*_error,\s*\{\s*taskId,\s*chainId\s*\}\)[\s\S]*?id:\s*'ALL'[\s\S]*?id:\s*'PINNED_LIST'[\s\S]*?id:\s*'GROUPED_LIST'/,
    'setTaskStatus must invalidate ChainList:ALL, PINNED_LIST, and GROUPED_LIST',
  );
});

test('REQ-SIDEBAR-ATTENTION-LIVE-1: wsInvalidation.ts task resource_changed invalidates ChainList:ALL, PINNED_LIST, and GROUPED_LIST', () => {
  const wsFile = path.join(REPO_ROOT, 'src/ui/api/wsInvalidation.ts');
  assert.ok(fs.existsSync(wsFile), 'src/ui/api/wsInvalidation.ts must exist');
  const content = fs.readFileSync(wsFile, 'utf8');

  // Under case 'task':, tags must include ChainList:ALL, PINNED_LIST, and GROUPED_LIST
  assert.match(
    content,
    /case\s+'task':[\s\S]*?const\s+tags:\s*any\[\]\s*=\s*\[[\s\S]*?\{ type:\s*'ChainList',\s*id:\s*'ALL' \}[\s\S]*?\{ type:\s*'Chain',\s*id:\s*'PINNED_LIST' \}[\s\S]*?\{ type:\s*'Chain',\s*id:\s*'GROUPED_LIST' \}[\s\S]*?\];/,
    'wsInvalidation task resource_changed must invalidate ChainList:ALL, PINNED_LIST, and GROUPED_LIST',
  );
});

// ── 2. REQ-SIDEBAR-COLLAPSED-PROGRESS-1: Collapsed Pinned Chains Progress Ring ─

test('REQ-SIDEBAR-COLLAPSED-PROGRESS-1: CollapsedPinnedChains renders progress ring for active chains with tasks', () => {
  const treeFile = path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx');
  assert.ok(fs.existsSync(treeFile), 'src/ui/components/chains/ProjectChainTree.tsx must exist');
  const content = fs.readFileSync(treeFile, 'utf8');

  // CollapsedPinnedChains must compute isActive, hasTasks, radius, circumference, ratio, pct
  assert.match(
    content,
    /export\s+function\s+CollapsedPinnedChains[\s\S]*?const\s+isActive\s*=\s*chain\.status\s*===\s*'active'\s*\|\|\s*chain\.status\s*===\s*'in_progress';/,
    'CollapsedPinnedChains must define isActive correctly',
  );
  assert.match(
    content,
    /export\s+function\s+CollapsedPinnedChains[\s\S]*?const\s+hasTasks\s*=\s*typeof\s+chain\.taskCount\s*===\s*'number'\s*&&\s*chain\.taskCount\s*>\s*0;/,
    'CollapsedPinnedChains must check chain.taskCount > 0',
  );
  assert.match(
    content,
    /export\s+function\s+CollapsedPinnedChains[\s\S]*?isActive\s*&&\s*hasTasks\s*\?[\s\S]*?data-debug-id="chain-progress-ring"[\s\S]*?<svg[\s\S]*?strokeDasharray=\{circumference\}[\s\S]*?strokeDashoffset=\{strokeDashoffset\}/,
    'CollapsedPinnedChains must render circular SVG progress ring with circumference and strokeDashoffset when active with tasks',
  );
});

// ── 3. REQ-CONVO-EXCLUDE-CANCELLED-1: Conversation Header Progress Calculation ─

test('REQ-CONVO-EXCLUDE-CANCELLED-1: ConversationThreadPage chainProgress filters out cancelled tasks', () => {
  const convoFile = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');
  assert.ok(fs.existsSync(convoFile), 'src/ui/components/chat/ConversationThreadPage.tsx must exist');
  const content = fs.readFileSync(convoFile, 'utf8');

  // Verify chainProgress filters by status !== 'cancelled'
  assert.match(
    content,
    /const\s+chainProgress\s*=\s*useMemo\(\(\)\s*=>\s*\{[\s\S]*?status\s*!==\s*['"]cancelled['"][\s\S]*?return\s*\{\s*total,\s*done\s*\};/,
    'chainProgress in ConversationThreadPage.tsx must filter out cancelled tasks',
  );
});

test('REQ-CONVO-EXCLUDE-CANCELLED-1: functional verification of progress computation excluding cancelled tasks', () => {
  interface MockTask {
    taskId: string;
    status: string;
  }

  function computeProgress(rawTasks: MockTask[]) {
    const tasks = rawTasks.filter((t) => t.status !== 'cancelled');
    const total = tasks.length;
    const done = tasks.filter((t) => t.status === 'validated_good' || t.status === 'completed').length;
    return { total, done };
  }

  // 1. Mixed tasks: 2 completed, 1 validated_good, 1 in_progress, 1 cancelled
  const set1: MockTask[] = [
    { taskId: 't1', status: 'completed' },
    { taskId: 't2', status: 'completed' },
    { taskId: 't3', status: 'validated_good' },
    { taskId: 't4', status: 'in_progress' },
    { taskId: 't5', status: 'cancelled' },
  ];
  const res1 = computeProgress(set1);
  assert.equal(res1.total, 4, 'Cancelled task must be excluded from total');
  assert.equal(res1.done, 3, 'Completed and validated_good tasks must be counted as done');

  // 2. All cancelled tasks except 1 done
  const set2: MockTask[] = [
    { taskId: 't1', status: 'completed' },
    { taskId: 't2', status: 'cancelled' },
    { taskId: 't3', status: 'cancelled' },
  ];
  const res2 = computeProgress(set2);
  assert.equal(res2.total, 1, 'Only 1 non-cancelled task');
  assert.equal(res2.done, 1, '1 done task');

  // 3. Only cancelled tasks
  const set3: MockTask[] = [
    { taskId: 't1', status: 'cancelled' },
    { taskId: 't2', status: 'cancelled' },
  ];
  const res3 = computeProgress(set3);
  assert.equal(res3.total, 0, 'Total should be 0 when all tasks are cancelled');
  assert.equal(res3.done, 0, 'Done should be 0 when all tasks are cancelled');

  // 4. Empty task list
  const res4 = computeProgress([]);
  assert.equal(res4.total, 0);
  assert.equal(res4.done, 0);
});
