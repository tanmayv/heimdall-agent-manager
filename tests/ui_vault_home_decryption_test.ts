// REQ-VAULT-HOME-CHAINS, REQ-VAULT-HOME-ACTIONS, REQ-VAULT-CARDS-PANEL, REQ-VAULT-PINNED-SIDEBAR, REQ-VAULT-TASKCHAINS-PAGE
// Comprehensive Vault decryption unit test suite covering Home page, Action cards, Task chains,
// and Sidebar pinned avatars.
//
// RUN: node --test tests/ui_vault_home_decryption_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../src/ui/utils/vaultContent.ts';
import {
  chainAvatarInitials,
  resolveCollapsedPinnedChainAvatar,
} from '../src/ui/components/chains/chainInitials.ts';
import {
  resolveDecryptedMarkdownContent,
} from '../src/ui/components/vault/vaultTextHelper.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// -----------------------------------------------------------------------------
// Section 1: Static Architecture & Component Contract Verification
// -----------------------------------------------------------------------------

test('REQ-VAULT-HOME-CHAINS: RecentTaskChainsTab wraps project name with VaultText', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/home/RecentTaskChainsTab.tsx');
  assert.ok(fs.existsSync(filePath), 'RecentTaskChainsTab.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');
  assert.ok(
    content.includes("import { VaultText } from '../vault/VaultText';"),
    'RecentTaskChainsTab.tsx must import VaultText',
  );
  assert.ok(
    content.includes('<VaultText value={chain.projectName} fallback="Unassigned" as="span" />'),
    'RecentTaskChainsTab.tsx must wrap chain.projectName with VaultText fallback="Unassigned" as="span"',
  );
  assert.ok(
    !content.includes('<span>{chain.projectName}</span>'),
    'RecentTaskChainsTab.tsx must not render unwrapped {chain.projectName}',
  );
});

test('REQ-VAULT-HOME-ACTIONS: ActionItemsTab wraps titles, badges, rationales, and operations with VaultText / DecryptedMarkdown', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/home/ActionItemsTab.tsx');
  assert.ok(fs.existsSync(filePath), 'ActionItemsTab.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');
  assert.ok(
    content.includes("import { VaultText, DecryptedMarkdown } from '../vault/VaultText';"),
    'ActionItemsTab.tsx must import VaultText and DecryptedMarkdown',
  );

  // Card title in list
  assert.ok(
    content.includes('<VaultText value={card.title} fallback="Untitled card" as="span" />'),
    'ActionItemsTab.tsx must wrap card.title in list with VaultText',
  );

  // Project name in list
  assert.ok(
    content.includes('<VaultText value={project?.name || \'Global\'} as="span" />'),
    'ActionItemsTab.tsx must wrap project?.name in list with VaultText',
  );

  // Project badge in detail header
  assert.ok(
    content.includes('<VaultText value={selectedCard.project_id ? (projectMap.get(selectedCard.project_id)?.name || selectedCard.project_id) : \'Global\'} as="span" />'),
    'ActionItemsTab.tsx must wrap selectedCard project badge with VaultText',
  );

  // Card title in detail header
  assert.ok(
    content.includes('<VaultText value={selectedCard.title} fallback="Untitled card" as="span" />'),
    'ActionItemsTab.tsx must wrap detail card title with VaultText',
  );

  // Card rationale in detail
  assert.ok(
    content.includes('<DecryptedMarkdown source={selectedCard.rationale || \'_No rationale provided._\'} />'),
    'ActionItemsTab.tsx must render selectedCard.rationale with DecryptedMarkdown',
  );

  // OperationPreviewRow
  assert.ok(
    content.includes('<VaultText value={memTitle} />'),
    'OperationPreviewRow in ActionItemsTab.tsx must wrap memTitle with VaultText',
  );
  assert.ok(
    content.includes('<DecryptedMarkdown source={memBody} compact copyAll={false} />'),
    'OperationPreviewRow in ActionItemsTab.tsx must render memBody with DecryptedMarkdown',
  );
  assert.ok(
    content.includes('<VaultText value={taskComment} />'),
    'OperationPreviewRow in ActionItemsTab.tsx must wrap taskComment with VaultText',
  );
});

test('REQ-VAULT-CARDS-PANEL: CardsPanel wraps group names, card titles, rationales, and operations with VaultText / DecryptedMarkdown', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/cards/CardsPanel.tsx');
  assert.ok(fs.existsSync(filePath), 'CardsPanel.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');
  assert.ok(
    content.includes("import { VaultText, DecryptedMarkdown } from '../vault/VaultText';"),
    'CardsPanel.tsx must import VaultText and DecryptedMarkdown',
  );

  // Project group header
  assert.ok(
    content.includes('<VaultText value={group.name} />'),
    'CardsPanel.tsx must wrap group.name with VaultText',
  );

  // Card title in row
  assert.ok(
    content.includes('<VaultText value={card.title} fallback="Untitled card" as="span" />'),
    'CardsPanel.tsx must wrap card.title with VaultText',
  );

  // Card rationale
  assert.ok(
    content.includes('<DecryptedMarkdown source={card.rationale} compact copyAll={false} />'),
    'CardsPanel.tsx must render card.rationale with DecryptedMarkdown',
  );

  // OperationPreviewRow
  assert.ok(
    content.includes('<VaultText value={memTitle} />'),
    'OperationPreviewRow in CardsPanel.tsx must wrap memTitle with VaultText',
  );
  assert.ok(
    content.includes('<DecryptedMarkdown source={memBody} compact copyAll={false} />'),
    'OperationPreviewRow in CardsPanel.tsx must render memBody with DecryptedMarkdown',
  );
  assert.ok(
    content.includes('<VaultText value={taskComment} />'),
    'OperationPreviewRow in CardsPanel.tsx must wrap taskComment with VaultText',
  );
});

