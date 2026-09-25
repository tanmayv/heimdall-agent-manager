// REQ-VAULT-CHAINS-1: Unit Tests for Task Chains Zero-Knowledge Encryption, Decryption,
// UI Integration, and Generic Reusable Components.
//
// RUN: node --test tests/ui_chains_vault_test.ts

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
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  openUnlockModal,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
  selectIsUnlockModalOpen,
} from '../src/ui/store/vaultSlice.ts';
import {
  resolveVaultText,
  decryptVaultTextContent,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptChainFields,
  decryptChainRecord,
  decryptChainList,
} from '../src/ui/utils/vaultChains.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DIFFERENT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// Test 1: Static verification of chain component files, contracts, and debug IDs
// -----------------------------------------------------------------------------

test('Task Chains endpoints, utilities, and UI files exist with required contracts', () => {
  const vaultChainsFile = path.join(REPO_ROOT, 'src/ui/utils/vaultChains.ts');
  const taskChainsEndpointFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/taskChains.ts');
  const tasksEndpointFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts');
  const taskChainsPageFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainsPage.tsx');
  const taskChainOverviewFile = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainOverview.tsx');
  const projectChainTreeFile = path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx');
  const chainOverviewPanelFile = path.join(REPO_ROOT, 'src/ui/components/chat/ChainOverviewPanel.tsx');
  const recentTaskChainsTabFile = path.join(REPO_ROOT, 'src/ui/components/home/RecentTaskChainsTab.tsx');

  assert.ok(fs.existsSync(vaultChainsFile), 'vaultChains.ts must exist');
  assert.ok(fs.existsSync(taskChainsEndpointFile), 'taskChains.ts must exist');
  assert.ok(fs.existsSync(tasksEndpointFile), 'tasks.ts must exist');
  assert.ok(fs.existsSync(taskChainsPageFile), 'TaskChainsPage.tsx must exist');
  assert.ok(fs.existsSync(taskChainOverviewFile), 'TaskChainOverview.tsx must exist');
  assert.ok(fs.existsSync(projectChainTreeFile), 'ProjectChainTree.tsx must exist');
  assert.ok(fs.existsSync(chainOverviewPanelFile), 'ChainOverviewPanel.tsx must exist');
  assert.ok(fs.existsSync(recentTaskChainsTabFile), 'RecentTaskChainsTab.tsx must exist');

  const taskChainsSrc = fs.readFileSync(taskChainsEndpointFile, 'utf8');
  assert.ok(
    taskChainsSrc.includes('encryptVaultText'),
    'taskChains.ts must import and use encryptVaultText',
  );
  assert.ok(
    taskChainsSrc.includes('createTaskChain'),
    'taskChains.ts must define createTaskChain mutation',
  );
  assert.ok(
    taskChainsSrc.includes('updateTaskChain'),
    'taskChains.ts must define updateTaskChain mutation',
  );
  assert.ok(
    taskChainsSrc.includes('getTaskChain'),
    'taskChains.ts must define getTaskChain query',
  );
  assert.ok(
    taskChainsSrc.includes('getTaskChains'),
    'taskChains.ts must define getTaskChains query',
  );

  const tasksSrc = fs.readFileSync(tasksEndpointFile, 'utf8');
  assert.ok(
    tasksSrc.includes('encryptVaultText'),
    'tasks.ts must import and use encryptVaultText',
  );

  const taskChainsPageSrc = fs.readFileSync(taskChainsPageFile, 'utf8');
  assert.ok(
    taskChainsPageSrc.includes('VaultText'),
    'TaskChainsPage.tsx must integrate VaultText component',
  );

  const taskChainOverviewSrc = fs.readFileSync(taskChainOverviewFile, 'utf8');
  assert.ok(
    taskChainOverviewSrc.includes('VaultText'),
    'TaskChainOverview.tsx must integrate VaultText component',
  );
  assert.ok(
    taskChainOverviewSrc.includes('data-debug-id="taskchain-overview-title"'),
    'TaskChainOverview.tsx must retain data-debug-id="taskchain-overview-title"',
  );
  assert.ok(
    taskChainOverviewSrc.includes('data-debug-id="taskchain-overview-description"'),
    'TaskChainOverview.tsx must retain data-debug-id="taskchain-overview-description"',
  );

  const projectChainTreeSrc = fs.readFileSync(projectChainTreeFile, 'utf8');
  assert.ok(
    projectChainTreeSrc.includes('VaultText'),
    'ProjectChainTree.tsx must integrate VaultText component',
  );

  const chainOverviewPanelSrc = fs.readFileSync(chainOverviewPanelFile, 'utf8');
  assert.ok(
    chainOverviewPanelSrc.includes('VaultText'),
    'ChainOverviewPanel.tsx must integrate VaultText component',
  );

  const recentTaskChainsTabSrc = fs.readFileSync(recentTaskChainsTabFile, 'utf8');
  assert.ok(
    recentTaskChainsTabSrc.includes('VaultText'),
    'RecentTaskChainsTab.tsx must integrate VaultText component',
  );
});

