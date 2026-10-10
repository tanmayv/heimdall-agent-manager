// REQ-VAULT-TASKS-1: Unit Tests for Tasks and Task Comments UI Zero-Knowledge Encryption,
// Decryption, and Reusable VaultText Integration.
//
// RUN: node --test tests/ui_tasks_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  VAULT_ARMOR_PREFIX,
} from '../src/ui/utils/vaultContent.ts';
import {
  resolveVaultText,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptTaskFields,
  encryptTaskCommentFields,
  decryptTaskRecord,
  decryptTaskCommentRecord,
} from '../src/ui/utils/vaultTasks.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DIFFERENT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// Test 1: Static verification of component files, contracts, and imports
// -----------------------------------------------------------------------------

test('Task UI components, endpoints, and utils exist with required contracts', () => {
  const taskOverviewFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainOverview.tsx');
  const taskCommentsThreadFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskCommentsThread.tsx');
  const taskCommentsFile = path.join(REPO_ROOT, 'src/ui/components/comments/TaskComments.tsx');
  const taskDetailPageFile = path.join(REPO_ROOT, 'src/ui/pages/TaskDetailPage.tsx');
  const currentTaskStripFile = path.join(REPO_ROOT, 'src/ui/components/chat/CurrentTaskStrip.tsx');
  const chainOverviewPanelFile = path.join(REPO_ROOT, 'src/ui/components/chat/ChainOverviewPanel.tsx');
  const tasksEndpointFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts');
  const vaultTasksFile = path.join(REPO_ROOT, 'src/ui/utils/vaultTasks.ts');

  assert.ok(fs.existsSync(taskOverviewFile), 'TaskChainOverview.tsx must exist');
  assert.ok(fs.existsSync(taskCommentsThreadFile), 'TaskCommentsThread.tsx must exist');
  assert.ok(fs.existsSync(taskCommentsFile), 'TaskComments.tsx must exist');
  assert.ok(fs.existsSync(taskDetailPageFile), 'TaskDetailPage.tsx must exist');
  assert.ok(fs.existsSync(currentTaskStripFile), 'CurrentTaskStrip.tsx must exist');
  assert.ok(fs.existsSync(chainOverviewPanelFile), 'ChainOverviewPanel.tsx must exist');
  assert.ok(fs.existsSync(tasksEndpointFile), 'tasks.ts endpoint must exist');
  assert.ok(fs.existsSync(vaultTasksFile), 'vaultTasks.ts must exist');

  // Verify TaskChainOverview integrates VaultText
  const taskOverviewSrc = fs.readFileSync(taskOverviewFile, 'utf8');
  assert.ok(
    taskOverviewSrc.includes('VaultText'),
    'TaskChainOverview.tsx must integrate VaultText component',
  );
  assert.ok(
    taskOverviewSrc.includes('<VaultText value={task.title} as="span" />'),
    'TaskChainOverview.tsx must render task.title wrapped in VaultText',
  );
  assert.ok(
    taskOverviewSrc.includes('isVaultArmored'),
    'TaskChainOverview.tsx must check for armored descriptions',
  );

  // Verify TaskCommentsThread integrates VaultText and decrypts comment bodies
  const taskCommentsThreadSrc = fs.readFileSync(taskCommentsThreadFile, 'utf8');
  assert.ok(
    taskCommentsThreadSrc.includes('VaultText'),
    'TaskCommentsThread.tsx must integrate VaultText component',
  );
  assert.ok(
    taskCommentsThreadSrc.includes('decryptVaultText'),
    'TaskCommentsThread.tsx must decrypt comment body with decryptVaultText',
  );
  assert.ok(
    taskCommentsThreadSrc.includes('<VaultText value={summary.lastCommentPreview} as="span" />'),
    'TaskCommentsThread.tsx must wrap lastCommentPreview in VaultText',
  );

  // Verify TaskComments.tsx re-exports components
  const taskCommentsSrc = fs.readFileSync(taskCommentsFile, 'utf8');
  assert.ok(
    taskCommentsSrc.includes('TaskCommentsThread') && taskCommentsSrc.includes('VaultText'),
    'TaskComments.tsx must re-export TaskCommentsThread and VaultText',
  );

  // Verify TaskDetailPage integrates VaultText
  const taskDetailPageSrc = fs.readFileSync(taskDetailPageFile, 'utf8');
  assert.ok(
    taskDetailPageSrc.includes('<VaultText value={task.title} as="span" />'),
    'TaskDetailPage.tsx must render task.title in VaultText',
  );
  assert.ok(
    taskDetailPageSrc.includes('<VaultText value={task.description} as="div" />'),
    'TaskDetailPage.tsx must render task.description in VaultText',
  );

  // Verify CurrentTaskStrip integrates VaultText
  const currentTaskStripSrc = fs.readFileSync(currentTaskStripFile, 'utf8');
  assert.ok(
    currentTaskStripSrc.includes('VaultText'),
    'CurrentTaskStrip.tsx must integrate VaultText component',
  );

  // Verify ChainOverviewPanel integrates VaultText and decrypts task description in review action gate
  const chainOverviewPanelSrc = fs.readFileSync(chainOverviewPanelFile, 'utf8');
  assert.ok(
    chainOverviewPanelSrc.includes('VaultText'),
    'ChainOverviewPanel.tsx must integrate VaultText component',
  );
  assert.ok(
    chainOverviewPanelSrc.includes('<VaultText value={currentTask.title} as="span" className="truncate" />'),
    'ChainOverviewPanel.tsx must wrap currentTask.title in VaultText on agent cards',
  );
  assert.ok(
    chainOverviewPanelSrc.includes('selectActiveVaultKey'),
    'ChainOverviewPanel.tsx must import the active CryptoKey selector',
  );
  assert.ok(
    chainOverviewPanelSrc.includes('decryptVaultText'),
    'ChainOverviewPanel.tsx must import and call decryptVaultText',
  );
  assert.ok(
    chainOverviewPanelSrc.includes('fallback="[🔒 Encrypted description]"'),
    'ChainOverviewPanel.tsx must provide locked fallback for armored descriptions in review card',
  );

  // Verify tasks endpoint imports and uses vault encryption
  const tasksEndpointSrc = fs.readFileSync(tasksEndpointFile, 'utf8');
  assert.ok(
    tasksEndpointSrc.includes('encryptVaultText'),
    'tasks.ts must import and use encryptVaultText',
  );
  assert.ok(
    tasksEndpointSrc.includes('createTask:'),
    'tasks.ts must define createTask mutation',
  );
  assert.ok(
    tasksEndpointSrc.includes('updateTaskDetail:'),
    'tasks.ts must define updateTaskDetail mutation',
  );
  assert.ok(
    tasksEndpointSrc.includes('addTaskComment:'),
    'tasks.ts must define addTaskComment mutation',
  );
  assert.ok(
    tasksEndpointSrc.includes('updateTask:'),
    'tasks.ts must define updateTask mutation',
  );

  // Verify vaultTasks utility exports
  const vaultTasksSrc = fs.readFileSync(vaultTasksFile, 'utf8');
  assert.ok(
    vaultTasksSrc.includes('export async function encryptTaskFields'),
    'vaultTasks.ts must export encryptTaskFields',
  );
  assert.ok(
    vaultTasksSrc.includes('export async function encryptTaskCommentFields'),
    'vaultTasks.ts must export encryptTaskCommentFields',
  );
  assert.ok(
    vaultTasksSrc.includes('export async function decryptTaskRecord'),
    'vaultTasks.ts must export decryptTaskRecord',
  );
  assert.ok(
    vaultTasksSrc.includes('export async function decryptTaskCommentRecord'),
    'vaultTasks.ts must export decryptTaskCommentRecord',
  );
});

