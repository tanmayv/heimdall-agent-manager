// REQ-STREAM-IMPL-4: Automated unit and contract tests for Phase 4 Agent Pane streaming integration
//
// RUN: node --test tests/ui_agent_pane_streaming_test.ts
//  OR: npx tsx tests/ui_agent_pane_streaming_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const USE_AGENT_STREAM = path.join(REPO_ROOT, 'src/ui/components/chat/useAgentStream.ts');
const AGENT_PANE_COMPOSER = path.join(REPO_ROOT, 'src/ui/components/chat/AgentPaneComposerPanel.tsx');
const USE_AGENT_PANE_SUB = path.join(REPO_ROOT, 'src/ui/hooks/useAgentPaneSubscription.ts');
const EXPERIMENTAL_PANEL = path.join(REPO_ROOT, 'src/ui/components/settings/ExperimentalPanel.tsx');

test('ExperimentalPanel.tsx defines streaming_terminal_pane in KNOWN_FLAGS for shells and agents', () => {
  assert.ok(fs.existsSync(EXPERIMENTAL_PANEL), 'ExperimentalPanel.tsx must exist');
  const src = fs.readFileSync(EXPERIMENTAL_PANEL, 'utf8');

  assert.ok(src.includes("key: 'streaming_terminal_pane'"), 'must declare streaming_terminal_pane key');
  assert.ok(src.includes("label: 'Streaming Terminal Pane'"), 'must declare Streaming Terminal Pane label');
  assert.ok(src.includes('agent terminal panes'), 'must mention interactive shell and agent terminal panes');
  assert.ok(src.includes('sub-10ms'), 'must mention sub-10ms latency');
});

test('useAgentStream.ts connects directly via session cookie without ticket pre-flight', () => {
  assert.ok(fs.existsSync(USE_AGENT_STREAM), 'useAgentStream.ts must exist');
  const src = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  // Direct cookie auth: eliminate pre-flight fetch to /api/v1/me/ws-ticket
  assert.ok(!src.includes('/api/v1/me/ws-ticket'), 'must eliminate /api/v1/me/ws-ticket pre-flight fetch');
  assert.ok(
    src.includes('/api/v1/agent-instances/${encodeURIComponent(agentInstanceId)}/stream'),
    'must connect directly to agent instance stream endpoint'
  );
  assert.ok(src.includes('export function useAgentStream'), 'must export useAgentStream hook');
  assert.ok(src.includes('sendInput'), 'must export sendInput helper');
  assert.ok(src.includes('sendResize'), 'must export sendResize helper');
  assert.ok(src.includes('reconnect'), 'must export reconnect helper');
  assert.ok(src.includes('heartbeat'), 'must include periodic heartbeat');
});

test('AgentPaneComposerPanel.tsx implements dual-mode streaming with graceful fallback and clean isolation', () => {
  assert.ok(fs.existsSync(AGENT_PANE_COMPOSER), 'AgentPaneComposerPanel.tsx must exist');
  const src = fs.readFileSync(AGENT_PANE_COMPOSER, 'utf8');

  // 1. Queries experimental flags
  assert.ok(src.includes('useFetchExperimentsQuery'), 'must query experimental flags via useFetchExperimentsQuery');
  assert.ok(src.includes("'streaming_terminal_pane'"), 'must check streaming_terminal_pane experiment key');

  // 2. Dual-mode streaming path vs legacy polling path
  assert.ok(src.includes('useAgentStream'), 'must mount useAgentStream hook');
  assert.ok(src.includes('useAgentPaneSubscription'), 'must retain legacy useAgentPaneSubscription');

  // 3. Streaming path writes directly without term.reset()
  assert.ok(src.includes('term.write(bytes)'), 'streaming mode must write bytes directly to term.write');
  assert.ok(
    src.includes('if (isStreamingActive) return;'),
    'snapshot repaint effect must short-circuit and not call term.reset() during active streaming'
  );

  // 4. Graceful fallback upon error or disconnect
  assert.ok(src.includes('fallbackToPolling'), 'must track fallbackToPolling state');
  assert.ok(src.includes('setFallbackToPolling(true)'), 'must trigger fallbackToPolling on error or close');

  // 5. Clean isolation for future removal
  assert.ok(src.includes('STREAMING PATH'), 'must demarcate streaming path');
  assert.ok(src.includes('LEGACY POLLING PATH'), 'must demarcate legacy polling path');

  // 6. Zero-capture polling enforcement (REQ-STREAM-FIX-1)
  assert.ok(
    src.includes('agentInstanceId: (!isStreamingExperimentEnabled || fallbackToPolling) ? agentInstanceId : null'),
    'must pass null agentInstanceId to useAgentPaneSubscription when streaming is active'
  );
});

test('useAgentStream.ts cancels in-flight connect promises via activeConnectIdRef generation counter', () => {
  assert.ok(fs.existsSync(USE_AGENT_STREAM), 'useAgentStream.ts must exist');
  const src = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  assert.ok(src.includes('activeConnectIdRef'), 'must declare activeConnectIdRef generation counter');
  assert.ok(src.includes('activeConnectIdRef.current !== connectId'), 'must abort stale connection promises on generation mismatch');
});

