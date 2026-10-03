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

test('REQ-MOBILE-SLIM-SIDEBAR-11: AppShell removes MobileTabBar and mobileBottomPadded completely', () => {
  const content = fs.readFileSync(APP_SHELL_FILE, 'utf8');
  assert.ok(
    !content.includes('<MobileTabBar'),
    'AppShell must not render MobileTabBar'
  );
  assert.ok(
    !content.includes('mobileBottomPadded'),
    'AppShell must not use or define mobileBottomPadded'
  );
  assert.ok(
    !content.includes('--ui-bottom-chrome'),
    'AppShell must not calculate padding based on --ui-bottom-chrome'
  );
});

test('REQ-MOBILE-SLIM-SIDEBAR-11: AppShell implements slim mobile left sidebar with toggle and touch targets', () => {
  const content = fs.readFileSync(APP_SHELL_FILE, 'utf8');
  assert.ok(
    !content.includes('-translate-x-full'),
    'AppShell must not hide the left sidebar off-canvas with -translate-x-full'
  );
  assert.ok(
    content.includes('isEffectiveCollapsed'),
    'AppShell must compute isEffectiveCollapsed considering isMobile and drawerOpen'
  );
  assert.ok(
    content.includes('isMobile ? !drawerOpen : collapsed'),
    'AppShell must collapse mobile sidebar when drawer is not open'
  );
  assert.ok(
    content.includes('shell-sidebar-collapse-toggle'),
    'AppShell must provide a toggle button to expand/collapse sidebar'
  );
  assert.ok(
    content.includes('min-h-11 items-center gap-3 rounded-xl px-2.5 py-2'),
    'NavItem must enforce touch-friendly min-h-11 targets'
  );
  assert.ok(
    content.includes('w-16 shrink-0 md:hidden'),
    'AppShell must reserve space on mobile for the slim left sidebar'
  );
});

test('REQ-CLUB-RUN-COMMANDS-13: groupTranscriptMessages clubs consecutive shell_run messages (>= 2) and keeps single runs standalone', async () => {
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeRun = (id: string, sessionId: string, time: number): any => ({
    key: id,
    messageId: id,
    body: '',
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'shell_run',
    metadata: { session_id: sessionId },
  });

  const makeUser = (id: string, text: string): any => ({
    key: id,
    messageId: id,
    body: text,
    isUser: true,
    createdUnixMs: 1000,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: 'you',
    messageType: 'text',
  });

  // 3 consecutive runs -> 1 clubbed group
  const input1 = [
    makeRun('r1', 's1', 1000),
    makeRun('r2', 's2', 2000),
    makeRun('r3', 's3', 3000),
  ];
  const out1 = groupTranscriptMessages(input1);
  assert.equal(out1.length, 1);
  assert.equal(out1[0].messageType, 'shell_run_group');
  assert.equal(out1[0].metadata?.count, 3);
  assert.equal(out1[0].metadata?.clubbedRuns.length, 3);

  // Single isolated run -> stays 1 shell_run
  const input2 = [
    makeUser('u1', 'hello'),
    makeRun('r1', 's1', 1000),
    makeUser('u2', 'world'),
  ];
  const out2 = groupTranscriptMessages(input2);
  assert.equal(out2.length, 3);
  assert.equal(out2[1].messageType, 'shell_run');

  // Consecutive runs with pinned session filtered out
  const input3 = [
    makeRun('r1', 's1', 1000),
    makeRun('r2', 's2', 2000),
    makeRun('r3', 's3_pinned', 3000),
  ];
  const out3 = groupTranscriptMessages(input3, new Set(['s3_pinned']));
  assert.equal(out3.length, 1);
  assert.equal(out3[0].messageType, 'shell_run_group');
  assert.equal(out3[0].metadata?.count, 2);
});

test('REQ-CLUB-RUN-COMMANDS-13: ShellRunIndicator exports ClubbedRunGroup with label, time range, chevron, and expansion', () => {
  const content = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shells/ShellRunIndicator.tsx'), 'utf8');

  assert.ok(content.includes('export function ClubbedRunGroup'), 'Must export ClubbedRunGroup');
  assert.ok(content.includes('data-debug-id="clubbed-run-group"'), 'Must have clubbed-run-group debug ID');
  assert.ok(content.includes('data-debug-id="clubbed-run-group-toggle"'), 'Must have toggle button with clubbed-run-group-toggle');
  assert.ok(content.includes('Ran {count} commands'), 'Must display Ran {count} commands');
  assert.ok(content.includes('{expanded ? \'⌄\' : \'›\'}'), 'Must toggle chevron between › and ⌄');
  assert.ok(content.includes('data-debug-id="clubbed-run-group-items"'), 'Must render clubbed-run-group-items when expanded');
  assert.ok(content.includes('defaultExpanded={false}'), 'Inner ShellRunRows must default to collapsed');
});

test('REQ-SUBTLE-AGENT-START-14: groupTranscriptMessages clubs consecutive start messages and ConversationThreadPage renders subtle dividers', async () => {
  const { groupTranscriptMessages, isAgentStartMessage } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeSystem = (id: string, body: string, time: number): any => ({
    key: id,
    messageId: id,
    body,
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'system',
  });

  const msg1 = makeSystem('sys1', 'Agent has started and is ready.', 1000);
  const msg2 = makeSystem('sys2', 'Agent has started and is ready.', 2000);
  assert.ok(isAgentStartMessage(msg1), 'Must identify system start message');

  // Single start message -> isolated
  const single = groupTranscriptMessages([msg1]);
  assert.equal(single.length, 1);
  assert.equal(single[0].messageType, 'system');

  // Consecutive start messages -> clubbed into agent_start_clubbed
  const clubbed = groupTranscriptMessages([msg1, msg2]);
  assert.equal(clubbed.length, 1);
  assert.equal(clubbed[0].messageType, 'agent_start_clubbed');
  assert.equal(clubbed[0].metadata?.count, 2);

  // Check ConversationThreadPage source
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(
    !threadContent.includes('.filter((message) => message.messageType !== \'system\')'),
    'ConversationThreadPage must not filter out system messages from chatMessages'
  );
  assert.ok(
    threadContent.includes('border-t border-subtle/40'),
    'Subtle start divider must use border-t border-subtle/40'
  );
  assert.ok(
    threadContent.includes('text-faint text-[11px] font-mono') || threadContent.includes('font-mono text-[11px] text-faint'),
    'Subtle start divider must use faint font-mono styling'
  );
  assert.ok(
    threadContent.includes('agent started ({time})'),
    'Isolated start divider must format as agent started ({time})'
  );
  assert.ok(
    threadContent.includes('agent started {count} times ({timeStr})'),
    'Clubbed start divider must format as agent started {count} times ({timeStr})'
  );
});

test('REQ-AUTO-STARTUP-PANE-16: ConversationThreadPage auto-expands capture pane during starting phase and auto-collapses on running', () => {
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.ok(
    threadContent.includes('userManuallyToggledPaneRef'),
    'ConversationThreadPage must have userManuallyToggledPaneRef to track manual overrides'
  );
  assert.ok(
    threadContent.includes('isStarting') && threadContent.includes('setIsPaneExpanded(true)'),
    'Must auto-expand capture pane when entering starting phase'
  );
  assert.ok(
    threadContent.includes('isLive') && threadContent.includes('setIsPaneExpanded(false)'),
    'Must auto-collapse capture pane when transitioning to running / live'
  );
  assert.ok(
    threadContent.includes('userManuallyToggledPaneRef.current = true;'),
    'Manual pane button clicks or panel toggles must set userManuallyToggledPaneRef to true'
  );
});