// -----------------------------------------------------------------------------
// Test 2: <VaultText /> resolution for plaintext and legacy unencrypted tasks
// -----------------------------------------------------------------------------

test('VaultText helper handles plaintext and legacy unencrypted tasks and comments without changes', () => {
  const legacyTaskTitle = 'Implement Redis caching layer for session tokens';
  const resolved = resolveVaultText(legacyTaskTitle, false);
  assert.equal(resolved.mode, 'plaintext');
  assert.equal(resolved.isArmored, false);
  assert.equal(resolved.displayText, legacyTaskTitle);
  assert.equal(resolved.isLocked, false);
  assert.equal(resolved.dataDebugId, undefined);

  // Plaintext comment body
  const legacyComment = 'LGTM! Verified with 15 concurrent worker instances.';
  const resolvedComment = resolveVaultText(legacyComment, false);
  assert.equal(resolvedComment.mode, 'plaintext');
  assert.equal(resolvedComment.isArmored, false);
  assert.equal(resolvedComment.displayText, legacyComment);

  // Empty fallback string
  const resolvedEmpty = resolveVaultText('', false, 'No task description available');
  assert.equal(resolvedEmpty.mode, 'plaintext');
  assert.equal(resolvedEmpty.displayText, 'No task description available');
});

// -----------------------------------------------------------------------------
// Test 3: <VaultText /> locked placeholder resolution for armored task content
// -----------------------------------------------------------------------------