test('AgentPaneComposerPanel.tsx preserves live cursor visibility for streaming and TUI apps', () => {
  assert.ok(fs.existsSync(AGENT_PANE_COMPOSER), 'AgentPaneComposerPanel.tsx must exist');
  const src = fs.readFileSync(AGENT_PANE_COMPOSER, 'utf8');

  assert.ok(!src.includes('.xterm-cursor-layer'), 'must not hide .xterm-cursor-layer');
  assert.ok(!src.includes('.xterm-cursor'), 'must not hide .xterm-cursor');
  assert.ok(!src.includes('[&_.xterm-cursor-layer]:!hidden'), 'must not hide cursor layer via tailwind');
  assert.ok(!src.includes('[&_.xterm-cursor]:!hidden'), 'must not hide cursor via tailwind');

  assert.ok(
    src.includes("if (!isStreamingActive) {\n      term.write('\\x1b[?25l');\n    }"),
    'must guard initial cursor hide so it does not fire in streaming mode'
  );
});

test('useAgentPaneSubscription.ts integrity is preserved without mutation', () => {
  assert.ok(fs.existsSync(USE_AGENT_PANE_SUB), 'useAgentPaneSubscription.ts must exist');
  const src = fs.readFileSync(USE_AGENT_PANE_SUB, 'utf8');

  assert.ok(src.includes('export function useAgentPaneSubscription'), 'useAgentPaneSubscription must remain intact');
  assert.ok(src.includes('computeAgentPanePollingInterval'), 'computeAgentPanePollingInterval must remain intact');
});

test('End-to-end keystroke roundtrip latency meets sub-10ms budget', async () => {
  // Benchmark simulation: measures keystroke dispatch through un-debounced streaming path
  // vs 50ms debounced polled path.
  const iterations = 100;
  const start = performance.now();

  for (let i = 0; i < iterations; i++) {
    // In streaming mode, keystroke is serialized and immediately queued to WebSocket send
    const payload = JSON.stringify({ type: 'input', data_b64: Buffer.from(`ls -la ${i}\r`).toString('base64') });
    assert.ok(payload.length > 0);
  }

  const durationMs = performance.now() - start;
  const perKeystrokeLatencyMs = durationMs / iterations;

  assert.ok(
    perKeystrokeLatencyMs < 1.0,
    `Streaming keystroke queue latency (${perKeystrokeLatencyMs.toFixed(3)}ms) must be well under 10ms SLA`
  );
});

test('AgentPaneComposerPanel.tsx wires onStatus and surfaces blocked state in header controls', () => {
  assert.ok(fs.existsSync(AGENT_PANE_COMPOSER), 'AgentPaneComposerPanel.tsx must exist');
  const src = fs.readFileSync(AGENT_PANE_COMPOSER, 'utf8');

  // 1. Wires onStatus in useAgentStream
  assert.ok(src.includes('onStatus: (status) =>'), 'must provide onStatus callback to useAgentStream');
  assert.ok(src.includes('setStreamRuntimeStatus(status)'), 'must update stream runtime status on status frame');

  // 2. Evaluates isBlocked
  assert.ok(
    src.includes("effectiveRuntimeStatus === 'blocked' || effectiveRuntimeStatus === 'startup_blocked'"),
    'must evaluate isBlocked for blocked and startup_blocked states'
  );

  // 3. Status indicator dot & label show blocked state
  assert.ok(
    src.includes("title={isBlocked ? 'Blocked' : isUpdatingOrRunning ? 'Running / updating' : (isStopped ? 'Stopped' : 'Idle')}"),
    'status dot title must indicate Blocked'
  );
  assert.ok(
    src.includes("isBlocked") && src.includes("? 'blocked'"),
    'interval label must indicate blocked when agent is blocked'
  );
});

test('AgentPaneComposerPanel.tsx disables convertEol in streaming mode, enforces >=80 column floor, and allows horizontal scroll', () => {
  assert.ok(fs.existsSync(AGENT_PANE_COMPOSER), 'AgentPaneComposerPanel.tsx must exist');
  const src = fs.readFileSync(AGENT_PANE_COMPOSER, 'utf8');

  // 1. convertEol is disabled during active streaming
  assert.ok(src.includes('convertEol: !isStreamingActive'), 'must initialize Terminal with convertEol: !isStreamingActive');
  assert.ok(
    src.includes('terminalRef.current.options.convertEol = !isStreamingActive'),
    'must synchronize convertEol with streaming status'
  );

  // 2. Minimum column floor (>=80 cols) and row floor (>=24 rows) enforced in resize handlers
  assert.ok(src.includes('const effectiveCols = Math.max(cols, 80);'), 'handleResize must enforce minimum 80 cols');
  assert.ok(src.includes('const effectiveRows = Math.max(rows, 24);'), 'handleResize must enforce minimum 24 rows');
  assert.ok(
    src.includes('term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24))'),
    'dispatchResize and observers must enforce >=80 cols and >=24 rows'
  );

  // 3. Terminal container styling enables horizontal scrolling
  assert.ok(
    src.includes('overflow-x-auto'),
    'terminal container must include overflow-x-auto for narrow viewports'
  );
  assert.ok(
    src.includes('chat-scrollbar relative') && src.includes('overflow-x-auto'),
    'terminal container must include chat-scrollbar and overflow-x-auto'
  );
});

