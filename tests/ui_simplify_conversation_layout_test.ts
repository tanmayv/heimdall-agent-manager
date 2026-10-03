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
const BOTTOM_DOCK_FILE = path.join(REPO_ROOT, 'src/ui/components/shell/BottomDock.tsx');
const MESSAGE_ITEM_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/MessageItem.tsx');
const CHAT_MESSAGE_ITEM_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ChatMessageItem.tsx');
const CTL_AGENT_MODE_FILE = path.join(REPO_ROOT, 'src/ctl/agent_mode.odin');
const HUB_AGENT_ACTION_FILE = path.join(REPO_ROOT, 'src/hub/transport/http/agent_action_handlers.odin');
const HUB_CONTENT_SERVICE_FILE = path.join(REPO_ROOT, 'src/hub/service/content/content_service.odin');
const SHELL_TERMINAL_PANE_FILE = path.join(REPO_ROOT, 'src/ui/components/shells/ShellTerminalPane.tsx');
const CHAT_ACTION_CARD_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ChatActionCard.tsx');
const CARDS_ENDPOINT_FILE = path.join(REPO_ROOT, 'src/ui/api/endpoints/cards.ts');

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

test('REQ-AUTO-STARTUP-PANE-24: ConversationThreadPage connects stream during startup, expands on output, and auto-collapses on startup_status ready', () => {
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  const composerContent = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chat/AgentPaneComposerPanel.tsx'), 'utf8');

  assert.ok(
    threadContent.includes('userManuallyToggledPaneRef'),
    'ConversationThreadPage must have userManuallyToggledPaneRef to track manual overrides'
  );
  assert.ok(
    threadContent.includes('startupStatus') && threadContent.includes('startup_status'),
    'ConversationThreadPage must read startupStatus from instance / conversation'
  );
  assert.ok(
    threadContent.includes('isStarting') && threadContent.includes('onStreamOutput'),
    'ConversationThreadPage must track isStarting and wire onStreamOutput'
  );
  assert.ok(
    threadContent.includes("startupStatus === 'ready'") && threadContent.includes('setIsPaneExpanded(false)'),
    'Must auto-collapse capture pane when agent calls start success (startupStatus ready)'
  );
  assert.ok(
    threadContent.includes('userManuallyToggledPaneRef.current = true;'),
    'Manual pane button clicks or panel toggles must set userManuallyToggledPaneRef to true'
  );

  // AgentPaneComposerPanel contracts for REQ-AUTO-STARTUP-PANE-24
  assert.ok(
    composerContent.includes('(isExpanded || isStarting) && isActiveTab'),
    'AgentPaneComposerPanel must connect stream when isExpanded or isStarting'
  );
  assert.ok(
    composerContent.includes('onStreamOutputRef.current?.()') || composerContent.includes('onStreamOutput'),
    'AgentPaneComposerPanel must invoke onStreamOutput callback when streaming output arrives'
  );
  assert.ok(
    composerContent.includes('Starting agent…'),
    'AgentPaneComposerPanel must display subtle Starting agent… indicator while awaiting initial output'
  );
});

// ---------------------------------------------------------------------------
// REQ-TEST-VERIFICATION-17: Regression tests for command clubbing, start indicators,
// and auto-startup capture pane
// ---------------------------------------------------------------------------