// -----------------------------------------------------------------------------
// Test 2: encryptChainFields encrypts title and description when unlocked
// -----------------------------------------------------------------------------

test('encryptChainFields encrypts title and description when vault key is provided', async () => {
  const plainChain = {
    title: 'Zero-Knowledge Task Chain Integration',
    description: 'This description contains sensitive architecture plans and credentials.',
    kind: 'team_work',
    status: 'active',
  };

  const encrypted = await encryptChainFields(plainChain, TEST_KEY_HEX);

  assert.ok(isVaultArmored(encrypted.title), 'Chain title must have vault:v1: armor');
  assert.ok(isVaultArmored(encrypted.description), 'Chain description must have vault:v1: armor');
  assert.notEqual(encrypted.title, plainChain.title);
  assert.notEqual(encrypted.description, plainChain.description);
  assert.equal(encrypted.kind, 'team_work');
  assert.equal(encrypted.status, 'active');

  // Re-encrypting already-armored fields must be idempotent (no double encryption)
  const doubleEncrypted = await encryptChainFields(encrypted, TEST_KEY_HEX);
  assert.equal(doubleEncrypted.title, encrypted.title, 'Must not double-armor title');
  assert.equal(doubleEncrypted.description, encrypted.description, 'Must not double-armor description');
});

test('encryptChainFields leaves plaintext intact when no vault key is provided', async () => {
  const plainChain = {
    title: 'Public Community Documentation',
    description: 'Public description with no sensitive data.',
    kind: 'team_work',
  };

  const unencrypted = await encryptChainFields(plainChain, null);
  assert.equal(unencrypted.title, plainChain.title);
  assert.equal(unencrypted.description, plainChain.description);
  assert.equal(isVaultArmored(unencrypted.title), false);
  assert.equal(isVaultArmored(unencrypted.description), false);
});

// -----------------------------------------------------------------------------
// Test 3: decryptChainRecord decrypts title and description with correct key
// -----------------------------------------------------------------------------

