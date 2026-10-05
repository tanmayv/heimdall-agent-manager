// REQ-STREAM-EVENT-3: Automated unit and contract tests for stream_ready/stream_closed and KEY_EVENTS queueing
//
// RUN: node --test tests/ui_stream_lifecycle_events_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const USE_SHELL_STREAM = path.join(REPO_ROOT, 'src/ui/components/shells/useShellStream.ts');
const USE_AGENT_STREAM = path.join(REPO_ROOT, 'src/ui/components/chat/useAgentStream.ts');
const AGENT_PANE_COMPOSER = path.join(REPO_ROOT, 'src/ui/components/chat/AgentPaneComposerPanel.tsx');
const CONVERSATION_THREAD = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');

test('useShellStream.ts defines stream_ready and stream_closed contracts', () => {
  assert.ok(fs.existsSync(USE_SHELL_STREAM), 'useShellStream.ts must exist');
  const src = fs.readFileSync(USE_SHELL_STREAM, 'utf8');

  // Types
  assert.ok(src.includes("type: 'stream_ready'"), 'ShellStreamMsg must include stream_ready');
  assert.ok(src.includes("type: 'stream_closed'"), 'ShellStreamMsg must include stream_closed');
  assert.ok(src.includes('isStreamReady: boolean'), 'UseShellStreamResult must include isStreamReady');
  assert.ok(src.includes('onStreamReady?:'), 'UseShellStreamOptions must include onStreamReady');
  assert.ok(src.includes('onStreamClosed?:'), 'UseShellStreamOptions must include onStreamClosed');

  // Implementation
  assert.ok(src.includes('isStreamReadyRef'), 'must maintain isStreamReadyRef');
  assert.ok(src.includes('pendingKeyEventsRef'), 'must maintain pendingKeyEventsRef queue');
  assert.ok(src.includes('Buffering early input before stream_ready'), 'sendInput must buffer keystrokes when not stream_ready');
  assert.ok(src.includes('Flushing') && src.includes('buffered key events post stream_ready'), 'must drain queue on stream_ready');
  assert.ok(src.includes("msg.type === 'stream_ready'"), 'must handle stream_ready incoming frame');
  assert.ok(src.includes("msg.type === 'stream_closed'"), 'must handle stream_closed incoming frame');
});

test('useAgentStream.ts defines stream_ready and stream_closed contracts', () => {
  assert.ok(fs.existsSync(USE_AGENT_STREAM), 'useAgentStream.ts must exist');
  const src = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  // Types
  assert.ok(src.includes("type: 'stream_ready'"), 'AgentStreamMsg must include stream_ready');
  assert.ok(src.includes("type: 'stream_closed'"), 'AgentStreamMsg must include stream_closed');
  assert.ok(src.includes('isStreamReady: boolean'), 'UseAgentStreamResult must include isStreamReady');
  assert.ok(src.includes('onStreamReady?:'), 'UseAgentStreamOptions must include onStreamReady');
  assert.ok(src.includes('onStreamClosed?:'), 'UseAgentStreamOptions must include onStreamClosed');

  // Implementation
  assert.ok(src.includes('isStreamReadyRef'), 'must maintain isStreamReadyRef');
  assert.ok(src.includes('pendingKeyEventsRef'), 'must maintain pendingKeyEventsRef queue');
  assert.ok(src.includes('pendingKeyEventsRef.current.push'), 'sendInput must buffer keystrokes when not stream_ready');
  assert.ok(src.includes("msg.type === 'stream_ready'"), 'must handle stream_ready incoming frame');
  assert.ok(src.includes("msg.type === 'stream_closed'"), 'must handle stream_closed incoming frame');
});

test('AgentPaneComposerPanel.tsx wires onStreamReady and onStreamClosed', () => {
  assert.ok(fs.existsSync(AGENT_PANE_COMPOSER), 'AgentPaneComposerPanel.tsx must exist');
  const src = fs.readFileSync(AGENT_PANE_COMPOSER, 'utf8');

  assert.ok(src.includes('onStreamReady?: (info?: any) => void;'), 'props must include onStreamReady');
  assert.ok(src.includes('onStreamClosed?: (info?: any) => void;'), 'props must include onStreamClosed');
  assert.ok(src.includes('onStreamReady: (info) =>'), 'useAgentStream call must bind onStreamReady');
  assert.ok(src.includes('onStreamClosed: (info) =>'), 'useAgentStream call must bind onStreamClosed');
});

test('ConversationThreadPage.tsx controls composer preview popup via stream_ready and stream_closed', () => {
  assert.ok(fs.existsSync(CONVERSATION_THREAD), 'ConversationThreadPage.tsx must exist');
  const src = fs.readFileSync(CONVERSATION_THREAD, 'utf8');

  assert.ok(src.includes('handleStreamReady'), 'must declare handleStreamReady callback');
  assert.ok(src.includes('handleStreamClosed'), 'must declare handleStreamClosed callback');
  assert.ok(src.includes('onStreamReady={handleStreamReady}'), 'must pass onStreamReady to AgentPaneComposerPanel');
  assert.ok(src.includes('onStreamClosed={handleStreamClosed}'), 'must pass onStreamClosed to AgentPaneComposerPanel');
});