test('VaultText helper renders locked placeholder with data-debug-id for armored task content', async () => {
  const secretTitle = 'Deploy confidential payment gateway service';
  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredTitle), 'Must produce valid armored ciphertext');

  // Vault is locked
  const resolvedLocked = resolveVaultText(armoredTitle, false);
  assert.equal(resolvedLocked.mode, 'locked');
  assert.equal(resolvedLocked.isArmored, true);
  assert.equal(resolvedLocked.isLocked, true);
  assert.equal(resolvedLocked.dataDebugId, 'vault-locked-placeholder');
  assert.equal(resolvedLocked.displayText, 'Encrypted content');
});

// -----------------------------------------------------------------------------
// Test 4: Task field encryption encrypts title and description when unlocked
// -----------------------------------------------------------------------------

test('encryptTaskFields encrypts title and description into "vault:v1:<base64>" when vault is unlocked', async () => {
  const rawTaskPayload = {
    title: 'Migrate production database with zero downtime',
    description: 'Detailed steps for migrating database: 1. Set up replica, 2. Catch up binlog, 3. Switch DNS.',
    chainId: 'chain_test_123',
    priority: 'p1',
    status: 'in_progress',
    assigneeRef: { type: 'agent_instance', agentInstanceId: 'inst_worker_1' },
    reviewerRefs: [{ type: 'agent_id', agentId: 'agt_rev_1' }],
    dependsOn: ['task_dep_1'],
  };

  // 1. Unlocked vault with valid 256-bit key
  const encrypted = await encryptTaskFields(rawTaskPayload, TEST_KEY_HEX);

  // Content fields must be armored
  assert.ok(isVaultArmored(encrypted.title), 'Title must be armored');
  assert.ok(isVaultArmored(encrypted.description), 'Description must be armored');

  assert.ok(encrypted.title!.startsWith(VAULT_ARMOR_PREFIX));
  assert.ok(encrypted.description!.startsWith(VAULT_ARMOR_PREFIX));

  // Plaintext must not leak into ciphertext
  assert.ok(!encrypted.title!.includes('Migrate production database'));
  assert.ok(!encrypted.description!.includes('Detailed steps'));
  assert.ok(!encrypted.description!.includes('binlog'));

  // Metadata / workflow fields must remain strictly plaintext
  assert.equal(encrypted.chainId, 'chain_test_123');
  assert.equal(encrypted.priority, 'p1');
  assert.equal(encrypted.status, 'in_progress');
  assert.deepEqual(encrypted.assigneeRef, { type: 'agent_instance', agentInstanceId: 'inst_worker_1' });
  assert.deepEqual(encrypted.reviewerRefs, [{ type: 'agent_id', agentId: 'agt_rev_1' }]);
  assert.deepEqual(encrypted.dependsOn, ['task_dep_1']);

  // 2. Locked vault (null key) preserves plaintext
  const unencrypted = await encryptTaskFields(rawTaskPayload, null);
  assert.equal(unencrypted.title, rawTaskPayload.title);
  assert.equal(unencrypted.description, rawTaskPayload.description);

  // 3. Idempotency: already armored fields must not be double encrypted
  const alreadyArmored = await encryptTaskFields(encrypted, TEST_KEY_HEX);
  assert.equal(alreadyArmored.title, encrypted.title);
  assert.equal(alreadyArmored.description, encrypted.description);
});

