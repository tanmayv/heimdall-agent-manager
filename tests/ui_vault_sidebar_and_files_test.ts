// REQ-VAULT-SIDEBAR-PROJECTS, REQ-VAULT-FILES-PANEL, REQ-VAULT-ARTIFACTS-LIBRARY, REQ-VAULT-PROJECT-LAUNCH, REQ-VAULT-TAGS-INVALIDATE
// Unit tests verifying Vault decryption and VaultText wrapping across Sidebar project tree,
// Files panel, Library, Launch modal, Action items tab, and RTK Query tag invalidation.
//
// RUN: node --test tests/ui_vault_sidebar_and_files_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
} from '../src/ui/utils/vaultContent.ts';
import {
  decryptProjectRecord,
  decryptProjectList,
  encryptProjectFields,
} from '../src/ui/utils/vaultProjects.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// -----------------------------------------------------------------------------
// Section 1: Static Architecture & JSX Wrapping Verification
// -----------------------------------------------------------------------------

test('REQ-VAULT-SIDEBAR-PROJECTS: AppShell wraps sidebar project header name in VaultText and uses safe launch attributes', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
  assert.ok(fs.existsSync(filePath), 'AppShell.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  // Verify VaultText import
  assert.ok(
    content.includes("import { VaultText } from '../vault/VaultText';"),
    'AppShell.tsx must import VaultText from ../vault/VaultText',
  );

  // Verify project name wrapping
  assert.ok(
    content.includes('<VaultText value={projectGroup.project.name} fallback="Project" />'),
    'AppShell.tsx must wrap projectGroup.project.name in VaultText with fallback="Project"',
  );

  // Verify safe launch button attributes
  assert.ok(
    content.includes("isVaultArmored(projectGroup.project.name)"),
    'AppShell.tsx must check isVaultArmored for project launch button title/aria-label',
  );
  assert.ok(
    content.includes("'Launch agent for project'"),
    'AppShell.tsx must use safe "Launch agent for project" fallback when armored',
  );
});

test('REQ-VAULT-TAGS-INVALIDATE: AppShell invalidates RTK Query tags on vault unlock', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
  const content = fs.readFileSync(filePath, 'utf8');

  assert.ok(
    content.includes("heimdallApi.util.invalidateTags(["),
    'AppShell.tsx must call invalidateTags',
  );
  assert.ok(
    content.includes("'Projects'"),
    'AppShell.tsx must invalidate Projects tag',
  );
  assert.ok(
    content.includes("'SidebarProjects'"),
    'AppShell.tsx must invalidate SidebarProjects tag',
  );
  assert.ok(
    content.includes("'SidebarConversations'"),
    'AppShell.tsx must invalidate SidebarConversations tag',
  );
  assert.ok(
    content.includes("'Cards'"),
    'AppShell.tsx must invalidate Cards tag',
  );
  assert.ok(
    content.includes("'ChainList'"),
    'AppShell.tsx must invalidate ChainList tag',
  );
});

test('REQ-VAULT-FILES-PANEL: ProjectFilesPanel wraps directory selector, dropdown option, and breadcrumb in VaultText', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/chat/ProjectFilesPanel.tsx');
  assert.ok(fs.existsSync(filePath), 'ProjectFilesPanel.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  // Verify VaultText import
  assert.ok(
    content.includes("import { VaultText } from '../vault/VaultText';"),
    'ProjectFilesPanel.tsx must import VaultText',
  );

  // Verify activeDirectory.label wrapping in directory selector button
  assert.ok(
    content.includes('<VaultText value={activeDirectory.label} />'),
    'ProjectFilesPanel.tsx must wrap activeDirectory.label in VaultText',
  );

  // Verify dir.label wrapping in directory options dropdown
  assert.ok(
    content.includes('<VaultText value={dir.label} />'),
    'ProjectFilesPanel.tsx must wrap dir.label in VaultText',
  );

  // Verify root breadcrumb wrapping
  assert.ok(
    content.includes('<VaultText value={i === 0 ? activeDirectory.label : c.label} />'),
    'ProjectFilesPanel.tsx must wrap root breadcrumb label with VaultText',
  );
});