test('REQ-TEST-VERIFICATION-17: Consecutive shell_run messages (>= 2) group with count and formatted start/end time range', async () => {
  const {
    groupTranscriptMessages,
    formatClubbedTimeRange,
    formatClubbedRunLabel,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeRun = (id: string, time: number): any => ({
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
    metadata: { session_id: `sess_${id}` },
  });

  const mockFormatTimestamp = (ms: number) => {
    const d = new Date(ms);
    const hours = d.getUTCHours();
    const minutes = String(d.getUTCMinutes()).padStart(2, '0');
    return { label: `${hours}:${minutes} UTC`, iso: d.toISOString() };
  };

  // 1. Grouping 2 consecutive runs
  const runs2 = [
    makeRun('run-1', 1700000000000),
    makeRun('run-2', 1700000300000),
  ];
  const grouped2 = groupTranscriptMessages(runs2);
  assert.equal(grouped2.length, 1);
  assert.equal(grouped2[0].messageType, 'shell_run_group');
  assert.equal(grouped2[0].metadata?.count, 2);
  assert.equal(grouped2[0].metadata?.startUnixMs, 1700000000000);
  assert.equal(grouped2[0].metadata?.endUnixMs, 1700000300000);
  assert.equal(formatClubbedRunLabel(grouped2[0].metadata?.count), 'Ran 2 commands');
  const timeRange2 = formatClubbedTimeRange(
    grouped2[0].metadata?.startUnixMs,
    grouped2[0].metadata?.endUnixMs,
    mockFormatTimestamp,
  );
  assert.equal(timeRange2, '22:13 UTC \u2013 22:18 UTC');

  // 2. Grouping 4 consecutive runs with multiple intervals
  const runs4 = [
    makeRun('run-a', 1700000000000),
    makeRun('run-b', 1700000100000),
    makeRun('run-c', 1700000200000),
    makeRun('run-d', 1700000600000),
  ];
  const grouped4 = groupTranscriptMessages(runs4);
  assert.equal(grouped4.length, 1);
  assert.equal(grouped4[0].messageType, 'shell_run_group');
  assert.equal(grouped4[0].metadata?.count, 4);
  assert.equal(grouped4[0].metadata?.clubbedRuns.length, 4);
  assert.equal(formatClubbedRunLabel(grouped4[0].metadata?.count), 'Ran 4 commands');
  const timeRange4 = formatClubbedTimeRange(
    grouped4[0].metadata?.startUnixMs,
    grouped4[0].metadata?.endUnixMs,
    mockFormatTimestamp,
  );
  assert.equal(timeRange4, '22:13 UTC \u2013 22:23 UTC');

  // 3. Same start and end timestamp returns single time formatted
  const sameTimeRange = formatClubbedTimeRange(
    1700000000000,
    1700000000000,
    mockFormatTimestamp,
  );
  assert.equal(sameTimeRange, '22:13 UTC');
});

test('REQ-TEST-VERIFICATION-17: Group toggle expands/collapses the full command list', async () => {
  const {
    createClubbedGroupState,
    toggleClubbedGroup,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  // Initial state is collapsed
  let state = createClubbedGroupState(false);
  assert.equal(state.isGroupExpanded, false, 'Group must default to collapsed');

  // Toggle opens
  state = toggleClubbedGroup(state);
  assert.equal(state.isGroupExpanded, true, 'First toggle must expand group');

  // Toggle closes
  state = toggleClubbedGroup(state);
  assert.equal(state.isGroupExpanded, false, 'Second toggle must collapse group');

  // Component structure checks for ClubbedRunGroup in ShellRunIndicator.tsx
  const shellRunContent = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shells/ShellRunIndicator.tsx'), 'utf8');
  assert.ok(
    shellRunContent.includes('data-debug-id="clubbed-run-group-toggle"'),
    'ClubbedRunGroup must provide clubbed-run-group-toggle button'
  );
  assert.ok(
    shellRunContent.includes('aria-expanded={expanded}'),
    'Toggle button must bind aria-expanded={expanded}'
  );
  assert.ok(
    shellRunContent.includes('{expanded ? \'⌄\' : \'›\'}'),
    'Toggle chevron must reflect expanded state (› collapsed, ⌄ expanded)'
  );
  assert.ok(
    shellRunContent.includes('{expanded && (') && shellRunContent.includes('data-debug-id="clubbed-run-group-items"'),
    'clubbed-run-group-items container must only render when expanded is true'
  );

  // ChatMessageList suppresses card bubble chrome for clubbed groups
  const chatListContent = fs.readFileSync(CHAT_LIST_FILE, 'utf8');
  assert.ok(
    chatListContent.includes('const isClubbedGroup = message.messageType === \'shell_run_group\';'),
    'ChatMessageList must detect shell_run_group message type'
  );
  assert.ok(
    chatListContent.includes('hideCardChrome = isDivider || isClubbedGroup'),
    'hideCardChrome must hide bubble card chrome for clubbed groups'
  );
});

test('REQ-TEST-VERIFICATION-17: Individual commands inside clubbed group can be toggled expanded/collapsed independently', async () => {
  const {
    createClubbedGroupState,
    toggleClubbedCommand,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  let state = createClubbedGroupState(true);
  assert.equal(state.expandedCommandIds.size, 0, 'Inner commands must default to collapsed');

  // Expand command 1
  state = toggleClubbedCommand(state, 'cmd_1');
  assert.ok(state.expandedCommandIds.has('cmd_1'), 'cmd_1 must be expanded');
  assert.equal(state.expandedCommandIds.size, 1);

  // Expand command 2 independently
  state = toggleClubbedCommand(state, 'cmd_2');
  assert.ok(state.expandedCommandIds.has('cmd_1'), 'cmd_1 must remain expanded');
  assert.ok(state.expandedCommandIds.has('cmd_2'), 'cmd_2 must be expanded');
  assert.equal(state.expandedCommandIds.size, 2);

  // Collapse command 1 while keeping command 2 expanded
  state = toggleClubbedCommand(state, 'cmd_1');
  assert.ok(!state.expandedCommandIds.has('cmd_1'), 'cmd_1 must be collapsed');
  assert.ok(state.expandedCommandIds.has('cmd_2'), 'cmd_2 must still be expanded');
  assert.equal(state.expandedCommandIds.size, 1);

  // Component structure checks for ShellRunRow rendering inside ClubbedRunGroup
  const shellRunContent = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shells/ShellRunIndicator.tsx'), 'utf8');
  assert.ok(
    shellRunContent.includes('<ShellRunRow key={sessionId} session={session} defaultExpanded={false} />'),
    'ClubbedRunGroup must render ShellRunRow with defaultExpanded={false}'
  );
  assert.ok(
    shellRunContent.includes('data-debug-id={`shell-run-toggle-${session.session_id}`}') &&
    shellRunContent.includes('{expanded && <RunOutput session={session} />}'),
    'Each ShellRunRow must have independent toggle button that controls RunOutput expansion'
  );
});

test('REQ-TEST-VERIFICATION-17: Single isolated shell_run message renders as a single row', async () => {
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeMsg = (id: string, type: string, body = ''): any => ({
    key: id,
    messageId: id,
    body,
    isUser: type === 'user',
    createdUnixMs: 1000,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: type,
    metadata: type === 'shell_run' ? { session_id: `sess_${id}` } : {},
  });

  // Isolated run between user and assistant messages
  const input = [
    makeMsg('u1', 'user', 'Run a command'),
    makeMsg('r1', 'shell_run'),
    makeMsg('a1', 'assistant', 'Done!'),
  ];
  const output = groupTranscriptMessages(input);
  assert.equal(output.length, 3, 'Isolated run must not change message count');
  assert.equal(output[0].messageType, 'user');
  assert.equal(output[1].messageType, 'shell_run', 'Isolated run must remain shell_run type (not shell_run_group)');
  assert.equal(output[1].metadata?.clubbedRuns, undefined, 'Isolated run must not have clubbedRuns metadata');
  assert.equal(output[2].messageType, 'assistant');

  // Single run alone in thread
  const single = groupTranscriptMessages([makeMsg('r-solo', 'shell_run')]);
  assert.equal(single.length, 1);
  assert.equal(single[0].messageType, 'shell_run');

  // Verify ConversationThreadPage renders standalone ShellRunRow for single run
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(
    threadContent.includes('if (message.messageType === \'shell_run\')') &&
    threadContent.includes('return <ShellRunRow session={session} />;'),
    'ConversationThreadPage must render single ShellRunRow for isolated shell_run message'
  );
});

test('REQ-TEST-VERIFICATION-17: Agent start/restart system messages render as subtle divider indicators with time', async () => {
  const {
    isAgentStartMessage,
    formatAgentStartDividerText,
    groupTranscriptMessages,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeSystem = (id: string, body: string, time = 1700000000000, metadata: any = {}): any => ({
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
    metadata,
  });

  // Verify various startup/restart phrases are recognized
  assert.ok(isAgentStartMessage(makeSystem('s1', 'Agent has started and is ready.')));
  assert.ok(isAgentStartMessage(makeSystem('s2', 'Agent restarted after crash.')));
  assert.ok(isAgentStartMessage(makeSystem('s3', 'system ready for commands')));
  assert.ok(isAgentStartMessage({ messageType: 'agent_start' } as any));
  assert.ok(isAgentStartMessage(makeSystem('s4', '', 0, { system_type: 'agent_start' })));
  assert.ok(isAgentStartMessage(makeSystem('s5', '', 0, { system_type: 'startup' })));

  // Single isolated start message preserves system message type
  const solo = groupTranscriptMessages([makeSystem('s1', 'Agent has started and is ready.', 1700000000000)]);
  assert.equal(solo.length, 1);
  assert.equal(solo[0].messageType, 'system');

  // Verify divider text formatting for single start
  const dividerText = formatAgentStartDividerText(1, '10:14 AM');
  assert.equal(dividerText, 'agent started (10:14 AM)');

  // Verify ConversationThreadPage subtle divider DOM structure and classes
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(
    threadContent.includes('data-debug-id={`conversation-agent-start-${message.messageId}`}') &&
    threadContent.includes('className="my-2 flex w-full items-center gap-3"') &&
    threadContent.includes('border-t border-subtle/40') &&
    threadContent.includes('agent started ({time})'),
    'ConversationThreadPage must render subtle centered divider with border lines and agent started ({time})'
  );

  // Verify ChatMessageList suppresses bubble borders and copy buttons for dividers
  const chatListContent = fs.readFileSync(CHAT_LIST_FILE, 'utf8');
  assert.ok(
    chatListContent.includes('isDivider') &&
    chatListContent.includes('message.body.toLowerCase().includes(\'started\')') &&
    chatListContent.includes('!hideCardChrome &&'),
    'ChatMessageList must mark start notices as isDivider and suppress bubble card chrome'
  );
});

test('REQ-TEST-VERIFICATION-17: Consecutive agent starts are clubbed with count and time range', async () => {
  const {
    groupTranscriptMessages,
    formatAgentStartDividerText,
    formatClubbedTimeRange,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeStart = (id: string, time: number): any => ({
    key: id,
    messageId: id,
    body: 'Agent has started and is ready.',
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'system',
    metadata: {},
  });

  const mockFormatTimestamp = (ms: number) => ({
    label: ms === 1000 ? '10:00 AM' : ms === 2000 ? '10:02 AM' : '10:05 AM',
    iso: new Date(ms).toISOString(),
  });

  // 3 consecutive agent starts
  const starts = [
    makeStart('st1', 1000),
    makeStart('st2', 2000),
    makeStart('st3', 3000),
  ];
  const clubbed = groupTranscriptMessages(starts);
  assert.equal(clubbed.length, 1);
  assert.equal(clubbed[0].messageType, 'agent_start_clubbed');
  assert.equal(clubbed[0].metadata?.count, 3);
  assert.equal(clubbed[0].metadata?.startUnixMs, 1000);
  assert.equal(clubbed[0].metadata?.endUnixMs, 3000);

  const timeRange = formatClubbedTimeRange(
    clubbed[0].metadata?.startUnixMs,
    clubbed[0].metadata?.endUnixMs,
    mockFormatTimestamp,
  );
  assert.equal(timeRange, '10:00 AM \u2013 10:05 AM');

  const dividerText = formatAgentStartDividerText(clubbed[0].metadata?.count, timeRange);
  assert.equal(dividerText, 'agent started 3 times (10:00 AM \u2013 10:05 AM)');

  // Verify ConversationThreadPage renders clubbed start divider
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(
    threadContent.includes('message.messageType === \'agent_start_clubbed\'') &&
    threadContent.includes('data-debug-id={`conversation-agent-start-clubbed-${message.messageId}`}') &&
    threadContent.includes('agent started {count} times ({timeStr})'),
    'ConversationThreadPage must render clubbed divider with agent started {count} times ({timeStr})'
  );
});

test('REQ-TEST-VERIFICATION-17: Startup phase triggers capture pane expansion and running state triggers auto-close with manual override preservation', async () => {
  const { computeAutoStartupPaneState } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  // 1. Stopped -> Starting: auto-expands pane
  const step1 = computeAutoStartupPaneState({
    prevStatus: 'stopped',
    runtimeStatus: 'starting',
    userManuallyToggled: false,
    currentExpanded: false,
  });
  assert.equal(step1.isPaneExpanded, true, 'Transition into starting must auto-expand capture pane');
  assert.equal(step1.userManuallyToggled, false);

  // 2. Starting -> Running: auto-closes pane
  const step2 = computeAutoStartupPaneState({
    prevStatus: 'starting',
    runtimeStatus: 'running',
    userManuallyToggled: false,
    currentExpanded: true,
  });
  assert.equal(step2.isPaneExpanded, false, 'Transition into running must auto-collapse capture pane');
  assert.equal(step2.userManuallyToggled, false);

  // 3. User manual override during starting: user manually closes pane
  const step3 = computeAutoStartupPaneState({
    prevStatus: 'starting',
    runtimeStatus: 'starting',
    userManuallyToggled: true,
    currentExpanded: false,
  });
  assert.equal(step3.isPaneExpanded, false, 'Manual collapse during starting must be preserved');
  assert.equal(step3.userManuallyToggled, true);

  // 4. User manual override during running: user manually opens pane
  const step4 = computeAutoStartupPaneState({
    prevStatus: 'running',
    runtimeStatus: 'running',
    userManuallyToggled: true,
    currentExpanded: true,
  });
  assert.equal(step4.isPaneExpanded, true, 'Manual expand during running must be preserved');
  assert.equal(step4.userManuallyToggled, true);

  // 5. Subsequent new start cycle resets userManuallyToggled and auto-expands
  const step5 = computeAutoStartupPaneState({
    prevStatus: 'running',
    runtimeStatus: 'starting',
    userManuallyToggled: true,
    currentExpanded: false,
  });
  assert.equal(step5.isPaneExpanded, true, 'New start cycle must reset override and auto-expand');
  assert.equal(step5.userManuallyToggled, false);

  // Verify ConversationThreadPage implementation bindings
  const threadContent = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(
    threadContent.includes('userManuallyToggledPaneRef'),
    'ConversationThreadPage must track manual overrides with userManuallyToggledPaneRef'
  );
  assert.ok(
    threadContent.includes('handleStreamOutput') && threadContent.includes('setIsPaneExpanded(true)'),
    'ConversationThreadPage must auto-expand capture pane on streaming output'
  );
  assert.ok(
    threadContent.includes("startupStatus === 'ready'") && threadContent.includes('setIsPaneExpanded(false)'),
    'ConversationThreadPage must set isPaneExpanded(false) when startupStatus transitions to ready'
  );
  assert.ok(
    threadContent.includes('userManuallyToggledPaneRef.current = false;'),
    'ConversationThreadPage must reset userManuallyToggledPaneRef on new status cycle'
  );
});

// ---------------------------------------------------------------------------
// REQ-MOBILE-DOCK-FULLHEIGHT-18: Make BottomDock default to full vertical height on mobile viewports
// ---------------------------------------------------------------------------

test('REQ-MOBILE-DOCK-FULLHEIGHT-18: BottomDock imports useViewport and checks isMobile', () => {
  const content = fs.readFileSync(BOTTOM_DOCK_FILE, 'utf8');
  assert.ok(
    content.includes("import { useViewport } from './responsive';") ||
    (content.includes('useViewport') && (content.includes('@ui') || content.includes('./responsive'))),
    'BottomDock must import useViewport'
  );
  assert.ok(
    content.includes("viewport === 'mobile'"),
    'BottomDock must determine isMobile using viewport === \'mobile\''
  );
});

test('REQ-MOBILE-DOCK-FULLHEIGHT-18: On mobile viewport, open BottomDock expands to full vertical space and collapses to 36px when minimized', () => {
  const content = fs.readFileSync(BOTTOM_DOCK_FILE, 'utf8');
  assert.ok(
    content.includes("effectiveHeight = isMinimized ? 36 : (isMobile ? 'calc(100vh - 48px)' : height)") ||
    (content.includes('effectiveHeight') && content.includes('isMobile') && content.includes('calc(100vh - 48px)') && content.includes('36')),
    'BottomDock effectiveHeight must occupy full vertical space calc(100vh - 48px) on mobile when open, and 36px when minimized'
  );
  assert.ok(
    content.includes('data-debug-id="bottom-dock-minimize-btn"'),
    'BottomDock must include minimize button to toggle collapsed/expanded state'
  );
});

test('REQ-MOBILE-DOCK-FULLHEIGHT-18: On mobile viewport, container maxHeight expands to full vertical space and desktop caps at 80vh', () => {
  const content = fs.readFileSync(BOTTOM_DOCK_FILE, 'utf8');
  assert.ok(
    content.includes("maxHeight: isMobile ? 'calc(100vh - 48px)' : 'min(calc(100vh - 100px), 80vh)'") ||
    (content.includes('maxHeight') && content.includes('isMobile') && content.includes('calc(100vh - 48px)')),
    'BottomDock container style must set maxHeight to calc(100vh - 48px) on mobile and min(calc(100vh - 100px), 80vh) on desktop'
  );
  assert.ok(
    content.includes('max-h-[80vh]'),
    'Desktop must retain 80vh max-height cap'
  );
});

test('REQ-MOBILE-DOCK-FULLHEIGHT-18: On mobile viewport, resizing drag handle is disabled and desktop retains draggable resizing', () => {
  const content = fs.readFileSync(BOTTOM_DOCK_FILE, 'utf8');
  assert.ok(
    content.includes('if (isMobile) return;') || content.includes('if (isMinimized || isMobile) return;'),
    'handleResizeStart must return early and disable drag when isMobile is true'
  );
  assert.ok(
    content.includes('!isMinimized && !isMobile && (') ||
    content.includes('data-debug-id="bottom-dock-resizer"'),
    'bottom-dock-resizer handle must be disabled on mobile'
  );
  assert.ok(
    content.includes('readBottomDockHeight()'),
    'Desktop must retain persisted default height'
  );
  assert.ok(
    content.includes('BOTTOM_DOCK_MIN_HEIGHT'),
    'Desktop must retain minimum height clamping'
  );
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: extractMessageOptions parses options from array, string metadata, and metadata_json', async () => {
  const { extractMessageOptions } = await import('../src/ui/components/chat/types.ts');

  // Object with array options
  assert.deepEqual(
    extractMessageOptions({ metadata: { options: ['Deploy', 'Rollback', 'Wait'] } }),
    ['Deploy', 'Rollback', 'Wait'],
    'Must parse string array from metadata.options'
  );

  // Stringified metadata
  assert.deepEqual(
    extractMessageOptions({ metadata: JSON.stringify({ options: ['Alpha', 'Beta'] }) }),
    ['Alpha', 'Beta'],
    'Must parse JSON string in metadata'
  );

  // Fallback to metadata_json
  assert.deepEqual(
    extractMessageOptions({ metadata_json: JSON.stringify({ options: ['Yes', 'No'] }) }),
    ['Yes', 'No'],
    'Must parse JSON string in metadata_json'
  );

  // Empty or missing metadata returns empty array (normal messages without options)
  assert.deepEqual(extractMessageOptions({ metadata: {} }), [], 'Empty metadata object returns empty array');
  assert.deepEqual(extractMessageOptions({}), [], 'Missing metadata returns empty array');
  assert.deepEqual(extractMessageOptions({ metadata: { options: [] } }), [], 'Empty options array returns empty array');
  assert.deepEqual(extractMessageOptions({ metadata: { options: ['', '   '] } }), [], 'Whitespace-only options are filtered out');
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: ChatMessageList renders interactive option chips below agent messages with options', () => {
  const content = fs.readFileSync(CHAT_LIST_FILE, 'utf8');

  assert.ok(
    content.includes('extractMessageOptions'),
    'ChatMessageList must import and use extractMessageOptions'
  );
  assert.ok(
    content.includes('options.length > 0 && !message.isUser') || content.includes('options.length > 0 && !msg.isUser'),
    'ChatMessageList must only render option chips for messages with options from non-user (agent)'
  );
  assert.ok(
    content.includes('data-debug-id={`${debugPrefix}-option-chip-${message.messageId}-${optIdx}`}') ||
    content.includes('option-chip'),
    'ChatMessageList must render option chips with option-chip debug ids'
  );
  assert.ok(
    content.includes('onClick={() => reply(option)}') || content.includes('onClick={() => reply(opt)}'),
    'Clicking an option chip must invoke reply callback with the option text'
  );
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: MessageItem and ChatMessageItem support quick-reply option chips and onReply callback', () => {
  const itemContent = fs.readFileSync(MESSAGE_ITEM_FILE, 'utf8');
  assert.ok(
    itemContent.includes('onReply?: (reply: string) => void'),
    'MessageItemProps must include optional onReply callback'
  );
  assert.ok(
    itemContent.includes('extractMessageOptions'),
    'MessageItem must use extractMessageOptions'
  );
  assert.ok(
    itemContent.includes('data-debug-id={`option-chip-${messageId}-${optIdx}`}') ||
    itemContent.includes('option-chip'),
    'MessageItem must render option chip buttons'
  );
  assert.ok(
    itemContent.includes('onClick={() => onReply?.(option)}') || itemContent.includes('onClick={() => onReply?.(opt)}'),
    'Clicking option chip in MessageItem must invoke onReply'
  );

  const chatItemContent = fs.readFileSync(CHAT_MESSAGE_ITEM_FILE, 'utf8');
  assert.ok(
    chatItemContent.includes('ChatMessageItem'),
    'ChatMessageItem must export ChatMessageItem component'
  );
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: ConversationThreadPage passes handleSendReply as onReply to ChatMessageList', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.ok(
    content.includes('async function handleSendReply') || content.includes('const handleSendReply ='),
    'ConversationThreadPage must define handleSendReply'
  );
  assert.ok(
    content.includes('onReply={handleSendReply}'),
    'ConversationThreadPage must pass handleSendReply to ChatMessageList onReply'
  );
  assert.ok(
    content.includes('sendMessage({ conversationId, body: sendBody'),
    'handleSendReply must send the reply text via sendMessage mutation'
  );
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: CLI agent_mode parses --options and aliases into options array payload', () => {
  const content = fs.readFileSync(CTL_AGENT_MODE_FILE, 'utf8');

  assert.ok(
    content.includes('collect_multi_values(args, "--options", "--option", "--expected-answers", "--choices")'),
    'agent_mode must parse --options, --option, --expected-answers, --choices using collect_multi_values'
  );
  assert.ok(
    content.includes('json_string_array_field("options", opts[:])'),
    'agent_mode must format options array into JSON payload'
  );
  assert.ok(
    content.includes('return json_object(json_kv("to", to), json_kv("body", chat_body))'),
    'agent_mode must keep baseline plaintext JSON payload when no options are provided'
  );
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: Backend preserves options array in message metadata_json', () => {
  const actionContent = fs.readFileSync(HUB_AGENT_ACTION_FILE, 'utf8');
  assert.ok(
    actionContent.includes('json_array_optional(params, "options")'),
    'agent_action_chat_send_to_user_handler must extract options array from params'
  );
  assert.ok(
    actionContent.includes('metadata_json = fmt.tprintf("{{\\"options\\":%s}}", options)'),
    'agent_action_chat_send_to_user_handler must format metadata_json containing options array'
  );

  const serviceContent = fs.readFileSync(HUB_CONTENT_SERVICE_FILE, 'utf8');
  assert.ok(
    serviceContent.includes('Message_Input :: struct { body,artifact_ids_json,message_type,metadata_json: string }'),
    'Message_Input struct must include metadata_json'
  );
  assert.ok(
    serviceContent.includes('metadata_json=input.metadata_json'),
    'send_agent_message must assign metadata_json from input'
  );
});

// ---------------------------------------------------------------------------
// REQ-SHELL-DOCK-NO-VSCROLL-23: Eliminate vertical scrolling and enforce 40-col minimum width in ShellTerminalPane
// ---------------------------------------------------------------------------

test('REQ-SHELL-DOCK-NO-VSCROLL-23: ShellTerminalPane enforces Math.max(..., 40) column floor across resize handlers and geometry', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE_FILE), 'ShellTerminalPane.tsx must exist');
  const content = fs.readFileSync(SHELL_TERMINAL_PANE_FILE, 'utf8');

  // getGeometry enforces 40-col floor
  assert.ok(
    content.includes('cols: Math.max(term.cols, 40)'),
    'getGeometry must enforce minimum 40 columns'
  );

  // handleResize enforces 40-col floor
  assert.ok(
    content.includes('const effectiveCols = Math.max(cols, 40);'),
    'handleResize must enforce minimum 40 columns'
  );

  // dispatchResize, ResizeObserver, and handleWindowResize enforce 40-col floor
  assert.ok(
    content.includes('term.resize(Math.max(term.cols, 40), term.rows)'),
    'dispatchResize, ResizeObserver, and handleWindowResize must enforce 40 columns floor'
  );
});

test('REQ-SHELL-DOCK-NO-VSCROLL-23: ShellTerminalPane does NOT enforce 24-row floor across resize handlers or geometry (fits parent container directly)', () => {
  const content = fs.readFileSync(SHELL_TERMINAL_PANE_FILE, 'utf8');

  // Must not enforce 24-row floor in handleResize
  assert.ok(
    !content.includes('Math.max(rows, 24)'),
    'handleResize must not enforce 24-row floor'
  );

  // Must not enforce 24-row floor in term.resize calls
  assert.ok(
    !content.includes('Math.max(term.rows, 24)'),
    'term.resize callers must not enforce 24-row floor'
  );

  // Must not enforce 24-row floor in getGeometry
  assert.ok(
    !content.includes('rows: Math.max(term.rows, 24)'),
    'getGeometry must not enforce 24-row floor'
  );

  // Rows fit directly from fitAddon / term.rows
  assert.ok(
    content.includes('term.resize(Math.max(term.cols, 40), term.rows)'),
    'term.resize must pass term.rows directly without 24-row floor'
  );
});

test('REQ-SHELL-DOCK-NO-VSCROLL-23: ShellTerminalPane container styling enables horizontal scroll and prevents vertical scrolling', () => {
  const content = fs.readFileSync(SHELL_TERMINAL_PANE_FILE, 'utf8');

  // Terminal container styling
  assert.ok(
    content.includes('chat-scrollbar relative flex-1 min-h-0 w-full overflow-x-auto p-2 font-mono text-xs cursor-text touch-manipulation focus:outline-none'),
    'xterm container must retain chat-scrollbar, flex-1, min-h-0, w-full, overflow-x-auto styling'
  );

  // Must not include overflow-y-auto or overflow-y-scroll on the terminal container
  assert.ok(
    !content.includes('overflow-y-auto') && !content.includes('overflow-y-scroll'),
    'xterm container must not include vertical scroll overflow classes'
  );
});

// ---------------------------------------------------------------------------
// REQ-ACTION-FEEDBACK-LOOP-21: In-chat Action Card approval/rejection UI and agent feedback loop
// ---------------------------------------------------------------------------

test('REQ-ACTION-FEEDBACK-LOOP-21: extractMessageActionIds parses action_ids from metadata, stringified metadata, and metadata_json', async () => {
  const { extractMessageActionIds } = await import('../src/ui/components/chat/types.ts');

  // Array of action_ids
  assert.deepEqual(
    extractMessageActionIds({ metadata: { action_ids: ['card_1', 'card_2'] } }),
    ['card_1', 'card_2'],
    'Must parse string array from metadata.action_ids'
  );

  // Stringified metadata
  assert.deepEqual(
    extractMessageActionIds({ metadata: JSON.stringify({ action_ids: ['card_3'] }) }),
    ['card_3'],
    'Must parse JSON string in metadata'
  );

  // Fallback to metadata_json
  assert.deepEqual(
    extractMessageActionIds({ metadata_json: JSON.stringify({ action_ids: ['card_4'] }) }),
    ['card_4'],
    'Must parse JSON string in metadata_json'
  );

  // Aliases: actions or action_id
  assert.deepEqual(
    extractMessageActionIds({ metadata: { actions: ['card_5'] } }),
    ['card_5'],
    'Must support actions alias'
  );
  assert.deepEqual(
    extractMessageActionIds({ metadata: { action_id: 'card_6' } }),
    ['card_6'],
    'Must support single action_id string'
  );

  // Normal messages without action_ids return empty array
  assert.deepEqual(extractMessageActionIds({ metadata: {} }), [], 'Empty metadata returns empty array');
  assert.deepEqual(extractMessageActionIds({}), [], 'Missing metadata returns empty array');
  assert.deepEqual(extractMessageActionIds({ metadata: { action_ids: [] } }), [], 'Empty array returns empty array');
});

test('REQ-ACTION-FEEDBACK-LOOP-21: ChatMessageList, MessageItem, and ChatMessageItem render inline Action Card inside message bubble', () => {
  assert.ok(fs.existsSync(CHAT_ACTION_CARD_FILE), 'ChatActionCard.tsx must exist');

  const listContent = fs.readFileSync(CHAT_LIST_FILE, 'utf8');
  assert.ok(
    listContent.includes('ChatActionCard'),
    'ChatMessageList must import ChatActionCard'
  );
  assert.ok(
    listContent.includes('<ChatActionCard message={message}'),
    'ChatMessageList must render ChatActionCard inside message bubble container'
  );

  const itemContent = fs.readFileSync(MESSAGE_ITEM_FILE, 'utf8');
  assert.ok(
    itemContent.includes('ChatActionCard'),
    'MessageItem must import and render ChatActionCard'
  );

  const chatItemContent = fs.readFileSync(CHAT_MESSAGE_ITEM_FILE, 'utf8');
  assert.ok(
    chatItemContent.includes('ChatActionCard'),
    'ChatMessageItem must export or reference ChatActionCard'
  );
});

test('REQ-ACTION-FEEDBACK-LOOP-21: ChatActionCard displays title, status badge, and operations summary', () => {
  const content = fs.readFileSync(CHAT_ACTION_CARD_FILE, 'utf8');

  // Title
  assert.ok(
    content.includes('action-card-title-'),
    'ChatActionCard must render card title with debug id action-card-title-'
  );

  // Status badge (pending/accepted/rejected)
  assert.ok(
    content.includes('action-card-status-'),
    'ChatActionCard must render card status badge with debug id action-card-status-'
  );
  assert.ok(
    content.includes("'pending'") && content.includes("'accepted'") && content.includes("'rejected'"),
    'ChatActionCard status badge must support pending, accepted, and rejected statuses'
  );

  // Operations summary
  assert.ok(
    content.includes('action-card-summary-') || content.includes('operationsSummary'),
    'ChatActionCard must render operations summary'
  );
  assert.ok(
    content.includes('formatOpLabel'),
    'ChatActionCard must format operations using formatOpLabel'
  );
});

test('REQ-ACTION-FEEDBACK-LOOP-21: Clicking Approve executes acceptCard({ cardId }) and sends [Action Approved] confirmation message', () => {
  const content = fs.readFileSync(CHAT_ACTION_CARD_FILE, 'utf8');

  assert.ok(
    content.includes('action-card-approve-btn-'),
    'ChatActionCard must render approve button'
  );
  assert.ok(
    content.includes('acceptCardMutation') || content.includes('acceptCard'),
    'Approve action must execute acceptCard mutation'
  );
  assert.ok(
    content.includes('cardId: actionId') || content.includes('cardId'),
    'Approve action must pass cardId to acceptCard'
  );
  assert.ok(
    content.includes('[Action Approved] Action') && content.includes('was approved by user'),
    'Approve action must construct confirmation message: "[Action Approved] Action <action_id> (<title>) was approved by user"'
  );
});

test('REQ-ACTION-FEEDBACK-LOOP-21: Clicking Reject discards card and sends [Action Rejected] confirmation message with comment', () => {
  const content = fs.readFileSync(CHAT_ACTION_CARD_FILE, 'utf8');

  assert.ok(
    content.includes('action-card-reject-btn-'),
    'ChatActionCard must render reject button'
  );
  assert.ok(
    content.includes('action-card-comment-input-'),
    'ChatActionCard must render optional user comment input'
  );
  assert.ok(
    content.includes('discardCardMutation') || content.includes('discardCard'),
    'Reject action must execute discardCard mutation'
  );
  assert.ok(
    content.includes('cardId: actionId') || content.includes('cardId'),
    'Reject action must pass cardId to discardCard'
  );
  assert.ok(
    content.includes('[Action Rejected] Action') && content.includes('was rejected by user'),
    'Reject action must construct confirmation message: "[Action Rejected] Action <action_id> (<title>) was rejected by user: <comment>"'
  );
});

test('REQ-ACTION-FEEDBACK-LOOP-21: Resolved action cards reflect approved/rejected state and disable action buttons', () => {
  const content = fs.readFileSync(CHAT_ACTION_CARD_FILE, 'utf8');

  assert.ok(
    content.includes("const isResolved = status === 'accepted' || status === 'rejected'"),
    'ChatActionCard must determine resolved state for accepted and rejected cards'
  );
  assert.ok(
    content.includes('disabled={isResolved || isBusy}'),
    'Action buttons and inputs must be disabled once the card is resolved'
  );
});

test('REQ-ACTION-FEEDBACK-LOOP-21: cards.ts API endpoints support cardId argument and issue.create formatting', () => {
  const content = fs.readFileSync(CARDS_ENDPOINT_FILE, 'utf8');

  assert.ok(
    content.includes('acceptCard: build.mutation<Card, { id?: string; cardId?: string }>'),
    'acceptCard must accept cardId in argument'
  );
  assert.ok(
    content.includes('discardCard: build.mutation<Card, { id?: string; cardId?: string }>'),
    'discardCard must accept cardId in argument'
  );
  assert.ok(
    content.includes("case 'issue.create':"),
    'formatOpLabel must format issue.create operations'
  );
});