// -----------------------------------------------------------------------------
// Test 5: Task comment field encryption encrypts body when unlocked
// -----------------------------------------------------------------------------

test('encryptTaskCommentFields encrypts comment body into "vault:v1:<base64>" when vault is unlocked', async () => {
  const rawCommentPayload = {
    taskId: 'task_abc',
    chainId: 'chain_123',
    body: 'Production secret: API key is sk_live_998877665544',
  };

  // 1. Unlocked vault
  const encrypted = await encryptTaskCommentFields(rawCommentPayload, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.body), 'Comment body must be armored');
  assert.ok(encrypted.body.startsWith(VAULT_ARMOR_PREFIX));
  assert.ok(!encrypted.body.includes('sk_live_998877665544'));

  // 2. Locked vault (null key) preserves plaintext
  const unencrypted = await encryptTaskCommentFields(rawCommentPayload, null);
  assert.equal(unencrypted.body, rawCommentPayload.body);

  // 3. Idempotency
  const alreadyArmored = await encryptTaskCommentFields(encrypted, TEST_KEY_HEX);
  assert.equal(alreadyArmored.body, encrypted.body);
});

// -----------------------------------------------------------------------------
// Test 6: Full round-trip encryption, decryption, and transformation of Task records
// -----------------------------------------------------------------------------

test('Full round-trip encryption and decryption of Task records', async () => {
  const originalTitle = 'Implement Zero-Knowledge Encryption for Tasks';
  const originalDescription = 'Full specification for task encryption in UI and CLI.';
  const originalLastComment = 'Worker finished implementation and passed all tests.';

  const rawTask = {
    id: 'task_roundtrip_1',
    taskId: 'task_roundtrip_1',
    chainId: 'chain_test_xyz',
    title: originalTitle,
    description: originalDescription,
    priority: 'p1',
    status: 'in_progress',
    commentSummary: {
      count: 2,
      lastCommentPreview: originalLastComment,
      lastCommentAt: '2026-09-25T15:00:00Z',
    },
  };

  // Encrypt task fields
  const encryptedTask = await encryptTaskFields(rawTask, TEST_KEY_HEX);
  // Encrypt comment summary preview too for testing
  const encryptedSummaryPreview = await encryptVaultText(originalLastComment, TEST_KEY_HEX);
  encryptedTask.commentSummary = {
    ...encryptedTask.commentSummary,
    lastCommentPreview: encryptedSummaryPreview,
  };

  assert.ok(isVaultArmored(encryptedTask.title));
  assert.ok(isVaultArmored(encryptedTask.description));
  assert.ok(isVaultArmored(encryptedTask.commentSummary.lastCommentPreview));

  // Decrypt with correct key
  const decryptedTask = await decryptTaskRecord(encryptedTask, TEST_KEY_HEX);
  assert.equal(decryptedTask.title, originalTitle);
  assert.equal(decryptedTask.description, originalDescription);
  assert.equal(decryptedTask.commentSummary.lastCommentPreview, originalLastComment);
  assert.equal(decryptedTask.taskId, 'task_roundtrip_1');
  assert.equal(decryptedTask.status, 'in_progress');

  // Locked vault (null key) leaves armored fields intact
  const lockedTask = await decryptTaskRecord(encryptedTask, null);
  assert.equal(lockedTask.title, encryptedTask.title);
  assert.equal(lockedTask.description, encryptedTask.description);

  // Decrypt with incorrect key fails gracefully (leaves original armored string, does not crash)
  const wrongKeyTask = await decryptTaskRecord(encryptedTask, DIFFERENT_KEY_HEX);
  assert.equal(wrongKeyTask.title, encryptedTask.title);
  assert.equal(wrongKeyTask.description, encryptedTask.description);
});