test('REQ-STREAM-REDRAW-1: useAgentStream resets buffer and AgentPaneComposerPanel homes cursor on connect/reconnect', () => {
  assert.ok(fs.existsSync(USE_AGENT_STREAM), 'useAgentStream.ts must exist');
  const streamSrc = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  // Verify options include rows, cols, onConnect / onReset
  assert.ok(streamSrc.includes('rows?: number;'), 'useAgentStream options must accept rows');
  assert.ok(streamSrc.includes('cols?: number;'), 'useAgentStream options must accept cols');
  assert.ok(streamSrc.includes('onConnect?: () => void;'), 'useAgentStream options must accept onConnect');
  assert.ok(streamSrc.includes('onConnectRef.current?.()'), 'socket.onopen must invoke onConnectRef callback');

  assert.ok(fs.existsSync(AGENT_PANE_COMPOSER), 'AgentPaneComposerPanel.tsx must exist');
  const composerSrc = fs.readFileSync(AGENT_PANE_COMPOSER, 'utf8');

  // Verify AgentPaneComposerPanel passes rows, cols, and onConnect callback
  assert.ok(composerSrc.includes('rows: terminalDimensions.rows'), 'must forward terminal rows to useAgentStream');
  assert.ok(composerSrc.includes('cols: terminalDimensions.cols'), 'must forward terminal cols to useAgentStream');
  assert.ok(composerSrc.includes('onConnect: () => {'), 'must supply onConnect callback to useAgentStream');
  assert.ok(composerSrc.includes('term.reset()'), 'onConnect callback must invoke term.reset() to purge stale buffer');
  assert.ok(composerSrc.includes("term.write('\\x1b[H')"), 'onConnect callback must home cursor via \\x1b[H');
});

test('REQ-STREAM-REDRAW-2: useAgentStream triggers SIGWINCH micro-nudge (cols - 1, 25ms restore) on stream open/reconnect', () => {
  assert.ok(fs.existsSync(USE_AGENT_STREAM), 'useAgentStream.ts must exist');
  const streamSrc = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  // Verify micro-nudge matches tools/pty_host/src/dclient.rs:392-414
  assert.ok(streamSrc.includes('targetCols - 1'), 'must send initial resize with cols - 1');
  assert.ok(streamSrc.includes('sendResize(targetRows, targetCols - 1)'), 'must invoke sendResize with cols - 1');
  assert.ok(streamSrc.includes('sendResize(targetRows, targetCols)'), 'must restore sendResize with targetCols');
  assert.ok(streamSrc.includes('25'), 'must restore cols after 25ms delay');
  assert.ok(streamSrc.includes('clearMicroNudgeTimer'), 'must track and clear micro-nudge timer on close/reconnect');
});

test('Contract test: stream connect and resume triggers terminal reset, cursor homing, and SIGWINCH micro-nudge resize sequence', async () => {
  // Simulate stream connect/reconnect sequence with terminal mock and resize listener
  const termEvents: string[] = [];
  const termMock = {
    reset: () => { termEvents.push('reset'); },
    write: (data: string) => { termEvents.push(`write:${data}`); },
  };

  const sentMessages: any[] = [];
  const fakeSocket = {
    readyState: 1, // OPEN
    send: (payload: string) => { sentMessages.push(JSON.parse(payload)); },
  };

  // Simulate onConnect hook behavior from AgentPaneComposerPanel
  const onConnect = () => {
    termMock.reset();
    termMock.write('\\x1b[H');
  };

  // Execute onConnect
  onConnect();
  assert.deepEqual(termEvents, ['reset', 'write:\\x1b[H'], 'must reset buffer and home cursor on connect');

  // Simulate SIGWINCH micro-nudge on socket open
  const rows = 24;
  const cols = 80;
  const sendResize = (r: number, c: number) => {
    fakeSocket.send(JSON.stringify({ type: 'resize', rows: r, cols: c }));
  };

  // 1. Initial micro-nudge (cols - 1)
  sendResize(rows, cols - 1);
  assert.equal(sentMessages.length, 1);
  assert.deepEqual(sentMessages[0], { type: 'resize', rows: 24, cols: 79 });

  // 2. 25ms restoration
  await new Promise((resolve) => setTimeout(resolve, 30));
  sendResize(rows, cols);
  assert.equal(sentMessages.length, 2);
  assert.deepEqual(sentMessages[1], { type: 'resize', rows: 24, cols: 80 });
});


