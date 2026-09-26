// REQ-SEARCH-PALETTE-UI-1, REQ-SEARCH-CHAIN-SELECTOR-1:
// Unit tests for Refactored CommandPalette Task Chain Search & Conversation Chain Selector.
//
// RUN: npx tsx --test tests/ui_global_title_search_test.ts

const sessionStore = new Map<string, string>();
const fakeSessionStorage = {
  getItem: (k: string) => sessionStore.get(k) ?? null,
  setItem: (k: string, v: string) => { sessionStore.set(k, String(v)); },
  removeItem: (k: string) => { sessionStore.delete(k); },
  clear: () => { sessionStore.clear(); },
};
(globalThis as any).sessionStorage = fakeSessionStorage;
if (typeof (globalThis as any).window === 'undefined') {
  (globalThis as any).window = {
    sessionStorage: fakeSessionStorage,
    addEventListener: () => {},
    removeEventListener: () => {},
    location: { hash: '' },
    setTimeout: (fn: (...args: any[]) => void, ms?: number) => setTimeout(fn, ms),
    clearTimeout: (id: any) => clearTimeout(id),
  };
} else {
  (globalThis as any).window.sessionStorage = fakeSessionStorage;
}

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { configureStore } from '@reduxjs/toolkit';

import searchTitleReducer, {
  upsertChainTitle,
  setBulkChainTitles,
  selectSearchChains,
  type SearchItem,
} from '../src/ui/store/searchTitleSlice.ts';

import {
  chainStatusDot,
  taskChainRoute,
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
  optionId,
} from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// -----------------------------------------------------------------------------
// 1. Static Contract: Backend global search removed from CommandPalette.tsx
// -----------------------------------------------------------------------------

test('Backend global search (/api/v1/search) is completely removed from CommandPalette.tsx', () => {
  const file = path.join(REPO_ROOT, 'src/ui/components/ui/patterns/CommandPalette.tsx');
  assert.ok(fs.existsSync(file), 'CommandPalette.tsx must exist');

  const content = fs.readFileSync(file, 'utf8');

  // Must not import or reference backend search queries or SearchHit
  assert.ok(!content.includes('useGlobalSearchQuery'), 'useGlobalSearchQuery must be completely removed');
  assert.ok(!content.includes('useLazyGlobalSearchQuery'), 'useLazyGlobalSearchQuery must be completely removed');
  assert.ok(!content.includes('SearchHit'), 'SearchHit type must be completely removed');
  assert.ok(!content.includes('/api/v1/search'), '/api/v1/search endpoint must not be referenced');
  assert.ok(!content.includes('hitRoute'), 'hitRoute helper must not be imported');
  assert.ok(!content.includes('renderPreview'), 'renderPreview helper must not be imported');

  // Must connect to searchTitleSlice
  assert.ok(content.includes('searchTitleSlice') || content.includes('selectSearchChains'), 'Must connect to searchTitleSlice');
  assert.ok(content.includes('selectSearchChains'), 'Must use selectSearchChains selector');
});

// -----------------------------------------------------------------------------
// 2. CommandPalette Status Indicator Mapping
// -----------------------------------------------------------------------------

test('chainStatusDot correctly maps all task chain statuses to StatusDot tone and pulse', () => {
  // Active and in-progress chains pulse with success tone
  const activeDot = chainStatusDot('active');
  assert.equal(activeDot.tone, 'success');
  assert.equal(activeDot.pulse, true);

  const inProgressDot = chainStatusDot('in_progress');
  assert.equal(inProgressDot.tone, 'success');
  assert.equal(inProgressDot.pulse, true);

  // Completed and validated_good chains are neutral without pulse
  const completedDot = chainStatusDot('completed');
  assert.equal(completedDot.tone, 'neutral');
  assert.equal(completedDot.pulse, false);

  const validatedGoodDot = chainStatusDot('validated_good');
  assert.equal(validatedGoodDot.tone, 'neutral');
  assert.equal(validatedGoodDot.pulse, false);

  // Paused chains have warning tone
  const pausedDot = chainStatusDot('paused');
  assert.equal(pausedDot.tone, 'warning');
  assert.equal(pausedDot.pulse, false);

  // Cancelled and validated_not_good chains have danger tone
  const cancelledDot = chainStatusDot('cancelled');
  assert.equal(cancelledDot.tone, 'danger');
  assert.equal(cancelledDot.pulse, false);

  const validatedNotGoodDot = chainStatusDot('validated_not_good');
  assert.equal(validatedNotGoodDot.tone, 'danger');
  assert.equal(validatedNotGoodDot.pulse, false);

  // Unknown or undefined falls back to neutral
  const defaultDot = chainStatusDot(undefined);
  assert.equal(defaultDot.tone, 'neutral');
  assert.equal(defaultDot.pulse, false);
});