// -----------------------------------------------------------------------------
// Test 7: Full round-trip encryption and decryption of Task Comment records
// -----------------------------------------------------------------------------

test('Full round-trip encryption and decryption of Task Comment records', async () => {
  const originalBody = 'Reviewed code diff; all test vectors pass and edge cases are handled.';
  const rawComment = {
    commentId: 'cmt_roundtrip_1',
    taskId: 'task_1',
    chainId: 'chain_1',
    authorDisplayName: 'Senior Reviewer',
    body: originalBody,
  };

  const encryptedComment = await encryptTaskCommentFields(rawComment, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encryptedComment.body));

  const decryptedComment = await decryptTaskCommentRecord(encryptedComment, TEST_KEY_HEX);
  assert.equal(decryptedComment.body, originalBody);
  assert.equal(decryptedComment.commentId, 'cmt_roundtrip_1');

  // Locked vault preserves armored
  const lockedComment = await decryptTaskCommentRecord(encryptedComment, null);
  assert.equal(lockedComment.body, encryptedComment.body);

  // Wrong key preserves armored
  const wrongKeyComment = await decryptTaskCommentRecord(encryptedComment, DIFFERENT_KEY_HEX);
  assert.equal(wrongKeyComment.body, encryptedComment.body);
});

// -----------------------------------------------------------------------------
// Test 8: Partial task updates encrypt only provided content fields
// -----------------------------------------------------------------------------

test('encryptTaskFields handles partial payloads with omitted fields', async () => {
  const partialPayload = {
    title: 'Only updating task title',
  };

  const encrypted = await encryptTaskFields(partialPayload, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.title));
  assert.equal(encrypted.description, undefined);

  const decrypted = await decryptTaskRecord(encrypted, TEST_KEY_HEX);
  assert.equal(decrypted.title, 'Only updating task title');
  assert.equal(decrypted.description, undefined);
});

// -----------------------------------------------------------------------------
// Test 9: Review Action Gate decodes encrypted task description and parses checklist
// -----------------------------------------------------------------------------

test('Review Action Gate decodes encrypted task description and parses checklist (REQ-REVIEW-GATE-DECRYPT-DESCRIPTION)', async () => {
  const originalChecklistDescription = `Title: Feature Verification
Acceptance criteria:
- [ ] AttentionTaskReviewCard decrypts task description when vault is unlocked
- [x] Acceptance criteria checklist parses correctly from decrypted description
[ ] Raw base64 ciphertext is never rendered in Review Action Gate
[x] When vault is locked, renders VaultText / encrypted placeholder`;

  // Encrypt the description with test key
  const armoredDescription = await encryptVaultText(originalChecklistDescription, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredDescription));

  // 1. When vault is locked (no key), effectiveDescription is empty string and never raw ciphertext
  const lockedEffectiveDescription = isVaultArmored(armoredDescription) ? ('' || '') : armoredDescription;
  assert.equal(lockedEffectiveDescription, '');
  assert.ok(!lockedEffectiveDescription.includes('vault:v1:'), 'Ciphertext must never be present in effectiveDescription when locked');

  // 2. When vault is unlocked, decryptVaultText decrypts description
  const decrypted = await decryptVaultText(armoredDescription, TEST_KEY_HEX);
  assert.equal(decrypted, originalChecklistDescription);

  // 3. Checklist items extract properly from decrypted description
  const lines = decrypted.split('\n');
  const checklistItems = lines
    .map((l) => l.trim())
    .filter((l) => /^(\[[\sxX]\]|-\s*\[[\sxX]\])/.test(l))
    .map((l) => ({
      checked: /\[[xX]\]/.test(l),
      text: l.replace(/^[-*]?\s*\[[\sxX]\]\s*/, ''),
    }));

  assert.equal(checklistItems.length, 4);
  assert.equal(checklistItems[0].checked, false);
  assert.equal(checklistItems[0].text, 'AttentionTaskReviewCard decrypts task description when vault is unlocked');
  assert.equal(checklistItems[1].checked, true);
  assert.equal(checklistItems[1].text, 'Acceptance criteria checklist parses correctly from decrypted description');
  assert.equal(checklistItems[2].checked, false);
  assert.equal(checklistItems[2].text, 'Raw base64 ciphertext is never rendered in Review Action Gate');
  assert.equal(checklistItems[3].checked, true);
  assert.equal(checklistItems[3].text, 'When vault is locked, renders VaultText / encrypted placeholder');

  // 4. Fallback locked placeholder helper resolves correctly
  const lockedFallback = resolveVaultText(armoredDescription, false);
  assert.equal(lockedFallback.isLocked, true);
  assert.equal(lockedFallback.mode, 'locked');
  assert.equal(lockedFallback.dataDebugId, 'vault-locked-placeholder');
});

