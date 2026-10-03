// REQ-EXPIRY-UI-3: Unit Tests for UI Pending tab expiration filtering for memories & action cards
//
// RUN: node --test tests/ui_expiry_filtering_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const MEMORY_MODEL_FILE = path.join(REPO_ROOT, 'src/ui/components/memory/memoryModel.ts');
const MEMORY_LIST_FILE = path.join(REPO_ROOT, 'src/ui/components/memory/MemoryListPage.tsx');
const CARDS_PANEL_FILE = path.join(REPO_ROOT, 'src/ui/components/cards/CardsPanel.tsx');
const CARDS_ENDPOINT_FILE = path.join(REPO_ROOT, 'src/ui/api/endpoints/cards.ts');
const EXPIRY_FILE = path.join(REPO_ROOT, 'src/ui/utils/expiry.ts');

test('REQ-EXPIRY-UI-3: Static structure and exports in files', () => {
  assert.ok(fs.existsSync(MEMORY_MODEL_FILE), 'memoryModel.ts must exist');
  assert.ok(fs.existsSync(MEMORY_LIST_FILE), 'MemoryListPage.tsx must exist');
  assert.ok(fs.existsSync(CARDS_PANEL_FILE), 'CardsPanel.tsx must exist');
  assert.ok(fs.existsSync(CARDS_ENDPOINT_FILE), 'cards.ts must exist');
  assert.ok(fs.existsSync(EXPIRY_FILE), 'expiry.ts must exist');

  const memoryModelContent = fs.readFileSync(MEMORY_MODEL_FILE, 'utf8');
  assert.match(
    memoryModelContent,
    /export\s+interface\s+Memory\s*\{[\s\S]*expires_at\?: string;/m,
    'Memory interface must include expires_at?: string'
  );
  assert.match(
    memoryModelContent,
    /export\s+(function\s+isMemoryExpired|\{\s*isMemoryExpired\s*\}|const\s+isMemoryExpired)/,
    'memoryModel.ts must export isMemoryExpired function'
  );

  const memoryListContent = fs.readFileSync(MEMORY_LIST_FILE, 'utf8');
  assert.ok(
    memoryListContent.includes('const visibleRows = (activeTab === \'proposals\' ? rows.filter(m => !isMemoryExpired(m)) : rows)'),
    'MemoryListPage.tsx must filter visibleRows for proposals tab using isMemoryExpired'
  );
  assert.ok(
    memoryListContent.includes('!isMemoryExpired(m)'),
    'MemoryListPage.tsx must exclude expired memories'
  );

  const cardsPanelContent = fs.readFileSync(CARDS_PANEL_FILE, 'utf8');
  assert.match(
    cardsPanelContent,
    /export\s+(function\s+isCardExpired|\{\s*isCardExpired\s*\}|const\s+isCardExpired)/,
    'CardsPanel.tsx must export isCardExpired function'
  );
  assert.ok(
    cardsPanelContent.includes('card.status === \'pending\' && !isCardExpired(card)'),
    'CardsPanel.tsx must exclude expired cards from pendingCount'
  );
  assert.ok(
    cardsPanelContent.includes('statusFilter === \'pending\' && isCardExpired(card)'),
    'CardsPanel.tsx must exclude expired cards when statusFilter is pending'
  );

  const cardsEndpointContent = fs.readFileSync(CARDS_ENDPOINT_FILE, 'utf8');
  assert.match(
    cardsEndpointContent,
    /export\s*\{\s*isCardExpired\s*\}\s*from/,
    'cards.ts must export isCardExpired'
  );
});

test('REQ-EXPIRY-UI-3: isMemoryExpired accurately detects past ISO timestamps', async () => {
  const { isMemoryExpired } = await import('../src/ui/utils/expiry.ts');

  // Past timestamp -> true
  assert.equal(isMemoryExpired({ expires_at: '2020-01-01T00:00:00.000Z' }), true);
  assert.equal(isMemoryExpired({ expires_at: new Date(Date.now() - 60000).toISOString() }), true);
  assert.equal(isMemoryExpired({ expires_at: new Date(Date.now() - 1000).toISOString() }), true);

  // Future timestamp -> false
  assert.equal(isMemoryExpired({ expires_at: '2099-01-01T00:00:00.000Z' }), false);
  assert.equal(isMemoryExpired({ expires_at: new Date(Date.now() + 60000).toISOString() }), false);
  assert.equal(isMemoryExpired({ expires_at: new Date(Date.now() + 86400000).toISOString() }), false);

  // Empty string / missing / null / undefined / invalid -> false
  assert.equal(isMemoryExpired({ expires_at: '' }), false);
  assert.equal(isMemoryExpired({ expires_at: '   ' }), false);
  assert.equal(isMemoryExpired({ expires_at: undefined }), false);
  assert.equal(isMemoryExpired({}), false);
  assert.equal(isMemoryExpired(null), false);
  assert.equal(isMemoryExpired(undefined), false);
  assert.equal(isMemoryExpired({ expires_at: 'not-a-valid-date' }), false);

  // Supports normalized camelCase expiresAt fallback
  assert.equal(isMemoryExpired({ expiresAt: '2020-01-01T00:00:00.000Z' } as any), true);
  assert.equal(isMemoryExpired({ expiresAt: '2099-01-01T00:00:00.000Z' } as any), false);
});

test('REQ-EXPIRY-UI-3: isCardExpired accurately detects past ISO timestamps', async () => {
  const { isCardExpired } = await import('../src/ui/utils/expiry.ts');

  // Past timestamp -> true
  assert.equal(isCardExpired({ ttl_at: '2020-01-01T00:00:00.000Z' }), true);
  assert.equal(isCardExpired({ ttl_at: new Date(Date.now() - 60000).toISOString() }), true);
  assert.equal(isCardExpired({ ttl_at: new Date(Date.now() - 1000).toISOString() }), true);

  // Future timestamp -> false
  assert.equal(isCardExpired({ ttl_at: '2099-01-01T00:00:00.000Z' }), false);
  assert.equal(isCardExpired({ ttl_at: new Date(Date.now() + 60000).toISOString() }), false);
  assert.equal(isCardExpired({ ttl_at: new Date(Date.now() + 86400000).toISOString() }), false);

  // Empty string / missing / null / undefined / invalid -> false
  assert.equal(isCardExpired({ ttl_at: '' }), false);
  assert.equal(isCardExpired({ ttl_at: '   ' }), false);
  assert.equal(isCardExpired({ ttl_at: undefined }), false);
  assert.equal(isCardExpired({}), false);
  assert.equal(isCardExpired(null), false);
  assert.equal(isCardExpired(undefined), false);
  assert.equal(isCardExpired({ ttl_at: 'not-a-valid-date' }), false);
});

test('REQ-EXPIRY-UI-3: Expired pending memories are excluded from proposals list and count, unexpired remain visible', async () => {
  const { isMemoryExpired } = await import('../src/ui/utils/expiry.ts');

  const memories = [
    {
      id: 'mem_1',
      title: 'Expired Pending Memory 1',
      status: 'pending',
      expires_at: '2021-01-01T00:00:00Z',
    },
    {
      id: 'mem_2',
      title: 'Expired Pending Memory 2',
      status: 'pending',
      expires_at: new Date(Date.now() - 3600000).toISOString(),
    },
    {
      id: 'mem_3',
      title: 'Unexpired Pending Memory with future date',
      status: 'pending',
      expires_at: new Date(Date.now() + 86400000).toISOString(),
    },
    {
      id: 'mem_4',
      title: 'Unexpired Pending Memory with no expiry',
      status: 'pending',
    },
    {
      id: 'mem_5',
      title: 'Active Memory with past date',
      status: 'active',
      expires_at: '2020-01-01T00:00:00Z',
    },
  ];

  // Under 'proposals' tab, expired memories must be excluded
  const activeTabProposals = 'proposals';
  const visibleProposals = activeTabProposals === 'proposals'
    ? memories.filter(m => !isMemoryExpired(m))
    : memories;

  assert.equal(visibleProposals.length, 2);
  assert.deepEqual(visibleProposals.map(m => m.id), ['mem_3', 'mem_4']);

  // Only pending unexpired proposals:
  const pendingUnexpiredProposals = memories
    .filter(m => m.status === 'pending')
    .filter(m => !isMemoryExpired(m));
  assert.equal(pendingUnexpiredProposals.length, 2);
  assert.deepEqual(pendingUnexpiredProposals.map(m => m.id), ['mem_3', 'mem_4']);

  // Probed page filter excludes expired pending items
  const probedPendingPage = {
    items: memories.filter(m => m.status === 'pending'),
  };
  const filteredProbedItems = probedPendingPage.items.filter(m => !isMemoryExpired(m));
  assert.equal(filteredProbedItems.length, 2);

  // If all pending items were expired, proposals tab would have 0 items
  const allExpired = [
    { id: 'exp_1', status: 'pending', expires_at: '2020-01-01T00:00:00Z' },
    { id: 'exp_2', status: 'pending', expires_at: '2021-01-01T00:00:00Z' },
  ];
  const filteredAllExpired = allExpired.filter(m => !isMemoryExpired(m));
  assert.equal(filteredAllExpired.length, 0);

  // Under 'active' tab, activeTab !== 'proposals' does not filter by isMemoryExpired
  const activeTabActive = 'active';
  const visibleActive = activeTabActive === 'proposals'
    ? memories.filter(m => !isMemoryExpired(m))
    : memories;
  assert.equal(visibleActive.length, memories.length);
});

test('REQ-EXPIRY-UI-3: Expired pending action cards are excluded from pending cards list and pendingCount, unexpired remain visible', async () => {
  const { isCardExpired } = await import('../src/ui/utils/expiry.ts');

  const cards = [
    {
      card_id: 'crd_expired_1',
      title: 'Expired Card 1',
      status: 'pending',
      ttl_at: '2022-01-01T00:00:00Z',
      project_id: 'proj_1',
      operations: [],
      source_refs: [],
      confidence: 0.9,
    },
    {
      card_id: 'crd_expired_2',
      title: 'Expired Card 2',
      status: 'pending',
      ttl_at: new Date(Date.now() - 5000).toISOString(),
      project_id: 'proj_1',
      operations: [],
      source_refs: [],
      confidence: 0.8,
    },
    {
      card_id: 'crd_valid_pending_1',
      title: 'Valid Pending Card 1',
      status: 'pending',
      ttl_at: new Date(Date.now() + 3600000).toISOString(),
      project_id: 'proj_1',
      operations: [],
      source_refs: [],
      confidence: 0.95,
    },
    {
      card_id: 'crd_valid_pending_2',
      title: 'Valid Pending Card 2 (no ttl)',
      status: 'pending',
      project_id: 'proj_1',
      operations: [],
      source_refs: [],
      confidence: 0.85,
    },
    {
      card_id: 'crd_accepted_1',
      title: 'Accepted Card',
      status: 'accepted',
      ttl_at: '2022-01-01T00:00:00Z',
      project_id: 'proj_1',
      operations: [],
      source_refs: [],
      confidence: 0.99,
    },
  ];

  // Emulate CardsPanel.tsx groupedCards and pendingCount computation
  function computeCardsPanelMetrics(cardsList: typeof cards, statusFilter: string) {
    let pending = 0;
    const filteredCards: typeof cards = [];

    for (const card of cardsList) {
      if (card.status === 'pending' && !isCardExpired(card)) {
        pending += 1;
      }

      // Status filter
      if (statusFilter !== 'all') {
        if (card.status !== statusFilter) {
          continue;
        }
        if (statusFilter === 'pending' && isCardExpired(card)) {
          continue;
        }
      }

      filteredCards.push(card);
    }

    return { pendingCount: pending, filteredCards };
  }

  // 1. Pending view:
  const pendingView = computeCardsPanelMetrics(cards, 'pending');
  // pendingCount must ONLY count unexpired pending cards (2)
  assert.equal(pendingView.pendingCount, 2);
  // filteredCards must ONLY contain unexpired pending cards
  assert.equal(pendingView.filteredCards.length, 2);
  assert.deepEqual(
    pendingView.filteredCards.map(c => c.card_id),
    ['crd_valid_pending_1', 'crd_valid_pending_2']
  );

  // 2. All cards view:
  const allView = computeCardsPanelMetrics(cards, 'all');
  // pendingCount is still 2
  assert.equal(allView.pendingCount, 2);
  // All 5 cards are retained in All view
  assert.equal(allView.filteredCards.length, 5);

  // 3. Accepted view:
  const acceptedView = computeCardsPanelMetrics(cards, 'accepted');
  assert.equal(acceptedView.pendingCount, 2);
  assert.equal(acceptedView.filteredCards.length, 1);
  assert.equal(acceptedView.filteredCards[0].card_id, 'crd_accepted_1');
});