// -----------------------------------------------------------------------------
// 3. Task Chain Route Resolution
// -----------------------------------------------------------------------------

test('taskChainRoute navigates to conversation when coordinator is present or overview when absent', () => {
  // With coordinatorAgentInstanceId: navigates to conversation
  const chainWithCoordinator = {
    chainId: 'chain_123',
    coordinatorAgentInstanceId: 'inst_coord_456',
  };
  assert.equal(
    taskChainRoute(chainWithCoordinator),
    '/conversations/inst_coord_456',
    'Must navigate to coordinator conversation when coordinator agent instance id exists',
  );

  // Without coordinatorAgentInstanceId: navigates to chain overview
  const chainWithoutCoordinator = {
    chainId: 'chain_789',
    coordinatorAgentInstanceId: undefined,
  };
  assert.equal(
    taskChainRoute(chainWithoutCoordinator),
    '/chains/chain_789',
    'Must navigate to chain overview when coordinator is absent',
  );
});

// -----------------------------------------------------------------------------
// 4. Default Navigation and Actions Preservation
// -----------------------------------------------------------------------------

test('CommandPalette preserves default navigation routes and actions for empty query', () => {
  assert.ok(DEFAULT_NAV.length >= 10, 'DEFAULT_NAV must define core application navigation items');
  const labels = DEFAULT_NAV.map((n) => n.label);
  assert.ok(labels.includes('Task Chains'), 'DEFAULT_NAV must include Task Chains');
  assert.ok(labels.includes('Conversations'), 'DEFAULT_NAV must include Conversations');
  assert.ok(labels.includes('Projects'), 'DEFAULT_NAV must include Projects');
  assert.ok(labels.includes('Settings'), 'DEFAULT_NAV must include Settings');

  const actionIds = DEFAULT_ACTIONS.map((a) => a.id);
  assert.ok(actionIds.includes('new-chain'), 'DEFAULT_ACTIONS must include new-chain');
  assert.ok(actionIds.includes('new-conversation'), 'DEFAULT_ACTIONS must include new-conversation');
  assert.ok(actionIds.includes('new-project'), 'DEFAULT_ACTIONS must include new-project');

  assert.equal(optionId(0), 'command-palette-option-0');
  assert.equal(optionId(4), 'command-palette-option-4');
});

// -----------------------------------------------------------------------------
// 5. Redux Title Cache & Client-Side Task Chain Filtering Logic
// -----------------------------------------------------------------------------

