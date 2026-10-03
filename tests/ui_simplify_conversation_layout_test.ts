import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const BUBBLES_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/AgentActivityBubbles.tsx');
const CHAT_LIST_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ChatMessageList.tsx');
const THREAD_PAGE_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');
const CHAIN_OVERVIEW_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ChainOverviewPanel.tsx');
const APP_SHELL_FILE = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');

test('REQ-SIMPLIFY-GUTTER-3: AgentActivityBubbles returns null when empty with no reserved empty gutter', () => {
  const content = fs.readFileSync(BUBBLES_FILE, 'utf8');
  assert.ok(
    content.includes('if (visible.length === 0) return null;'),
    'AgentActivityBubbles must return null when visible.length === 0'
  );
  assert.ok(
    !content.includes('// Reserved fixed-height gutter: ALWAYS rendered (even when empty)'),
    'Reserved fixed-height empty gutter comment/behavior must be removed'
  );
});

test('REQ-SIMPLIFY-LAYOUT-1 & REQ-SIMPLIFY-SCROLL-4: ChatMessageList accepts footer prop and renders inside scroll container', () => {
  const content = fs.readFileSync(CHAT_LIST_FILE, 'utf8');
  assert.ok(
    content.includes('footer?: ReactNode'),
    'ChatMessageList must accept footer prop'
  );
  assert.ok(
    content.includes('{footer}') && content.includes('{agentIsWorking && ('),
    'footer must be rendered inside messages-container after agentIsWorking'
  );
  assert.ok(
    !content.includes('data-debug-id={`${debugPrefix}-mobile-bottom-spacer`}'),
    'mobile-bottom-spacer must be completely removed from ChatMessageList'
  );
  assert.ok(
    !content.includes('pt-16 pb-4 sm:space-y-4'),
    'artificial pt-16 overlay padding must be removed from default scrollClassName'
  );
});

test('REQ-SIMPLIFY-COMPOSER-2 & REQ-SIMPLIFY-SCROLL-4: ConversationThreadPage unifies layout into single scroll flow and removes mobile chrome smartness', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Unified footer passed to ChatMessageList
  assert.ok(
    content.includes('footer={(') && content.includes('<AgentActivityBubbles instanceId={agentInstanceId} />') && content.includes('<PinnedShellRuns sessions={pinnedRuns} />') && content.includes('{renderComposer()}'),
    'ConversationThreadPage must pass bubbles, pinned shell runs, and composer as footer to ChatMessageList'
  );

  // Composer form is in-flow, not fixed
  assert.ok(
    content.includes('className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"'),
    'Composer form must use normal in-flow container styling'
  );
  assert.ok(
    !content.includes('fixed bottom-14 inset-x-0 z-20'),
    'Composer must not use fixed bottom-14 overlay classes'
  );
  assert.ok(
    !content.includes('keyboardAwareBottomPx'),
    'keyboardAwareBottomPx must be removed from composer form'
  );

  // Mobile scroll hide/reveal removed
  assert.ok(
    !content.includes('handleTranscriptScroll'),
    'handleTranscriptScroll must be removed'
  );
  assert.ok(
    !content.includes('chromeVisible'),
    'chromeVisible state must be removed'
  );
  assert.ok(
    !content.includes('restoreChrome'),
    'restoreChrome must be removed'
  );
  assert.ok(
    !content.includes('heimdall:mobile-chrome'),
    'heimdall:mobile-chrome custom events must not be dispatched from ConversationThreadPage'
  );

  // Floating pills removed
  assert.ok(
    !content.includes('data-debug-id="conversation-floating-panel-toggle-btn"'),
    'conversation-floating-panel-toggle-btn must be removed'
  );
  assert.ok(
    !content.includes('data-debug-id="conversation-floating-agent-pill"'),
    'conversation-floating-agent-pill must be removed'
  );
  assert.ok(
    !content.includes('data-debug-id="conversation-floating-reply-pill"'),
    'conversation-floating-reply-pill must be removed'
  );

  // Header stays at top of Col 1 without scroll translation
  assert.ok(
    content.includes('data-debug-id="conversation-thread-header"'),
    'conversation-thread-header must exist'
  );
  assert.ok(
    !content.includes('-translate-y-full opacity-0 pointer-events-none'),
    'Header must not hide/translate on scroll'
  );
});

test('REQ-HEADER-SEPARATOR-7: ConversationThreadPage header removes horizontal border-b separator', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(
    content.includes('data-debug-id="conversation-thread-header"'),
    'conversation-thread-header must exist'
  );
  assert.ok(
    !content.includes('border-b border-subtle/50'),
    'conversation-thread-header must not have border-b border-subtle/50'
  );
});

test('REQ-CHAIN-SUMMARY-SELECTED-BORDER-8: ChainOverviewPanel highlights selected agent instead of coordinator', () => {
  const content = fs.readFileSync(CHAIN_OVERVIEW_FILE, 'utf8');
  assert.ok(
    content.includes('instId === agentInstanceId'),
    'ChainOverviewPanel must check instId === agentInstanceId for active card selection'
  );
  assert.ok(
    !content.includes('const coordinatorClasses = isCoordinator'),
    'ChainOverviewPanel must not style card based on isCoordinator'
  );
  assert.ok(
    content.includes('border-accent/50 bg-gradient-to-br from-accent/10 to-accent/5 ring-1 ring-accent/20'),
    'ChainOverviewPanel must use active accent styling for selected agent'
  );
});

test('REQ-SWITCH-AGENT-PERSIST-SIDEBAR-9: AppShell avoids unmounting ConversationThreadPage across transitions in same chain', () => {
  const content = fs.readFileSync(APP_SHELL_FILE, 'utf8');
  assert.ok(
    content.includes('findChainIdForInstance'),
    'AppShell must define findChainIdForInstance to resolve chain ID for instances'
  );
  assert.ok(
    content.includes('activeChainId'),
    'AppShell must compute activeChainId for conversation route'
  );
  assert.ok(
    content.includes('key={threadKey}'),
    'AppShell must key ConversationThreadPage by activeChainId to persist sidebar during intra-chain switches'
  );
  assert.ok(
    !content.includes('<ConversationThreadPage key={agentInstanceId}'),
    'AppShell must not blindly key ConversationThreadPage by raw agentInstanceId'
  );
});

test('REQ-SIDEBAR-TOGGLE-SINGLE-CLICK-10: ConversationThreadPage auto-open effect excludes rightPanel and fixes double-click toggle bug', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  // Auto-open effect deps must not contain rightPanel
  assert.ok(
    !content.includes('[chainId, isMobile, rightPanel]'),
    'Auto-open useEffect must not include rightPanel in dependency array'
  );
  assert.ok(
    content.includes('chainAutoOpenedRef.current = true;'),
    'Auto-open effect must mark chainAutoOpenedRef as true once upon initial check'
  );
  assert.ok(
    content.includes('heimdall:sidebar:open:chain:'),
    'Auto-open effect must check persisted chain sidebar open state'
  );
});