test('decryptChainRecord decrypts armored title and description when unlocked', async () => {
  const origTitle = 'Feature: Secure Enclave Deployment';
  const origDesc = '# Deployment Steps\n1. Generate keys\n2. Attest enclave';

  const armoredTitle = await encryptVaultText(origTitle, TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText(origDesc, TEST_KEY_HEX);

  const chainRecord = {
    chain_id: 'chain_test_123',
    title: armoredTitle,
    description: armoredDesc,
    description_preview: armoredTitle,
    status: 'active',
  };

  const decrypted = await decryptChainRecord(chainRecord, TEST_KEY_HEX);

  assert.equal(decrypted.title, origTitle);
  assert.equal(decrypted.description, origDesc);
  assert.equal(decrypted.description_preview, origTitle);
  assert.equal(decrypted.status, 'active');
});

test('decryptChainRecord preserves armored string when vault is locked or key is missing', async () => {
  const armoredTitle = await encryptVaultText('Secret chain title', TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText('Secret chain description', TEST_KEY_HEX);

  const chainRecord = {
    chain_id: 'chain_test_456',
    title: armoredTitle,
    description: armoredDesc,
    status: 'active',
  };

  const preserved = await decryptChainRecord(chainRecord, null);

  assert.equal(preserved.title, armoredTitle, 'Armored title must be preserved intact');
  assert.equal(preserved.description, armoredDesc, 'Armored description must be preserved intact');
});

// -----------------------------------------------------------------------------
// Test 4: Legacy plaintext chains render transparently without regression
// -----------------------------------------------------------------------------

test('decryptChainRecord and resolveVaultText handle legacy plaintext chains transparently', async () => {
  const legacyChain = {
    chain_id: 'chain_legacy_789',
    title: 'Migrate legacy database schema',
    description: 'Plain markdown description from before vault encryption was introduced.',
    status: 'completed',
  };

  // Even with a vault key present, plaintext should remain unchanged
  const decrypted = await decryptChainRecord(legacyChain, TEST_KEY_HEX);
  assert.equal(decrypted.title, legacyChain.title);
  assert.equal(decrypted.description, legacyChain.description);

  // resolveVaultText returns plaintext mode
  const titleResolved = resolveVaultText(legacyChain.title, true);
  assert.equal(titleResolved.mode, 'plaintext');
  assert.equal(titleResolved.isArmored, false);
  assert.equal(titleResolved.displayText, legacyChain.title);

  const descResolved = resolveVaultText(legacyChain.description, false);
  assert.equal(descResolved.mode, 'plaintext');
  assert.equal(descResolved.isArmored, false);
  assert.equal(descResolved.displayText, legacyChain.description);
});

// -----------------------------------------------------------------------------
// Test 5: decryptChainList decrypts array of chain records
// -----------------------------------------------------------------------------

test('decryptChainList decrypts arrays containing mixed encrypted and legacy chains', async () => {
  const encTitle1 = await encryptVaultText('Encrypted Chain Alpha', TEST_KEY_HEX);
  const encDesc1 = await encryptVaultText('Description Alpha', TEST_KEY_HEX);

  const encTitle2 = await encryptVaultText('Encrypted Chain Beta', TEST_KEY_HEX);
  const encDesc2 = await encryptVaultText('Description Beta', TEST_KEY_HEX);

  const chains = [
    { chain_id: 'c1', title: encTitle1, description: encDesc1 },
    { chain_id: 'c2', title: 'Unencrypted Legacy Chain Gamma', description: 'Legacy Plain Desc' },
    { chain_id: 'c3', title: encTitle2, description: encDesc2 },
  ];

  const decryptedList = await decryptChainList(chains, TEST_KEY_HEX);

  assert.equal(decryptedList.length, 3);
  assert.equal(decryptedList[0].title, 'Encrypted Chain Alpha');
  assert.equal(decryptedList[0].description, 'Description Alpha');
  assert.equal(decryptedList[1].title, 'Unencrypted Legacy Chain Gamma');
  assert.equal(decryptedList[1].description, 'Legacy Plain Desc');
  assert.equal(decryptedList[2].title, 'Encrypted Chain Beta');
  assert.equal(decryptedList[2].description, 'Description Beta');
});

// -----------------------------------------------------------------------------
// Test 6: Redux vault state transitions and interactive locked placeholder
// -----------------------------------------------------------------------------

test('Vault locked state displays interactive placeholder and triggers unlock modal', async () => {
  const armoredTitle = await encryptVaultText('Classified Chain Title', TEST_KEY_HEX);

  // Locked resolution
  const lockedResolved = resolveVaultText(armoredTitle, false);
  assert.equal(lockedResolved.mode, 'locked');
  assert.equal(lockedResolved.isLocked, true);
  assert.equal(lockedResolved.dataDebugId, 'vault-locked-placeholder');
  assert.equal(lockedResolved.displayText, '[🔒 Encrypted content - click to unlock]');

  // Unlocked resolution
  const unlockedResolved = resolveVaultText(armoredTitle, true);
  assert.equal(unlockedResolved.mode, 'unlocked');
  assert.equal(unlockedResolved.isLocked, false);

  // Redux state transitions
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false);

  // Unlock with key
  state = vaultReducer(state, setVaultUnlocked({ rawVaultKeyHex: TEST_KEY_HEX }));
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal(selectRawVaultKeyHex({ vault: state }), TEST_KEY_HEX);

  // Lock vault
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // Open unlock modal
  state = vaultReducer(state, openUnlockModal());
  assert.equal(selectIsUnlockModalOpen({ vault: state }), true);
});