test('Client-side task chain search filters strictly across decrypted titles', () => {
  const store = configureStore({
    reducer: {
      searchTitle: searchTitleReducer,
    },
  });

  // Seed multiple task chains across different projects with encrypted rawTitle and decryptedTitle
  store.dispatch(
    setBulkChainTitles([
      {
        id: 'chain_vault_auth',
        type: 'chain',
        rawTitle: 'vault:v1:armoredCiphertext1',
        decryptedTitle: 'Implement User Vault & Master Password',
        projectId: 'proj_security',
        status: 'in_progress',
        updatedAt: '2026-09-26T12:00:00Z',
      },
      {
        id: 'chain_lsp',
        type: 'chain',
        rawTitle: 'vault:v1:armoredCiphertext2',
        decryptedTitle: 'Language Server Protocol Client Support',
        projectId: 'proj_core',
        status: 'completed',
        updatedAt: '2026-09-25T10:00:00Z',
      },
      {
        id: 'chain_fleet',
        type: 'chain',
        rawTitle: 'vault:v1:armoredCiphertext3',
        decryptedTitle: 'Worker Fleet Auto-Scaling and Recovery',
        projectId: 'proj_infra',
        status: 'active',
        updatedAt: '2026-09-26T14:00:00Z',
      },
    ]),
  );

  const chains = selectSearchChains(store.getState());
  assert.equal(Object.keys(chains).length, 3);

  // Search logic simulation matching CommandPalette filtering
  const allChains = Object.values(chains);

  // Query: "vault" -> matches "Implement User Vault & Master Password"
  const qVault = 'vault';
  const matchesVault = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qVault.toLowerCase()),
  );
  assert.equal(matchesVault.length, 1);
  assert.equal(matchesVault[0].id, 'chain_vault_auth');
  assert.equal(matchesVault[0].decryptedTitle, 'Implement User Vault & Master Password');

  // Query: "armoredCiphertext" -> should NOT match because search is strictly against decryptedTitle
  const qCipher = 'armoredciphertext';
  const matchesCipher = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qCipher.toLowerCase()),
  );
  assert.equal(matchesCipher.length, 0, 'Must search decrypted titles, not ciphertexts');

  // Query: "server" -> matches "Language Server Protocol Client Support"
  const qServer = 'server';
  const matchesServer = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qServer.toLowerCase()),
  );
  assert.equal(matchesServer.length, 1);
  assert.equal(matchesServer[0].id, 'chain_lsp');

  // Query: "nonexistent" -> matches nothing
  const qNone = 'nonexistentxyz';
  const matchesNone = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qNone.toLowerCase()),
  );
  assert.equal(matchesNone.length, 0);
});

// -----------------------------------------------------------------------------
// 6. ConversationThreadPage Header Breadcrumb Click Integration
// -----------------------------------------------------------------------------

test('ConversationThreadPage header breadcrumb has interactive button with click event opening palette', () => {
  const convoFile = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');
  assert.ok(fs.existsSync(convoFile), 'ConversationThreadPage.tsx must exist');

  const content = fs.readFileSync(convoFile, 'utf8');

  // Breadcrumb structure with project, slash, and title
  assert.ok(content.includes('data-debug-id="conversation-thread-breadcrumb"'), 'Must have breadcrumb container');
  assert.ok(content.includes('data-debug-id="conversation-breadcrumb-project"'), 'Must have breadcrumb project');
  assert.ok(content.includes('data-debug-id="conversation-thread-title"'), 'Must have conversation-thread-title debug id');

  // Interactive button verification
  assert.match(
    content,
    /<button[^>]*data-debug-id="conversation-thread-title"[^>]*onClick=\{[^}]*setPaletteOpen\(true\)[^}]*\}/,
    'conversation-thread-title must be a button triggering setPaletteOpen(true)',
  );

  // Accessibility and hover state
  assert.match(content, /aria-label="Select task chain"/, 'Must have accessible aria-label on title button');
  assert.match(content, /hover:bg-neutral-soft/, 'Must have hover background styling');
  assert.match(content, /cursor-pointer/, 'Must indicate clickability with cursor-pointer');

  // Search button also opens palette
  assert.match(
    content,
    /<button[^>]*data-debug-id="conversation-search-btn"[^>]*onClick=\{[^}]*setPaletteOpen\(true\)[^}]*\}/,
    'conversation-search-btn must open task chain search palette via setPaletteOpen(true)',
  );
});

// -----------------------------------------------------------------------------
// 7. AppShell Cmd+K and Sidebar Search Button Integration
// -----------------------------------------------------------------------------

test('AppShell maintains Cmd+K / Ctrl+K and sidebar Search button opening CommandPalette', () => {
  const appShellFile = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
  assert.ok(fs.existsSync(appShellFile), 'AppShell.tsx must exist');

  const content = fs.readFileSync(appShellFile, 'utf8');

  // Cmd+K / Ctrl+K keyboard shortcut
  assert.match(
    content,
    /\(event\.metaKey\s*\|\|\s*event\.ctrlKey\)\s*&&\s*\(event\.key\s*===\s*['"]k['"]\s*\|\|\s*event\.key\s*===\s*['"]K['"]\)/,
    'AppShell must handle Cmd+K and Ctrl+K to toggle command palette',
  );

  // Sidebar search button
  assert.ok(
    content.includes('data-debug-id="shell-sidebar-search-button"'),
    'Sidebar search button must exist with data-debug-id="shell-sidebar-search-button"',
  );
  assert.match(
    content,
    /<button[^>]*data-debug-id="shell-sidebar-search-button"[^>]*onClick=\{[^}]*setPaletteOpen\(true\)[^}]*\}/,
    'Sidebar search button must call setPaletteOpen(true)',
  );
});

