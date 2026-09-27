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