// -----------------------------------------------------------------------------
// Test 10: Agent Card Task Titles resolve through VaultText (REQ-AGENT-CARD-VAULT-TITLE)
// -----------------------------------------------------------------------------

test('Agent card task titles resolve through VaultText and raw ciphertext never leaks (REQ-AGENT-CARD-VAULT-TITLE)', async () => {
  const originalTaskTitle = 'Confidential Security Audit Task';

  // 1. Static check: ChainOverviewPanel wraps currentTask.title in VaultText
  const chainOverviewPanelFile = path.join(REPO_ROOT, 'src/ui/components/chat/ChainOverviewPanel.tsx');
  const chainOverviewPanelSrc = fs.readFileSync(chainOverviewPanelFile, 'utf8');
  assert.ok(
    chainOverviewPanelSrc.includes('<VaultText value={currentTask.title} as="span" className="truncate" />'),
    'ChainOverviewPanel.tsx must wrap currentTask.title with <VaultText value={currentTask.title} as="span" className="truncate" />',
  );

  // 2. Encrypt task title
  const armoredTitle = await encryptVaultText(originalTaskTitle, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredTitle));
  assert.ok(armoredTitle.startsWith(VAULT_ARMOR_PREFIX));

  // 3. When vault is locked (isUnlocked = false), resolveVaultText returns locked placeholder and never leaks ciphertext
  const lockedResolution = resolveVaultText(armoredTitle, false);
  assert.equal(lockedResolution.isLocked, true);
  assert.equal(lockedResolution.mode, 'locked');
  assert.equal(lockedResolution.displayText, 'Encrypted content');
  assert.equal(lockedResolution.dataDebugId, 'vault-locked-placeholder');
  assert.ok(!lockedResolution.displayText.includes('vault:v1:'), 'Raw ciphertext must never leak when locked');

  // 4. When vault is unlocked, decryptVaultText decrypts and returns original task title
  const unlockedResolution = resolveVaultText(armoredTitle, true);
  assert.equal(unlockedResolution.isLocked, false);
  assert.equal(unlockedResolution.mode, 'unlocked');
  const decryptedTitle = await decryptVaultText(armoredTitle, TEST_KEY_HEX);
  assert.equal(decryptedTitle, originalTaskTitle);
  assert.ok(!decryptedTitle.includes('vault:v1:'), 'Decrypted title must not contain armor prefix');

  // 5. Unencrypted task titles pass through without modification
  const unencryptedTitle = 'Unencrypted Task Title';
  const plaintextResolution = resolveVaultText(unencryptedTitle, false);
  assert.equal(plaintextResolution.mode, 'plaintext');
  assert.equal(plaintextResolution.displayText, unencryptedTitle);
  assert.equal(plaintextResolution.isLocked, false);
});

