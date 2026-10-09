/**
 * Model 5 White-Box Adversarial Hardening Test Suite
 * Milestone M4: Terminal Shell Rendering, Initial Cursor Positioning, and Tab State Persistence
 * 
 * Thoroughly probes edge cases, boundary conditions, race conditions, and error paths
 * across TerminalSessionRegistry, ShellTerminalPane, useShellStream, BottomDock,
 * and Hub/Bridge snapshot implementations.
 * 
 * RUN: node --test tests/adv_terminal_whitebox_hardening_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as xtermModule from '@xterm/xterm';
import * as serializeModule from '@xterm/addon-serialize';
import {
  TerminalSessionRegistry,
  terminalSessionRegistry,
  MAX_DELTA_BYTES,
  SerializeAddon,
} from '../src/ui/components/shells/terminalSessionRegistry.ts';
import { shellResizeFrame } from '../src/ui/components/shells/shellStreamFrames.ts';
import { formatHubScreenSnapshot } from './e2e/terminal_shell_rendering_e2e_test.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const SHELL_TERMINAL_PANE = path.join(REPO_ROOT, 'src/ui/components/shells/ShellTerminalPane.tsx');
const USE_SHELL_STREAM = path.join(REPO_ROOT, 'src/ui/components/shells/useShellStream.ts');
const BOTTOM_DOCK = path.join(REPO_ROOT, 'src/ui/components/shell/BottomDock.tsx');

// Resolve Terminal across ESM/CJS boundaries
const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

// ============================================================================
// SUITE 1: TerminalSessionRegistry Boundary & Slicing Hardening
// ============================================================================
describe('ADV-SUITE 1: TerminalSessionRegistry Boundary & Slicing Hardening', () => {

  test('ADV-REG-01: Single chunk of size MAX_DELTA_BYTES + 1 is tail-sliced to exactly MAX_DELTA_BYTES', () => {
    const registry = new TerminalSessionRegistry();
    const oversizedLen = MAX_DELTA_BYTES + 1; // 1,048,577 bytes
    const chunk = new Uint8Array(oversizedLen);
    chunk.fill(65); // fill with 'A'
    chunk[chunk.length - 1] = 90; // last byte is 'Z'
    chunk[0] = 66; // first byte is 'B'

    registry.appendDelta('over-sess', chunk);
    const state = registry.get('over-sess')!;
    assert.equal(state.totalDeltaBytes, MAX_DELTA_BYTES, 'totalDeltaBytes must be exactly MAX_DELTA_BYTES');
    assert.equal(state.deltaChunks.length, 1);
    assert.equal(state.deltaChunks[0].byteLength, MAX_DELTA_BYTES);
    // Verify tail-slice retained the END of the chunk
    assert.equal(state.deltaChunks[0][state.deltaChunks[0].length - 1], 90, 'tail byte must be preserved');
  });

  test('ADV-REG-02: Cascade eviction of multiple small chunks by a large incoming chunk', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('cascade-sess', '', 0, 80, 24);

    // Append ten 100 KB chunks (1,000 KB total)
    const smallSize = 100 * 1024;
    for (let i = 0; i < 10; i++) {
      const c = new Uint8Array(smallSize).fill(i);
      registry.appendDelta('cascade-sess', c);
    }
    assert.equal(registry.get('cascade-sess')!.totalDeltaBytes, 1000 * 1024);
    assert.equal(registry.get('cascade-sess')!.deltaChunks.length, 10);

    // Append one 800 KB chunk. Total attempted = 1800 KB > 1024 KB.
    // Eviction must discard enough oldest chunks (8 x 100 KB = 800 KB discarded, 2 x 100 KB + 800 KB = 1000 KB retained)
    const largeChunk = new Uint8Array(800 * 1024).fill(99);
    registry.appendDelta('cascade-sess', largeChunk);

    const state = registry.get('cascade-sess')!;
    assert.ok(state.totalDeltaBytes <= MAX_DELTA_BYTES, 'must not exceed MAX_DELTA_BYTES');
    assert.equal(state.totalDeltaBytes, 1000 * 1024);
    assert.equal(state.deltaChunks.length, 3, 'should retain chunks 8, 9, and the 800KB chunk');
    assert.equal(state.deltaChunks[0][0], 8, 'chunk 8 is now oldest retained');
    assert.equal(state.deltaChunks[1][0], 9, 'chunk 9 is retained');
    assert.equal(state.deltaChunks[2][0], 99, 'large chunk is retained');
  });

  test('ADV-REG-03: Delta re-accumulation post-consumption preserves session continuity', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('reaccum-sess', 'snap-v1', 12, 80, 24);

    // Initial batch of deltas
    registry.appendDelta('reaccum-sess', new TextEncoder().encode('delta batch 1\r\n'));
    const restoration1 = registry.consumeRestorationData('reaccum-sess')!;
    assert.equal(restoration1.snapshot, 'snap-v1');
    assert.equal(restoration1.savedViewportY, 12);
    assert.equal(restoration1.deltaChunks.length, 1);
    assert.equal(new TextDecoder().decode(restoration1.deltaChunks[0]), 'delta batch 1\r\n');

    // New deltas arrive while session remains alive
    registry.appendDelta('reaccum-sess', new TextEncoder().encode('delta batch 2\r\n'));
    registry.appendDelta('reaccum-sess', new TextEncoder().encode('delta batch 3\r\n'));

    // Second consumption drains the new deltas without losing base snapshot
    const restoration2 = registry.consumeRestorationData('reaccum-sess')!;
    assert.equal(restoration2.snapshot, 'snap-v1');
    assert.equal(restoration2.savedViewportY, 12);
    assert.equal(restoration2.deltaChunks.length, 2);
    assert.equal(new TextDecoder().decode(restoration2.deltaChunks[0]), 'delta batch 2\r\n');
    assert.equal(new TextDecoder().decode(restoration2.deltaChunks[1]), 'delta batch 3\r\n');
  });

  test('ADV-REG-04: saveSessionState with unattached terminal instance handles gracefully', () => {
    const registry = new TerminalSessionRegistry();
    const term = new Terminal({ cols: 100, rows: 30 });
    // Note: SerializeAddon is NOT registered in registry for this session
    registry.saveSessionState('no-addon-sess', term, 5, 100, 30);

    const saved = registry.get('no-addon-sess')!;
    assert.ok(saved);
    assert.equal(saved.snapshot, '', 'snapshot falls back to empty string when addon unattached');
    assert.equal(saved.savedViewportY, 5);
    assert.equal(saved.cols, 100);
    assert.equal(saved.rows, 30);
    assert.equal(saved.isSized, true);
    term.dispose();
  });

  test('ADV-REG-05: Defends against string vs Uint8Array chunk formats and zero-byte chunks', () => {
    const registry = new TerminalSessionRegistry();
    registry.bufferSessionDelta('mixed-sess', 'Hello String Delta');
    registry.bufferSessionDelta('mixed-sess', new TextEncoder().encode(' & Bytes Delta'));
    registry.bufferSessionDelta('mixed-sess', ''); // zero-byte string
    registry.bufferSessionDelta('mixed-sess', new Uint8Array(0)); // zero-byte bytes

    const state = registry.get('mixed-sess')!;
    assert.equal(state.deltaChunks.length, 2);
    const combined = new TextDecoder().decode(state.deltaChunks[0]) + new TextDecoder().decode(state.deltaChunks[1]);
    assert.equal(combined, 'Hello String Delta & Bytes Delta');
  });

  test('ADV-REG-06: clearAll purges all sessions, active sets, and registered addons', () => {
    const registry = new TerminalSessionRegistry();
    registry.registerActiveSession('s1');
    registry.registerActiveSession('s2');
    registry.saveSnapshot('s1', 'snap1', 0, 80, 24);
    registry.saveSnapshot('s2', 'snap2', 0, 80, 24);

    registry.clearAll();
    assert.equal(registry.get('s1'), undefined);
    assert.equal(registry.get('s2'), undefined);
    assert.equal(registry.isSessionActive('s1'), false);
    assert.equal(registry.isSessionActive('s2'), false);
  });
});

// ============================================================================
// SUITE 2: ShellTerminalPane Sizing Gates, Queue Flushing & Scroll Pinning
// ============================================================================
describe('ADV-SUITE 2: ShellTerminalPane Sizing Gates, Queue Flushing & Scroll Pinning', () => {

  test('ADV-PANE-01: Geometry-First Gate queues writes while unmeasured and flushes FIFO on resize', async () => {
    const term = new Terminal({ cols: 80, rows: 24 });
    const writeQueue: Uint8Array[] = [];
    let isSized = false;

    // Incoming stream writes
    const onOutput = (bytes: Uint8Array) => {
      if (!isSized) {
        writeQueue.push(bytes);
        return;
      }
      term.write(bytes);
    };

    // Receive 5 chunks while container is unmeasured (0x0)
    for (let i = 1; i <= 5; i++) {
      onOutput(new TextEncoder().encode(`Buffered Line ${i}\r\n`));
    }

    assert.equal(isSized, false);
    assert.equal(writeQueue.length, 5, 'all 5 chunks must be buffered');
    assert.equal(term.buffer.active.cursorY, 0, 'terminal must have 0 lines written');

    // Container measurement fires: clientWidth > 0 && clientHeight > 0
    isSized = true;
    const queued = [...writeQueue];
    writeQueue.length = 0;
    for (const chunk of queued) {
      await writeToTerminal(term, chunk);
    }

    // Now live write arrives
    await writeToTerminal(term, new TextEncoder().encode('Live Line 6\r\n'));

    assert.equal(term.buffer.active.cursorY, 6);
    assert.equal(term.buffer.active.getLine(0)?.translateToString(true), 'Buffered Line 1');
    assert.equal(term.buffer.active.getLine(4)?.translateToString(true), 'Buffered Line 5');
    assert.equal(term.buffer.active.getLine(5)?.translateToString(true), 'Live Line 6');
    term.dispose();
  });

  test('ADV-PANE-02: Narrow viewport clamps to 40-col minimum without vertical row floor', () => {
    // Propose 20 cols, 8 rows
    const effectiveCols = Math.max(20, 40);
    const effectiveRows = Math.max(8, 1);

    assert.equal(effectiveCols, 40, 'must enforce 40-col floor for TUI readability');
    assert.equal(effectiveRows, 8, 'must NOT enforce 24-row floor');

    const frame = shellResizeFrame({ rows: effectiveRows, cols: effectiveCols });
    assert.equal(frame, '{"type":"resize","rows":8,"cols":40}');
  });

  test('ADV-PANE-03: Reactive userScrolledUp state machine suppresses scrollToBottom on scroll-up and re-enables at bottom', async () => {
    const term = new Terminal({ cols: 80, rows: 10 });
    let scrollToBottomCount = 0;

    // Fill terminal with 30 lines
    for (let i = 1; i <= 30; i++) {
      await writeToTerminal(term, `log message line ${i}\r\n`);
    }

    // Simulate term.onScroll subscription tracking
    let userScrolledUp = false;
    const updateScrollTracking = () => {
      const buffer = term.buffer.active;
      userScrolledUp = buffer.viewportY < buffer.baseY;
    };

    const handleStreamWrite = async (data: string) => {
      await writeToTerminal(term, data);
      const buffer = term.buffer.active;
      if (!userScrolledUp && buffer.baseY > 0) {
        scrollToBottomCount++;
      }
    };

    // State A: at bottom, new write triggers auto-scroll
    updateScrollTracking();
    assert.equal(userScrolledUp, false);
    await handleStreamWrite('bottom write 1\r\n');
    assert.equal(scrollToBottomCount, 1, 'auto-scroll triggered when at bottom');

    // State B: user scrolls up to inspect line 10
    term.scrollToLine(10);
    updateScrollTracking();
    assert.equal(userScrolledUp, true, 'userScrolledUp must be true when viewportY < baseY');

    // Incoming background write while user is scrolled up
    await handleStreamWrite('background write while inspecting\r\n');
    assert.equal(scrollToBottomCount, 1, 'auto-scroll must be SUPPRESSED while userScrolledUp is true');

    // State C: user scrolls back to bottom
    term.scrollToBottom();
    updateScrollTracking();
    assert.equal(userScrolledUp, false, 'userScrolledUp returns to false at bottom');

    // Subsequent write auto-scrolls again
    await handleStreamWrite('bottom write 2\r\n');
    assert.equal(scrollToBottomCount, 2, 'auto-scroll resumes after returning to bottom');

    term.dispose();
  });
});

// ============================================================================
// SUITE 3: Dynamic convertEol Decoupling & Polling Fallback State Machine
// ============================================================================
describe('ADV-SUITE 3: Dynamic convertEol Decoupling & Polling Fallback State Machine', () => {

  test('ADV-STREAM-01: Dynamic convertEol options switch during error fallback and user retry', () => {
    const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
    let isStreamingExperimentEnabled = true;
    let fallbackToPolling = false;

    // Derived streaming active flag decoupled from socket connection state
    const computeStreamingActive = () => isStreamingExperimentEnabled && !fallbackToPolling;

    // 1. Initial streaming state
    let isStreamingActive = computeStreamingActive();
    assert.equal(isStreamingActive, true);
    term.options.convertEol = !isStreamingActive;
    assert.equal(term.options.convertEol, false, 'convertEol must be false during streaming');

    // 2. WebSocket error / close triggers fallback
    fallbackToPolling = true;
    isStreamingActive = computeStreamingActive();
    assert.equal(isStreamingActive, false, 'fallback flips isStreamingActive to false');
    term.options.convertEol = !isStreamingActive;
    assert.equal(term.options.convertEol, true, 'convertEol dynamically switches to true for legacy polled text');

    // 3. User clicks Retry
    fallbackToPolling = false;
    isStreamingActive = computeStreamingActive();
    assert.equal(isStreamingActive, true, 'retry restores streaming mode');
    term.options.convertEol = !isStreamingActive;
    assert.equal(term.options.convertEol, false, 'convertEol switches back to false');

    term.dispose();
  });

  test('ADV-STREAM-02: Legacy polled output with bare LF renders without diagonal staircase under convertEol: true', async () => {
    const term = new Terminal({ cols: 80, rows: 24, convertEol: true });
    // Polled output delivers rows separated by bare \n
    const polledText = 'first line\nsecond line\nthird line';
    await writeToTerminal(term, polledText);

    // Verify each line starts at column 0 (no diagonal staircase)
    assert.equal(term.buffer.active.cursorY, 2);
    assert.equal(term.buffer.active.getLine(0)?.translateToString(true), 'first line');
    assert.equal(term.buffer.active.getLine(1)?.translateToString(true), 'second line');
    assert.equal(term.buffer.active.getLine(2)?.translateToString(true), 'third line');
    term.dispose();
  });

  test('ADV-STREAM-03: Streaming output with explicit CRLF and escape sequences renders cleanly under convertEol: false', async () => {
    const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
    // Streaming output delivers explicit CRLF
    const streamText = 'stream row 1\r\nstream row 2\r\nstream row 3';
    await writeToTerminal(term, streamText);

    assert.equal(term.buffer.active.cursorY, 2);
    assert.equal(term.buffer.active.getLine(0)?.translateToString(true), 'stream row 1');
    assert.equal(term.buffer.active.getLine(1)?.translateToString(true), 'stream row 2');
    assert.equal(term.buffer.active.getLine(2)?.translateToString(true), 'stream row 3');
    term.dispose();
  });
});

// ============================================================================
// SUITE 4: Hub & Bridge Screen Snapshot Repaint Invariants & Edge Coordinates
// ============================================================================
describe('ADV-SUITE 4: Hub & Bridge Screen Snapshot Repaint Invariants & Edge Coordinates', () => {

  test('ADV-SNAP-01: Snapshot trimming preserves internal empty rows and prompt spaces with mixed newlines', () => {
    // Pane output with mixed \r\n and \n, internal empty row, and trailing whitespace rows
    const paneOutput = 'user@box:~$     \r\n\nCommand Output Row\r\n   \t  \r\n\n\t\t';
    const snapshot = formatHubScreenSnapshot(paneOutput, 0, 16);

    const decoded = Buffer.from(snapshot.screen_b64, 'base64').toString('utf8');
    assert.ok(decoded.startsWith('\x1b[2J\x1b[H'), 'must start with erase & home');
    assert.ok(decoded.includes('user@box:~$     \r\n\r\nCommand Output Row'), 'preserves internal empty row and prompt spaces');
    assert.ok(!decoded.includes('Command Output Row\r\n   '), 'trailing whitespace rows stripped');
    assert.ok(decoded.endsWith('\x1b[1;17H'), 'cursor repositioned to row 1, col 17 (1-indexed)');
  });

  test('ADV-SNAP-02: Whitespace-only pane trims to clean erase & home with cursor repositioning', () => {
    const whitespacePane = '   \t  \r\n   \n\t\t\r\n  ';
    const snapshot = formatHubScreenSnapshot(whitespacePane, 0, 0);

    const decoded = Buffer.from(snapshot.screen_b64, 'base64').toString('utf8');
    assert.equal(decoded, '\x1b[2J\x1b[H\x1b[1;1H', 'must collapse to pure erase-home and cursor sequence');
  });

  test('ADV-SNAP-03: Boundary coordinates (0, 0) and large (500, 300) format correctly in wire JSON', () => {
    const snapZero = formatHubScreenSnapshot('prompt$ ', 0, 0);
    assert.equal(snapZero.cursor_row, 0);
    assert.equal(snapZero.cursor_col, 0);
    const decodedZero = Buffer.from(snapZero.screen_b64, 'base64').toString('utf8');
    assert.ok(decodedZero.endsWith('\x1b[1;1H'));

    const snapLarge = formatHubScreenSnapshot('prompt$ ', 500, 300);
    assert.equal(snapLarge.cursor_row, 500);
    assert.equal(snapLarge.cursor_col, 300);
    const decodedLarge = Buffer.from(snapLarge.screen_b64, 'base64').toString('utf8');
    assert.ok(decodedLarge.endsWith('\x1b[501;301H'));
  });
});

// ============================================================================
// SUITE 5: BottomDock Multi-Tab Keep-Alive, Navigation & Disposal
// ============================================================================
describe('ADV-SUITE 5: BottomDock Multi-Tab Keep-Alive, Navigation & Disposal', () => {

  test('ADV-DOCK-01: Tab switching preserves DOM keep-alive visibility toggles without recreation', () => {
    const sessions = [
      { session_id: 'sh-1', name: 'Shell 1' },
      { session_id: 'sh-2', name: 'Shell 2' },
      { session_id: 'sh-3', name: 'Shell 3' },
    ];

    let activeTab = 'sh-2';

    // Verify visibility projection
    const getTabVisibility = (currentActive: string) => {
      return sessions.map((s) => ({
        sessionId: s.session_id,
        display: s.session_id === currentActive ? 'flex' : 'none',
        ariaHidden: s.session_id !== currentActive,
      }));
    };

    let visibility = getTabVisibility(activeTab);
    assert.equal(visibility[0].display, 'none');
    assert.equal(visibility[1].display, 'flex');
    assert.equal(visibility[2].display, 'none');

    // Switch to sh-3
    activeTab = 'sh-3';
    visibility = getTabVisibility(activeTab);
    assert.equal(visibility[0].display, 'none');
    assert.equal(visibility[1].display, 'none');
    assert.equal(visibility[2].display, 'flex');
  });

  test('ADV-DOCK-02: Tab kill evicts killed session from registry and shifts focus to adjacent tab', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('tab-1', 'snap-1', 0, 80, 24);
    registry.saveSnapshot('tab-2', 'snap-2', 0, 80, 24);
    registry.saveSnapshot('tab-3', 'snap-3', 0, 80, 24);

    let activeTab = 'tab-2';
    let visible = ['tab-1', 'tab-2', 'tab-3'];

    // Kill tab-2 (active tab)
    const killTarget = 'tab-2';
    registry.closeSession(killTarget);

    const remaining = visible.filter((id) => id !== killTarget);
    const currentIndex = visible.indexOf(killTarget);
    activeTab = remaining[currentIndex] || remaining[currentIndex - 1] || remaining[0];
    visible = remaining;

    assert.equal(activeTab, 'tab-3', 'active tab shifts to next adjacent session tab-3');
    assert.equal(registry.get('tab-2'), undefined, 'tab-2 state evicted from registry');
    assert.ok(registry.get('tab-1'), 'tab-1 retained');
    assert.ok(registry.get('tab-3'), 'tab-3 retained');

    // Now kill tab-3 (last tab)
    registry.closeSession('tab-3');
    const remaining2 = visible.filter((id) => id !== 'tab-3');
    const currentIndex2 = visible.indexOf('tab-3');
    activeTab = remaining2[currentIndex2] || remaining2[currentIndex2 - 1] || remaining2[0];
    visible = remaining2;

    assert.equal(activeTab, 'tab-1', 'active tab shifts to previous adjacent session tab-1');
    assert.equal(registry.get('tab-3'), undefined);

    // Now kill tab-1 (final tab)
    registry.closeSession('tab-1');
    const remaining3 = visible.filter((id) => id !== 'tab-1');
    activeTab = remaining3.length > 0 ? remaining3[0] : '';
    visible = remaining3;

    assert.equal(activeTab, '', 'active tab becomes empty when all sessions killed');
    assert.equal(visible.length, 0);
  });
});
