// REQ-MOBILE-COMPOSER-UI-28 & REQ-COMPOSER-INPUT-PERSIST-29:
// Unit and regression tests for mobile composer layout overhaul and cross-agent input persistence.
//
// RUN: npx tsx tests/ui_composer_mobile_persistence_test.ts
//  OR: node --test tests/ui_composer_mobile_persistence_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const THREAD_PAGE_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');

test('REQ-COMPOSER-INPUT-PERSIST-29: COMPOSER_DRAFT_KEY is exported and equals "heimdall:composer:draft"', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /export\s+const\s+COMPOSER_DRAFT_KEY\s*=\s*['"]heimdall:composer:draft['"];?/,
    'ConversationThreadPage must export COMPOSER_DRAFT_KEY = "heimdall:composer:draft"'
  );
});

test('REQ-COMPOSER-INPUT-PERSIST-29: draft state initializes lazily from localStorage', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Must have lazy initializer reading localStorage with COMPOSER_DRAFT_KEY
  assert.ok(
    content.includes('localStorage.getItem(COMPOSER_DRAFT_KEY)'),
    'draft state must lazily read window.localStorage.getItem(COMPOSER_DRAFT_KEY)'
  );
  assert.match(
    content,
    /const\s*\[draft,\s*setDraft\]\s*=\s*useState<string>\s*\(\s*\(\)\s*=>\s*\{[^}]*localStorage\.getItem\(COMPOSER_DRAFT_KEY\)/s,
    'useState(draft) must use a lazy initializer function reading COMPOSER_DRAFT_KEY'
  );
});

test('REQ-COMPOSER-INPUT-PERSIST-29: updateDraft synchronizes draft state and localStorage', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.ok(
    content.includes('const updateDraft = useCallback('),
    'ConversationThreadPage must define an updateDraft callback'
  );
  assert.ok(
    content.includes('localStorage.setItem(COMPOSER_DRAFT_KEY, value)'),
    'updateDraft must set localStorage when value is present'
  );
  assert.ok(
    content.includes('localStorage.removeItem(COMPOSER_DRAFT_KEY)'),
    'updateDraft must remove localStorage key when value is empty'
  );
});

test('REQ-COMPOSER-INPUT-PERSIST-29: textarea onChange and submit() use updateDraft', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Textarea onChange
  assert.ok(
    content.includes('updateDraft(e.target.value)'),
    'Textarea onChange must call updateDraft(e.target.value)'
  );

  // submit() clears draft and storage
  assert.match(
    content,
    /async\s+function\s+submit\([^)]*\)\s*\{[\s\S]*?updateDraft\(['"]['"]\)[\s\S]*?\}/,
    'submit() must call updateDraft("") to clear both state and localStorage'
  );
});

test('REQ-COMPOSER-INPUT-PERSIST-29: useEffect([routeInstanceId]) does NOT clear draft or attachments on agent switch', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Find the useEffect([routeInstanceId]) block
  const routeEffectMatch = content.match(
    /useEffect\(\(\)\s*=>\s*\{([^}]*?)\},\s*\[routeInstanceId\]\);/
  );
  assert.ok(routeEffectMatch, 'ConversationThreadPage must contain useEffect([routeInstanceId])');

  const effectBody = routeEffectMatch[1];
  assert.ok(
    !effectBody.includes('setDraft('),
    'useEffect([routeInstanceId]) must NOT call setDraft("") when switching agents'
  );
  assert.ok(
    !effectBody.includes('updateDraft('),
    'useEffect([routeInstanceId]) must NOT call updateDraft("") when switching agents'
  );
  assert.ok(
    !effectBody.includes('setAttachments('),
    'useEffect([routeInstanceId]) must NOT call setAttachments([]) so attachments persist across agent switching'
  );
});

test('REQ-MOBILE-COMPOSER-UI-28: textarea placeholder dynamically adapts for mobile vs desktop', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /placeholder=\{isMobile\s*\?\s*['"]Message the agent…['"]\s*:\s*['"]Message the agent… \(Cmd\/Ctrl\+Enter to send\)['"]\}/,
    'Composer textarea placeholder must omit keyboard shortcuts on mobile'
  );
});

test('REQ-MOBILE-COMPOSER-UI-28: context header uses min-w-0 and truncation for mobile cleanliness', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /data-debug-id="conversation-composer-context"[^>]*min-w-0/,
    'conversation-composer-context must have min-w-0'
  );
  assert.match(
    content,
    /data-debug-id="conversation-composer-bridge-chip"[^>]*min-w-0/,
    'conversation-composer-bridge-chip must have min-w-0'
  );
});

test('REQ-MOBILE-COMPOSER-UI-28: toolbar implements 2-row mobile structure with anchored Send button and 1-row desktop structure', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Verify responsive container structure
  assert.ok(
    content.includes('flex flex-col gap-2 sm:mt-1 sm:flex-row sm:items-center sm:gap-1.5 min-w-0'),
    'Toolbar container must use flex flex-col on mobile and sm:flex-row on desktop'
  );

  // Row 1 (Agent chip + Model switcher side-by-side with full width under textarea)
  assert.match(
    content,
    /Mobile Row 1: Agent chip and Model switcher side-by-side with full width/,
    'Toolbar must have comment/structure for Mobile Row 1 side-by-side controls'
  );
  assert.ok(
    content.includes('w-full min-w-0 items-center gap-1.5 sm:contents'),
    'Row 1 must span full width on mobile and unwrap with sm:contents on desktop'
  );

  // Row 2 (Attach + Terminal on left, Send button anchored to bottom-right)
  assert.ok(
    content.includes('flex w-full min-w-0 items-center justify-between sm:contents'),
    'Row 2 must use justify-between on mobile to anchor Send button firmly to the bottom-right corner'
  );

  // Send button styling
  assert.match(
    content,
    /data-debug-id="conversation-composer-send-btn"[^>]*bg-accent[^>]*sm:order-7/,
    'Send button must be blue accent and have sm:order-7 on desktop'
  );

  // Desktop spacers
  assert.ok(
    content.includes('hidden sm:block flex-1 min-w-[8px] sm:order-3'),
    'Spacer 1 must be hidden on mobile and sm:order-3 on desktop'
  );
  assert.ok(
    content.includes('hidden sm:block flex-1 min-w-[8px] sm:order-5'),
    'Spacer 2 must be hidden on mobile and sm:order-5 on desktop'
  );
});

test('REQ-MOBILE-COMPOSER-UI-28: all required debug IDs are preserved', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  const requiredDebugIds = [
    'conversation-attach-btn',
    'conversation-request-pane-btn',
    'conversation-agent-picker-btn',
    'conversation-runtime-menu-btn',
    'conversation-composer-send-btn',
  ];

  for (const id of requiredDebugIds) {
    assert.ok(
      content.includes(`data-debug-id="${id}"`),
      `Toolbar must preserve data-debug-id="${id}"`
    );
  }
});

test('Regression safeguard: outer form container className is preserved', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.ok(
    content.includes('className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"'),
    'Form container className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4" must not be modified'
  );
});