test('REQ-VAULT-ARTIFACTS-LIBRARY: LibraryPage wraps project column in VaultText and decrypts project filter options', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/LibraryPage.tsx');
  assert.ok(fs.existsSync(filePath), 'LibraryPage.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  // Verify VaultText wrapping in project column
  assert.ok(
    content.includes('<VaultText value={project?.name} fallback={projectId(a) || \'—\'} />'),
    'LibraryPage.tsx must wrap project?.name with VaultText fallback={projectId(a) || "—"}',
  );

  // Verify project list decryption for options.
  // REQ-RAWKEY-A8: the `decryptProjectList(rawProjectsList, rawVaultKeyHex)` alternative is
  // gone. Accepting it kept a permanently-null operand on the allowed list, so a regression
  // back to the dead source would have passed this test while decrypting nothing. Still a
  // source check rather than a behavioral one because LibraryPage is a React component and
  // this suite has no DOM renderer to mount it.
  assert.ok(
    content.includes('decryptProjectList(rawProjectsList, keyToUse)') ||
      content.includes('decryptProjectList(rawProjectsList, activeKey)'),
    'LibraryPage.tsx must decrypt projectsList using decryptProjectList with the active key',
  );
  for (const dead of ['rawVaultKeyHex', 'selectRawVaultKeyHex', 'readSessionVaultKey']) {
    assert.ok(
      !content.includes(dead),
      `LibraryPage.tsx must not read ${dead} -- it is permanently null, so a gate on it never fires`,
    );
  }
});

test('REQ-VAULT-PROJECT-LAUNCH: ProjectLaunchModal wraps project.name in VaultText and uses decrypted name in feedback message', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/projects/ProjectLaunchModal.tsx');
  assert.ok(fs.existsSync(filePath), 'ProjectLaunchModal.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  // Verify VaultText and useDecryptedText import
  assert.ok(
    content.includes('VaultText') && content.includes('useDecryptedText'),
    'ProjectLaunchModal.tsx must import VaultText and useDecryptedText',
  );

  // Verify modal title wrapping
  assert.ok(
    content.includes('<VaultText value={project.name} />'),
    'ProjectLaunchModal.tsx must wrap project.name with VaultText in title',
  );

  // Verify feedback message uses decryptedProjectName
  assert.ok(
    content.includes('decryptedProjectName || project.name'),
    'ProjectLaunchModal.tsx must use decryptedProjectName in feedback message',
  );
});

test('REQ-VAULT-HOME-ACTIONS: ActionItemsTab projectOptions displays decrypted project names', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/home/ActionItemsTab.tsx');
  assert.ok(fs.existsSync(filePath), 'ActionItemsTab.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  // Retargeted from the retired `rawKey` operand onto `activeKey` (REQ-RAWKEY-A5): the key
  // comes from getActiveVaultKey(), not from state.vault.rawVaultKeyHex, which never held one.
  assert.ok(
    content.includes('decryptProjectList(projects, activeKey)'),
    'ActionItemsTab.tsx must decrypt projects using decryptProjectList',
  );
  assert.ok(
    content.includes('getActiveVaultKey()'),
    'ActionItemsTab.tsx must resolve the vault key via getActiveVaultKey()',
  );
  // REQ-RAWKEY-A8: negative guard, so a regression BACK to the dead source fails here
  // rather than passing silently with encryption quietly disabled.
  for (const dead of ['rawVaultKeyHex', 'selectRawVaultKeyHex', 'readSessionVaultKey']) {
    assert.ok(!content.includes(dead), `ActionItemsTab.tsx must not read the retired ${dead}`);
  }
  assert.ok(
    content.includes('decryptedProjects.map((p) => ({ value: p.project_id, label: p.name }))'),
    'ActionItemsTab.tsx projectOptions must map over decryptedProjects',
  );
});

// -----------------------------------------------------------------------------
// Section 2: Behavioral & Cryptographic Decryption Verification
// -----------------------------------------------------------------------------

test('Behavioral: Project record and list encryption & decryption round-trip', async () => {
  const rawProject = {
    project_id: 'proj_secret_123',
    name: 'Top Secret Alpha',
    description: 'Internal confidential engineering project',
    default_path: '/home/tanmay/repo',
  };

  // Encrypt project fields
  const encrypted = await encryptProjectFields(rawProject, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.name), 'Encrypted project name must be armored');
  assert.ok(isVaultArmored(encrypted.description), 'Encrypted project description must be armored');
  assert.equal(encrypted.project_id, rawProject.project_id, 'Project ID must remain plaintext');
  assert.equal(encrypted.default_path, rawProject.default_path, 'Default path must remain plaintext');

  // Decrypt single record
  const decryptedRecord = await decryptProjectRecord(encrypted, TEST_KEY_HEX);
  assert.equal(decryptedRecord.name, rawProject.name);
  assert.equal(decryptedRecord.description, rawProject.description);

  // Decrypt project list
  const list = [encrypted, { project_id: 'proj_plain', name: 'Plain Public Project' }];
  const decryptedList = await decryptProjectList(list, TEST_KEY_HEX);
  assert.equal(decryptedList.length, 2);
  assert.equal(decryptedList[0].name, 'Top Secret Alpha');
  assert.equal(decryptedList[1].name, 'Plain Public Project');

  // Decrypt without key (graceful fallback preserves armor or leaves as is)
  const lockedList = await decryptProjectList(list, null);
  assert.equal(lockedList[0].name, encrypted.name, 'When locked without key, leaves armored text as-is');
  assert.equal(lockedList[1].name, 'Plain Public Project');
});