test('REQ-VAULT-TASKCHAINS-PAGE: TaskChainsPage wraps project group displayName with VaultText', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainsPage.tsx');
  assert.ok(fs.existsSync(filePath), 'TaskChainsPage.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');
  assert.ok(
    content.includes("import { VaultText } from '../vault/VaultText';"),
    'TaskChainsPage.tsx must import VaultText',
  );
  assert.ok(
    content.includes('<VaultText value={displayName} fallback="Unassigned" />'),
    'TaskChainsPage.tsx must wrap displayName with VaultText fallback="Unassigned"',
  );
  assert.ok(
    !content.includes('<span className="truncate text-sm font-semibold text-primary">{displayName}</span>'),
    'TaskChainsPage.tsx must not render raw {displayName} without VaultText',
  );
});

test('REQ-VAULT-PINNED-SIDEBAR: ProjectChainTree defines CollapsedPinnedChainItem with reactive decryption', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx');
  assert.ok(fs.existsSync(filePath), 'ProjectChainTree.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');
  assert.ok(
    content.includes('useDecryptedText'),
    'ProjectChainTree.tsx must import useDecryptedText',
  );
  assert.ok(
    content.includes('export function CollapsedPinnedChainItem'),
    'ProjectChainTree.tsx must export CollapsedPinnedChainItem',
  );
  assert.ok(
    content.includes('const decryptedTitle = useDecryptedText(chain.title);'),
    'CollapsedPinnedChainItem must call useDecryptedText(chain.title)',
  );
  assert.ok(
    content.includes("const initials = isLocked ? '🔒' : chainAvatarInitials(decryptedTitle.text);"),
    'CollapsedPinnedChainItem must display lock icon when locked and decrypted initials when unlocked',
  );
  assert.ok(
    content.includes('title={decryptedTitle.text}'),
    'CollapsedPinnedChainItem must set title to decryptedTitle.text for tooltip',
  );
  assert.ok(
    content.includes('aria-label={decryptedTitle.text}'),
    'CollapsedPinnedChainItem must set aria-label to decryptedTitle.text',
  );
});

// -----------------------------------------------------------------------------
// Section 2: chainAvatarInitials Unit Tests
// -----------------------------------------------------------------------------

test('chainAvatarInitials returns "TC" (and never "VA") for vault-armored strings', async () => {
  const titles = [
    'Refactor Authentication Protocol',
    'Vault Zero Knowledge Architecture',
    'Secret Project #42',
    'Vanguard Operation Alpha',
  ];

  for (const plain of titles) {
    const armored = await encryptVaultText(plain, TEST_KEY_HEX);
    assert.ok(isVaultArmored(armored), `Encrypted title must be vault armored: ${armored}`);

    const initials = chainAvatarInitials(armored);
    assert.equal(
      initials,
      'TC',
      `Initials for vault armored string must be "TC", got: "${initials}"`,
    );
    assert.notEqual(
      initials,
      'VA',
      'Initials for vault armored string must NEVER be "VA"',
    );
  }
});

test('chainAvatarInitials correctly extracts initials from human-readable plaintext', () => {
  // Two or more words -> first letters of first two words
  assert.equal(chainAvatarInitials('Payment Gateway'), 'PG');
  assert.equal(chainAvatarInitials('refactor auth service'), 'RA');
  assert.equal(chainAvatarInitials('Heimdall Hub Rewrite v2'), 'HH');

  // Single word -> first two letters uppercase
  assert.equal(chainAvatarInitials('Vanguard'), 'VA');
  assert.equal(chainAvatarInitials('Core'), 'CO');
  assert.equal(chainAvatarInitials('single'), 'SI');

  // Single character -> 1 letter uppercase
  assert.equal(chainAvatarInitials('x'), 'X');

  // Empty or whitespace -> "TC"
  assert.equal(chainAvatarInitials(''), 'TC');
  assert.equal(chainAvatarInitials('   '), 'TC');
  assert.equal(chainAvatarInitials(null as any), 'TC');
  assert.equal(chainAvatarInitials(undefined as any), 'TC');
});

// -----------------------------------------------------------------------------
// Section 3: CollapsedPinnedChainItem Avatar Logic Unit Tests
// -----------------------------------------------------------------------------