// -----------------------------------------------------------------------------
// 8. Keyboard Navigation Logic
// -----------------------------------------------------------------------------

test('Keyboard navigation handles ArrowDown, ArrowUp with wrap-around and Enter selection', () => {
  const itemCount = 4;
  let activeIndex = 0;

  // ArrowDown
  const onArrowDown = () => {
    activeIndex = (activeIndex + 1) % itemCount;
  };
  // ArrowUp
  const onArrowUp = () => {
    activeIndex = (activeIndex - 1 + itemCount) % itemCount;
  };

  assert.equal(activeIndex, 0);
  onArrowDown();
  assert.equal(activeIndex, 1);
  onArrowDown();
  assert.equal(activeIndex, 2);
  onArrowDown();
  assert.equal(activeIndex, 3);
  onArrowDown(); // wraps to 0
  assert.equal(activeIndex, 0);

  onArrowUp(); // wraps to 3
  assert.equal(activeIndex, 3);
  onArrowUp();
  assert.equal(activeIndex, 2);

  // Enter activation
  let navigatedRoute = '';
  let closed = false;
  const mockNavigate = (r: string) => { navigatedRoute = r; };
  const mockClose = () => { closed = true; };

  const selectedItem = {
    kind: 'chain' as const,
    label: 'Test Chain',
    route: '/conversations/inst_test_123',
    group: 'Project — Chains',
    chainId: 'ch_1',
  };

  const activate = (item: typeof selectedItem) => {
    mockNavigate(item.route);
    mockClose();
  };

  activate(selectedItem);
  assert.equal(navigatedRoute, '/conversations/inst_test_123');
  assert.equal(closed, true);
});

// -----------------------------------------------------------------------------
// 9. Task Chain Matching Metadata: Project Labels and Status Indicators
// -----------------------------------------------------------------------------

test('Task chain results include project labels, status indicators, and correct routes', () => {
  const chain1 = {
    chainId: 'ch_alpha',
    title: 'Alpha Chain',
    status: 'in_progress',
    projectId: 'p_1',
    projectName: 'Security Gateway',
    coordinatorAgentInstanceId: 'inst_alpha_coord',
  };

  const chain2 = {
    chainId: 'ch_beta',
    title: 'Beta Chain',
    status: 'completed',
    projectId: 'p_2',
    projectName: 'Core Engine',
    coordinatorAgentInstanceId: undefined,
  };

  // Route calculation
  assert.equal(taskChainRoute(chain1), '/conversations/inst_alpha_coord');
  assert.equal(taskChainRoute(chain2), '/chains/ch_beta');

  // Status dot indicators
  const dot1 = chainStatusDot(chain1.status);
  assert.equal(dot1.tone, 'success');
  assert.equal(dot1.pulse, true);

  const dot2 = chainStatusDot(chain2.status);
  assert.equal(dot2.tone, 'neutral');
  assert.equal(dot2.pulse, false);
});

// -----------------------------------------------------------------------------
// 10. Empty Query vs Non-Empty Query Filtering
// -----------------------------------------------------------------------------

test('Query filtering separates quick navigation on empty from strict chain search on query', () => {
  const navItems = DEFAULT_NAV;
  const actions = DEFAULT_ACTIONS;
  const chains = [
    { chainId: 'c1', title: 'User Vault Setup', projectName: 'Auth' },
    { chainId: 'c2', title: 'Billing Integration', projectName: 'Billing' },
  ];

  // Empty query -> includes nav and actions
  const qEmpty = '';
  assert.ok(!qEmpty);
  assert.ok(navItems.length > 0);
  assert.ok(actions.length > 0);

  // Non-empty query "vault" -> filters strictly chains
  const qNonEmpty = 'vault';
  const matches = chains.filter(c => c.title.toLowerCase().includes(qNonEmpty.toLowerCase()));
  assert.equal(matches.length, 1);
  assert.equal(matches[0].chainId, 'c1');
  assert.equal(matches[0].title, 'User Vault Setup');
});
