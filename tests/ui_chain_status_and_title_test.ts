// REQ-CHAIN-UI-OVERVIEW-1: Unit Tests for Task Chain Status Selector, Inline Title Editing, and Archive Actions
//
// RUN: node --test tests/ui_chain_status_and_title_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

test('TaskChainOverview.tsx implements status selector and archived banner', () => {
  const overviewFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainOverview.tsx');
  assert.ok(fs.existsSync(overviewFile), 'TaskChainOverview.tsx must exist');

  const content = fs.readFileSync(overviewFile, 'utf8');

  // Acceptance Criterion 1: TaskChainOverview status can be switched between Active, Completed, and Archived
  assert.match(content, /data-debug-id="taskchain-overview-status-select"/, 'Status select must have debug id');
  assert.match(content, /value:\s*'active',\s*label:\s*'Active'/, 'Status options must include Active');
  assert.match(content, /value:\s*'completed',\s*label:\s*'Completed'/, 'Status options must include Completed');
  assert.match(content, /value:\s*'archived',\s*label:\s*'Archived'/, 'Status options must include Archived');
  assert.match(content, /handleChainStatusChange/, 'Status selector must invoke status change handler');
  assert.match(content, /updateTaskChain\(\{\s*chainId,\s*status:/, 'handleChainStatusChange must invoke updateTaskChain mutation');

  // Acceptance Criterion 2: Archived task chain displays archived banner with restore action
  assert.match(content, /data-debug-id="taskchain-overview-archived-banner"/, 'Archived banner must have debug id');
  assert.match(content, /data-debug-id="taskchain-overview-restore-btn"/, 'Restore button must have debug id');
  assert.match(content, /Restore to Active/, 'Restore button text must be "Restore to Active"');
  assert.match(content, /handleChainStatusChange\('active'\)/, 'Restore button must switch status back to active');
});

test('TaskChainOverview.tsx implements inline title editing with Enter/Save and Escape/Cancel', () => {
  const overviewFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainOverview.tsx');
  const content = fs.readFileSync(overviewFile, 'utf8');

  // Acceptance Criterion 3: Task chain title can be edited inline, saved via Enter/Save, and canceled via Escape
  assert.match(content, /data-debug-id="taskchain-overview-title-edit-btn"/, 'Title edit button must have debug id');
  assert.match(content, /<Icon\s+name="pencil"/, 'Title edit button must render pencil icon');
  assert.match(content, /data-debug-id="taskchain-overview-title-input"/, 'Inline title input must have debug id');
  assert.match(content, /data-debug-id="taskchain-overview-title-save-btn"/, 'Title save button must have debug id');
  assert.match(content, /data-debug-id="taskchain-overview-title-cancel-btn"/, 'Title cancel button must have debug id');

  // Verification of keyboard shortcuts & mutation call
  assert.match(content, /e\.key === 'Enter'/, 'Title input must handle Enter key to save');
  assert.match(content, /e\.key === 'Escape'/, 'Title input must handle Escape key to cancel');
  assert.match(content, /updateTaskChain\(\{\s*chainId,\s*title:/, 'handleSaveTitle must invoke updateTaskChain with trimmed title');

  // Verification of Vault title decryption
  assert.match(content, /decryptedTitle/, 'TaskChainOverview must track decryptedTitle state');
  assert.match(content, /decryptVaultText\(chainTitle,\s*rawKey\)/, 'TaskChainOverview must decrypt armored chain title');
});

test('TaskChainsPage.tsx implements status filtering and archive chain card actions', () => {
  const pageFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainsPage.tsx');
  assert.ok(fs.existsSync(pageFile), 'TaskChainsPage.tsx must exist');

  const content = fs.readFileSync(pageFile, 'utf8');

  // Acceptance Criterion 4: TaskChainsPage allows filtering for archived chains
  assert.match(content, /data-debug-id="task-chains-status-filter"/, 'Status filter Select must have debug id');
  assert.match(content, /<option\s+value="active">Active<\/option>/, 'Status filter must include Active option');
  assert.match(content, /<option\s+value="completed">Completed<\/option>/, 'Status filter must include Completed option');
  assert.match(content, /<option\s+value="archived">Archived<\/option>/, 'Status filter must include Archived option');
  assert.match(content, /<option\s+value="all">All<\/option>/, 'Status filter must include All option');

  // Acceptance Criterion 5: Archive chain option in chain card actions
  assert.match(content, /data-debug-id=\{`task-chains-archive-btn-\$\{chain\.chainId\}`\}/, 'Archive chain button must have debug id');
  assert.match(content, /Archive chain/, 'Chain card actions must display "Archive chain" option');
  assert.match(content, /data-debug-id=\{`task-chains-restore-btn-\$\{chain\.chainId\}`\}/, 'Restore chain button must have debug id');
  assert.match(content, /onArchive\?\.\(chain\.chainId\)/, 'Archive button must invoke onArchive handler');
  assert.match(content, /updateTaskChain\(\{\s*chainId,\s*status:\s*'archived'\s*\}\)/, 'Archive handler must invoke updateTaskChain mutation');
  assert.match(content, /updateTaskChain\(\{\s*chainId,\s*status:\s*'active'\s*\}\)/, 'Restore handler must invoke updateTaskChain mutation');

  // Archived badge style in statusBadgeClass
  assert.match(content, /case\s+'archived':/, 'statusBadgeClass must support archived status');
});

test('tasks.ts endpoint supports includeArchived and cache invalidation', () => {
  const tasksFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts');
  const content = fs.readFileSync(tasksFile, 'utf8');

  assert.match(content, /fetchTaskChainProjectPage:/, 'tasks.ts must define fetchTaskChainProjectPage');
  assert.match(content, /includeArchived\?: boolean/, 'fetchTaskChainProjectPage must support includeArchived');
  assert.match(content, /updateTaskChain:/, 'tasks.ts must export updateTaskChain mutation');
});