test('resolveCollapsedPinnedChainAvatar computes initials from decrypted title when unlocked and shows lock icon when locked', async () => {
  const rawTitle = 'Zero Knowledge Vault Integration';
  const armoredTitle = await encryptVaultText(rawTitle, TEST_KEY_HEX);

  // Scenario 1: Vault unlocked -> decrypts to "Zero Knowledge Vault Integration"
  const unlockedAvatar = resolveCollapsedPinnedChainAvatar(
    armoredTitle,
    rawTitle,
    false, // isLocked = false
  );
  assert.equal(unlockedAvatar.isLocked, false);
  assert.equal(unlockedAvatar.initials, 'ZK', 'Must compute initials from decrypted text');
  assert.equal(unlockedAvatar.tooltip, rawTitle, 'Tooltip must show decrypted title');

  // Scenario 2: Vault locked -> armored text is locked
  const lockedAvatar = resolveCollapsedPinnedChainAvatar(
    armoredTitle,
    '[🔒 Encrypted]',
    true, // isLocked = true
  );
  assert.equal(lockedAvatar.isLocked, true);
  assert.equal(lockedAvatar.initials, '🔒', 'Must display lock icon 🔒 when locked');
  assert.equal(lockedAvatar.tooltip, '[🔒 Encrypted]', 'Tooltip must show encrypted placeholder when locked');

  // Scenario 3: Plain unencrypted chain -> passthrough
  const plainTitle = 'Infrastructure Setup';
  const plainAvatar = resolveCollapsedPinnedChainAvatar(
    plainTitle,
    plainTitle,
    false,
  );
  assert.equal(plainAvatar.isLocked, false);
  assert.equal(plainAvatar.initials, 'IS');
  assert.equal(plainAvatar.tooltip, plainTitle);
});

// -----------------------------------------------------------------------------
// Section 4: DecryptedMarkdown Unit Tests
// -----------------------------------------------------------------------------

test('DecryptedMarkdown properly decrypts pure armored markdown when unlocked', async () => {
  const secretMarkdown = `### Sensitive Operational Procedure
1. Step One: Connect to isolated gateway.
2. Step Two: Verify SHA256 checksum \`abcdef123456\`.
`;

  const armored = await encryptVaultText(secretMarkdown, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armored));

  // When unlocked
  const unlocked = await resolveDecryptedMarkdownContent(armored, TEST_KEY_HEX, true);
  assert.equal(unlocked.isLocked, false);
  assert.equal(unlocked.text, secretMarkdown, 'Must decrypt cleanly back to markdown source');

  // When locked
  const locked = await resolveDecryptedMarkdownContent(armored, null, false);
  assert.equal(locked.isLocked, true);
  assert.equal(locked.text, '[🔒 Encrypted]', 'Must mask armored markdown when locked');
});

test('DecryptedMarkdown properly decrypts embedded vault tokens before markdown rendering', async () => {
  const tokenA = await encryptVaultText('super-secret-db-pass', TEST_KEY_HEX);
  const tokenB = await encryptVaultText('prod-api-key-999', TEST_KEY_HEX);

  const markdownWithTokens = `## Configuration Summary
- Database Password: \`${tokenA}\`
- API Key: \`${tokenB}\`
- Public Note: Visible to everyone.
`;

  // 1. Unlocked resolution -> tokens replaced with plaintext
  const unlocked = await resolveDecryptedMarkdownContent(markdownWithTokens, TEST_KEY_HEX, true);
  assert.equal(unlocked.isLocked, false);
  assert.ok(
    unlocked.text.includes('Database Password: `super-secret-db-pass`'),
    'Token A must be decrypted in markdown',
  );
  assert.ok(
    unlocked.text.includes('API Key: `prod-api-key-999`'),
    'Token B must be decrypted in markdown',
  );
  assert.ok(
    unlocked.text.includes('Public Note: Visible to everyone.'),
    'Unencrypted text must be preserved',
  );
  assert.ok(!unlocked.text.includes('vault:v1:'), 'No raw vault ciphertext should remain');

  // 2. Locked resolution -> tokens masked with [🔒 Encrypted]
  const locked = await resolveDecryptedMarkdownContent(markdownWithTokens, null, false);
  assert.equal(locked.isLocked, true);
  assert.ok(
    locked.text.includes('Database Password: `[🔒 Encrypted]`'),
    'Token A must be shielded with [🔒 Encrypted] when locked',
  );
  assert.ok(
    locked.text.includes('API Key: `[🔒 Encrypted]`'),
    'Token B must be shielded with [🔒 Encrypted] when locked',
  );
  assert.ok(!locked.text.includes('vault:v1:'), 'Ciphertext must be completely shielded');
});

test('DecryptedMarkdown passes through plain markdown unchanged', async () => {
  const plain = '# Normal Markdown\n\nNo encryption used here.';
  const res = await resolveDecryptedMarkdownContent(plain, null, false);
  assert.equal(res.isLocked, false);
  assert.equal(res.text, plain);
});
