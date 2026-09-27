// REQ-STREAM-IMPL-3: Automated unit and contract tests for Phase 3 UI streaming integration
//
// RUN: node --test tests/ui_shell_streaming_test.ts
//  OR: npx tsx tests/ui_shell_streaming_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const EXPERIMENTAL_PANEL = path.join(REPO_ROOT, 'src/ui/components/settings/ExperimentalPanel.tsx');
const USE_SHELL_STREAM = path.join(REPO_ROOT, 'src/ui/components/shells/useShellStream.ts');
const SHELL_TERMINAL_PANE = path.join(REPO_ROOT, 'src/ui/components/shells/ShellTerminalPane.tsx');
const USE_SHELL_PANE_SUB = path.join(REPO_ROOT, 'src/ui/hooks/useShellPaneSubscription.ts');

test('ExperimentalPanel.tsx defines streaming_terminal_pane in KNOWN_FLAGS', () => {
  assert.ok(fs.existsSync(EXPERIMENTAL_PANEL), 'ExperimentalPanel.tsx must exist');
  const src = fs.readFileSync(EXPERIMENTAL_PANEL, 'utf8');

  assert.ok(src.includes("key: 'streaming_terminal_pane'"), 'must declare streaming_terminal_pane key');
  assert.ok(src.includes("label: 'Streaming Terminal Pane'"), 'must declare Streaming Terminal Pane label');
  assert.ok(src.includes('sub-10ms'), 'must mention sub-10ms latency');
  assert.ok(src.includes('VT100 scrollback'), 'must mention native VT100 scrollback');
});

test('useShellStream.ts connects directly via session cookie without ticket pre-flight', () => {
  assert.ok(fs.existsSync(USE_SHELL_STREAM), 'useShellStream.ts must exist');
  const src = fs.readFileSync(USE_SHELL_STREAM, 'utf8');

  // Per user directive: eliminate mandatory pre-flight fetch to /api/v1/me/ws-ticket
  assert.ok(!src.includes('/api/v1/me/ws-ticket'), 'must eliminate /api/v1/me/ws-ticket pre-flight fetch');
  assert.ok(src.includes('/api/v1/shells/${encodeURIComponent(sessionId)}/stream'), 'must connect directly to shell stream endpoint');
  assert.ok(src.includes('export function useShellStream'), 'must export useShellStream hook');
  assert.ok(src.includes('sendInput'), 'must export sendInput helper');
  assert.ok(src.includes('sendResize'), 'must export sendResize helper');
  assert.ok(src.includes('reconnect'), 'must export reconnect helper');
  assert.ok(src.includes('heartbeat'), 'must include periodic heartbeat');
});

test('ShellTerminalPane.tsx implements dual-mode streaming with graceful fallback and clean isolation', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE), 'ShellTerminalPane.tsx must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  // 1. Queries experimental flags
  assert.ok(src.includes('useFetchExperimentsQuery'), 'must query experimental flags via useFetchExperimentsQuery');
  assert.ok(src.includes("'streaming_terminal_pane'"), 'must check streaming_terminal_pane experiment key');

  // 2. Dual-mode streaming path vs legacy polling path
  assert.ok(src.includes('useShellStream'), 'must mount useShellStream hook');
  assert.ok(src.includes('useShellPaneSubscription'), 'must retain legacy useShellPaneSubscription');

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
    src.includes('sessionId: (!isStreamingExperimentEnabled || fallbackToPolling) ? paneSessionId : null'),
    'must pass null sessionId to useShellPaneSubscription when streaming is active'
  );
});

test('useShellStream.ts cancels in-flight connect promises via activeConnectIdRef generation counter', () => {
  assert.ok(fs.existsSync(USE_SHELL_STREAM), 'useShellStream.ts must exist');
  const src = fs.readFileSync(USE_SHELL_STREAM, 'utf8');

  assert.ok(src.includes('activeConnectIdRef'), 'must declare activeConnectIdRef generation counter');
  assert.ok(src.includes('activeConnectIdRef.current !== connectId'), 'must abort stale connection promises on generation mismatch');
});

test('BottomDock.tsx suppresses duplicate ShellTerminalPane when already viewed in main view', () => {
  const bottomDockPath = path.join(REPO_ROOT, 'src/ui/components/shell/BottomDock.tsx');
  assert.ok(fs.existsSync(bottomDockPath), 'BottomDock.tsx must exist');
  const src = fs.readFileSync(bottomDockPath, 'utf8');

  assert.ok(src.includes('isViewedInMainView'), 'must compute isViewedInMainView');
  assert.ok(src.includes('activeSession && !isViewedInMainView'), 'must only render ShellTerminalPane when not viewed in main view');
  assert.ok(src.includes('bottom-dock-duplicate-state'), 'must render duplicate feedback indicator when viewed in main view');
});

test('ShellTerminalPane.tsx preserves live cursor visibility for streaming and TUI apps', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE), 'ShellTerminalPane.tsx must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  assert.ok(!src.includes('.xterm-cursor-layer'), 'must not hide .xterm-cursor-layer');
  assert.ok(!src.includes('.xterm-cursor'), 'must not hide .xterm-cursor');
  assert.ok(!src.includes('[&_.xterm-cursor-layer]:!hidden'), 'must not hide cursor layer via tailwind');
  assert.ok(!src.includes('[&_.xterm-cursor]:!hidden'), 'must not hide cursor via tailwind');
});

test('useShellPaneSubscription.ts integrity is preserved without mutation', () => {
  assert.ok(fs.existsSync(USE_SHELL_PANE_SUB), 'useShellPaneSubscription.ts must exist');
  const src = fs.readFileSync(USE_SHELL_PANE_SUB, 'utf8');

  assert.ok(src.includes('export function useShellPaneSubscription'), 'useShellPaneSubscription must remain intact');
  assert.ok(src.includes('computeShellPanePollingInterval'), 'computeShellPanePollingInterval must remain intact');
  assert.ok(src.includes('isShellTerminalStatus'), 'isShellTerminalStatus must remain intact');
});
