/**
 * Empirical Stress Test Suite for Milestone M3
 * Frontend Terminal Registry & Tab Persistence
 * 
 * Conducts adversarial empirical testing on:
 * 1. 1MB Delta Cap Boundaries (10,000 rapid small chunks, single chunk >1MB slicing, FIFO pruning)
 * 2. @xterm/addon-serialize Fidelity (500+ lines scrollback round-trip, 24-bit TrueColor, alternate screen buffer)
 * 3. Concurrency, Edge Cases, Multi-session Isolation & Replay Robustness
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';
import {
  TerminalSessionRegistry,
  MAX_DELTA_BYTES,
  SerializeAddon,
} from '../src/ui/components/shells/terminalSessionRegistry.ts';

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

describe('Empirical Challenge 1: 1MB Delta Cap Boundaries & FIFO Pruning', () => {
  test('EC 1.1: 10,000 rapid small chunks stress test', () => {
    const registry = new TerminalSessionRegistry();
    const sessionId = 'stress-10k-chunks';
    const numChunks = 10000;
    const chunkSize = 150; // Total: 1,500,000 bytes (~1.43 MB)

    // Pre-allocate buffer for rapid writes
    for (let i = 0; i < numChunks; i++) {
      const chunk = new Uint8Array(chunkSize);
      // Store 32-bit chunk index at start of chunk
      const view = new DataView(chunk.buffer);
      view.setUint32(0, i, true);
      registry.appendDelta(sessionId, chunk);
    }

    const state = registry.get(sessionId)!;
    assert.ok(state, 'Session state must exist');

    // Invariant 1: Total bytes must NEVER exceed MAX_DELTA_BYTES (1,048,576)
    assert.ok(
      state.totalDeltaBytes <= MAX_DELTA_BYTES,
      `totalDeltaBytes (${state.totalDeltaBytes}) must be <= ${MAX_DELTA_BYTES}`
    );

    // Invariant 2: totalDeltaBytes must strictly match the sum of bytes in deltaBuffer
    const actualSum = state.deltaBuffer.reduce((acc, c) => acc + c.byteLength, 0);
    assert.equal(
      state.totalDeltaBytes,
      actualSum,
      `totalDeltaBytes (${state.totalDeltaBytes}) must equal actual sum (${actualSum})`
    );

    // Invariant 3: FIFO order must be strictly preserved
    let prevIndex = -1;
    for (let j = 0; j < state.deltaBuffer.length; j++) {
      const view = new DataView(state.deltaBuffer[j].buffer, state.deltaBuffer[j].byteOffset);
      const chunkIdx = view.getUint32(0, true);
      assert.ok(
        chunkIdx > prevIndex,
        `Chunk index must be strictly monotonically increasing (got ${chunkIdx} <= ${prevIndex})`
      );
      prevIndex = chunkIdx;
    }

    // Invariant 4: Newest chunk (9999) must be retained at the end of the buffer
    const lastChunk = state.deltaBuffer[state.deltaBuffer.length - 1];
    const lastView = new DataView(lastChunk.buffer, lastChunk.byteOffset);
    assert.equal(lastView.getUint32(0, true), numChunks - 1, 'The very last chunk must be preserved');

    // Invariant 5: Oldest chunks (e.g. index 0) must have been pruned
    const firstChunk = state.deltaBuffer[0];
    const firstView = new DataView(firstChunk.buffer, firstChunk.byteOffset);
    assert.ok(
      firstView.getUint32(0, true) > 0,
      `Oldest chunk 0 must have been pruned (first chunk index is ${firstView.getUint32(0, true)})`
    );

    // Capacity check: Math.floor(1048576 / 150) = 6990 chunks = 1,048,500 bytes
    assert.equal(state.deltaBuffer.length, Math.floor(MAX_DELTA_BYTES / chunkSize));
    assert.equal(state.totalDeltaBytes, Math.floor(MAX_DELTA_BYTES / chunkSize) * chunkSize);
  });

  test('EC 1.2: Single chunk > 1MB slicing (2MB and 5MB chunks)', () => {
    const registry = new TerminalSessionRegistry();
    const sessionId = 'stress-huge-chunk';

    // Create 5MB chunk
    const fiveMbSize = 5 * 1024 * 1024;
    const hugeChunk = new Uint8Array(fiveMbSize);
    // Write marker at head
    hugeChunk[0] = 0xAA;
    hugeChunk[1] = 0xBB;
    // Write marker at the exact last 1MB boundary
    const lastMbOffset = fiveMbSize - MAX_DELTA_BYTES;
    hugeChunk[lastMbOffset] = 0x11;
    hugeChunk[lastMbOffset + 1] = 0x22;
    // Write marker at tail
    hugeChunk[fiveMbSize - 2] = 0xEE;
    hugeChunk[fiveMbSize - 1] = 0xFF;

    registry.appendDelta(sessionId, hugeChunk);

    const state5Mb = registry.get(sessionId)!;
    assert.ok(state5Mb);
    assert.equal(state5Mb.totalDeltaBytes, MAX_DELTA_BYTES);
    assert.equal(state5Mb.deltaBuffer.length, 1);
    assert.equal(state5Mb.deltaBuffer[0].byteLength, MAX_DELTA_BYTES);

    // Verify it sliced the tail (newest bytes) and discarded head (oldest bytes)
    const retained = state5Mb.deltaBuffer[0];
    assert.equal(retained[0], 0x11, 'Retained slice must start at last 1MB boundary of huge chunk');
    assert.equal(retained[1], 0x22);
    assert.equal(retained[retained.length - 2], 0xEE, 'Retained slice must end with newest bytes');
    assert.equal(retained[retained.length - 1], 0xFF);

    // Now push a 2MB chunk over it
    const twoMbSize = 2 * 1024 * 1024;
    const twoMbChunk = new Uint8Array(twoMbSize).fill(0x77);
    twoMbChunk[twoMbSize - 1] = 0x99;
    registry.appendDelta(sessionId, twoMbChunk);

    const state2Mb = registry.get(sessionId)!;
    assert.equal(state2Mb.totalDeltaBytes, MAX_DELTA_BYTES);
    assert.equal(state2Mb.deltaBuffer.length, 1, 'Previous chunks must be completely pruned');
    assert.equal(state2Mb.deltaBuffer[0][0], 0x77);
    assert.equal(state2Mb.deltaBuffer[0][state2Mb.deltaBuffer[0].byteLength - 1], 0x99);
  });

  test('EC 1.3: Boundary transitions: exactly 1,048,576 bytes threshold', () => {
    const registry = new TerminalSessionRegistry();
    const sessionId = 'stress-boundary-exact';

    // Step 1: Push 1,048,575 bytes (1 byte below cap)
    const chunkA = new Uint8Array(MAX_DELTA_BYTES - 1).fill(0x41);
    registry.appendDelta(sessionId, chunkA);
    assert.equal(registry.get(sessionId)!.totalDeltaBytes, MAX_DELTA_BYTES - 1);
    assert.equal(registry.get(sessionId)!.deltaBuffer.length, 1);

    // Step 2: Push 1 byte (exactly reaches 1,048,576 bytes)
    const chunkB = new Uint8Array([0x42]);
    registry.appendDelta(sessionId, chunkB);
    assert.equal(registry.get(sessionId)!.totalDeltaBytes, MAX_DELTA_BYTES);
    assert.equal(registry.get(sessionId)!.deltaBuffer.length, 2);

    // Step 3: Push 1 more byte (exceeds cap by 1 byte -> chunkA must be pruned)
    const chunkC = new Uint8Array([0x43]);
    registry.appendDelta(sessionId, chunkC);
    // Since chunkA was 1,048,575 bytes, removing it leaves chunkB (1 byte) + chunkC (1 byte) = 2 bytes
    assert.equal(registry.get(sessionId)!.totalDeltaBytes, 2);
    assert.equal(registry.get(sessionId)!.deltaBuffer.length, 2);
    assert.equal(registry.get(sessionId)!.deltaBuffer[0][0], 0x42);
    assert.equal(registry.get(sessionId)!.deltaBuffer[1][0], 0x43);
  });

  test('EC 1.4: Mixed string and binary delta stream with UTF-8 multi-byte glyphs', () => {
    const registry = new TerminalSessionRegistry();
    const sessionId = 'stress-mixed-utf8';

    // 4-byte UTF-8 emoji
    const emojiStr = '🚀🔥⚡️🎉';
    registry.bufferSessionDelta(sessionId, emojiStr);

    const encoder = new TextEncoder();
    const expectedBytes = encoder.encode(emojiStr);

    const state = registry.get(sessionId)!;
    assert.equal(state.totalDeltaBytes, expectedBytes.byteLength);
    assert.deepEqual(state.deltaBuffer[0], expectedBytes);

    // Drain and verify
    const drained = registry.drainSessionDeltas(sessionId);
    assert.equal(drained.length, 1);
    assert.equal(new TextDecoder().decode(drained[0]), emojiStr);
    assert.equal(registry.get(sessionId)!.totalDeltaBytes, 0);
  });
});

describe('Empirical Challenge 2: @xterm/addon-serialize Fidelity & Terminal Reconstruction', () => {
  test('EC 2.1: 500+ lines scrollback round-trip fidelity', async () => {
    const termSource = new Terminal({ cols: 80, rows: 24, scrollback: 1000 });
    const serializeAddon = new SerializeAddon();
    termSource.loadAddon(serializeAddon);

    const TOTAL_LINES = 600;
    // Write 600 lines
    for (let i = 1; i <= TOTAL_LINES; i++) {
      const lineStr = `[LINE ${String(i).padStart(4, '0')}] payload data for scrollback verification\r\n`;
      await writeToTerminal(termSource, lineStr);
    }

    // Verify termSource has scrolled down
    const sourceBaseY = termSource.buffer.active.baseY;
    assert.ok(sourceBaseY >= TOTAL_LINES - 24, `baseY (${sourceBaseY}) should reflect 600 lines written`);

    // Serialize
    const serialized = serializeAddon.serialize();
    assert.ok(serialized.length > 0, 'Serialized content must not be empty');

    // Save in registry
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('sess-scrollback-500', serialized, termSource.buffer.active.viewportY, 80, 24);

    // Consume and replay in fresh terminal
    const data = registry.consumeRestorationData('sess-scrollback-500')!;
    const termTarget = new Terminal({ cols: 80, rows: 24, scrollback: 1000 });
    await writeToTerminal(termTarget, data.snapshot);

    // Compare baseY
    assert.equal(termTarget.buffer.active.baseY, sourceBaseY, 'Target baseY must match source baseY');

    // Spot-check lines across scrollback
    const checkLineIndices = [0, 50, 150, 300, 450, 550, 575];
    for (const idx of checkLineIndices) {
      const srcLine = termSource.buffer.active.getLine(idx)?.translateToString(true);
      const tgtLine = termTarget.buffer.active.getLine(idx)?.translateToString(true);
      assert.equal(tgtLine, srcLine, `Line at index ${idx} must match exactly`);
    }

    termSource.dispose();
    termTarget.dispose();
  });

  test('EC 2.2: 24-bit TrueColor and Complex SGR Attributes Round-Trip', async () => {
    const termSource = new Terminal({ cols: 80, rows: 24 });
    const serializeAddon = new SerializeAddon();
    termSource.loadAddon(serializeAddon);

    // TrueColor fg (255, 100, 50) + TrueColor bg (20, 30, 40) + Bold + Underline
    const styledText = '\x1b[38;2;255;100;50m\x1b[48;2;20;30;40m\x1b[1;4mTRUECOLOR_AND_STYLE\x1b[0m\r\n';
    await writeToTerminal(termSource, styledText);

    const serialized = serializeAddon.serialize();
    assert.ok(serialized.includes('TRUECOLOR_AND_STYLE'));

    const termTarget = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(termTarget, serialized);

    const renderedLine = termTarget.buffer.active.getLine(0)?.translateToString(true);
    assert.ok(renderedLine?.includes('TRUECOLOR_AND_STYLE'), 'Styled text content must be retained');

    termSource.dispose();
    termTarget.dispose();
  });

  test('EC 2.3: Alternate screen buffer (Neovim / TUI) round-trip fidelity', async () => {
    const termSource = new Terminal({ cols: 80, rows: 24 });
    const serializeAddon = new SerializeAddon();
    termSource.loadAddon(serializeAddon);

    // Write something in normal buffer first
    await writeToTerminal(termSource, 'bash-5.2$ nvim test.txt\r\n');

    // Switch to alternate screen buffer: \x1b[?1049h
    // Clear and draw Neovim layout:
    // Line 1: header
    // Line 23: status bar
    // Line 24: command prompt
    const nvimBufferSequence =
      '\x1b[?1049h\x1b[2J\x1b[H' +
      '1 | fn main() {\r\n' +
      '2 |     println!("Hello World");\r\n' +
      '3 | }\r\n' +
      '\x1b[23;1H\x1b[7m[NORMAL] test.txt  [unix]  utf-8  100%  3:2\x1b[0m' +
      '\x1b[24;1H:';

    await writeToTerminal(termSource, nvimBufferSequence);

    // Verify termSource is in alternate buffer
    assert.equal(termSource.buffer.active.type, 'alternate');

    // Serialize
    const serialized = serializeAddon.serialize();
    assert.ok(serialized.length > 0);

    // Restore to termTarget
    const termTarget = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(termTarget, serialized);

    // Verify content in target terminal
    const activeBuf = termTarget.buffer.active;
    const l1 = activeBuf.getLine(0)?.translateToString(true);
    const l2 = activeBuf.getLine(1)?.translateToString(true);
    const l3 = activeBuf.getLine(2)?.translateToString(true);
    const lStatusBar = activeBuf.getLine(22)?.translateToString(true);
    const lCmd = activeBuf.getLine(23)?.translateToString(true);

    assert.ok(l1?.includes('1 | fn main() {'), `Line 1 should contain code, got: "${l1}"`);
    assert.ok(l2?.includes('2 |     println!("Hello World");'), `Line 2 should contain code, got: "${l2}"`);
    assert.ok(l3?.includes('3 | }'), `Line 3 should contain code, got: "${l3}"`);
    assert.ok(lStatusBar?.includes('[NORMAL] test.txt'), `Status bar should be preserved, got: "${lStatusBar}"`);
    assert.ok(lCmd?.includes(':'), `Command line should be preserved, got: "${lCmd}"`);

    termSource.dispose();
    termTarget.dispose();
  });

  test('EC 2.4: Snapshot + buffered deltas full sequential reconstruction', async () => {
    const registry = new TerminalSessionRegistry();
    const sessionId = 'full-reconstruct-sess';

    // Step 1: Active terminal produces base snapshot
    const term1 = new Terminal({ cols: 80, rows: 24 });
    const serialize1 = new SerializeAddon();
    term1.loadAddon(serialize1);

    await writeToTerminal(term1, 'STEP 1: Starting Build Process...\r\n');
    await writeToTerminal(term1, 'STEP 2: Compiling assets...\r\n');

    registry.saveSnapshot(sessionId, serialize1.serialize(), 0, 80, 24);
    term1.dispose();

    // Step 2: Tab is unmounted, background process emits 50 deltas
    for (let i = 1; i <= 50; i++) {
      registry.appendDelta(sessionId, new TextEncoder().encode(`DELTA LOG ${i}: ok\r\n`));
    }

    // Step 3: Tab remounts and replays snapshot + all 50 deltas
    const restoration = registry.consumeRestorationData(sessionId)!;
    assert.ok(restoration);
    assert.equal(restoration.deltaChunks.length, 50);

    const term2 = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(term2, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(term2, chunk);
    }

    // Verify initial snapshot content is at the top
    const l0 = term2.buffer.active.getLine(0)?.translateToString(true);
    const l1 = term2.buffer.active.getLine(1)?.translateToString(true);
    assert.equal(l0, 'STEP 1: Starting Build Process...');
    assert.equal(l1, 'STEP 2: Compiling assets...');

    // Verify deltas follow sequentially
    const l2 = term2.buffer.active.getLine(2)?.translateToString(true);
    assert.equal(l2, 'DELTA LOG 1: ok');

    const l51 = term2.buffer.active.getLine(51)?.translateToString(true);
    assert.equal(l51, 'DELTA LOG 50: ok');

    term2.dispose();
  });
});

describe('Empirical Challenge 3: Concurrency, Edge Cases & Multi-Session Isolation', () => {
  test('EC 3.1: 10 Concurrent sessions streaming under load without cross-talk', () => {
    const registry = new TerminalSessionRegistry();
    const NUM_SESSIONS = 10;
    const CHUNKS_PER_SESSION = 500;

    // Initialize 10 sessions
    for (let s = 0; s < NUM_SESSIONS; s++) {
      const sessId = `concurrent-sess-${s}`;
      registry.saveSnapshot(sessId, `snapshot-for-${sessId}`, 0, 80, 24);
      registry.registerActiveSession(sessId);
    }

    // Stream chunks interleaved across all sessions
    for (let c = 0; c < CHUNKS_PER_SESSION; c++) {
      for (let s = 0; s < NUM_SESSIONS; s++) {
        const sessId = `concurrent-sess-${s}`;
        const chunk = new TextEncoder().encode(`s:${s}-c:${c};`);
        registry.appendDelta(sessId, chunk);
      }
    }

    // Verify each session received only its own data
    for (let s = 0; s < NUM_SESSIONS; s++) {
      const sessId = `concurrent-sess-${s}`;
      const restoration = registry.consumeRestorationData(sessId)!;
      assert.ok(restoration, `Restoration for ${sessId} must exist`);
      assert.equal(restoration.snapshot, `snapshot-for-${sessId}`);
      assert.equal(restoration.deltaChunks.length, CHUNKS_PER_SESSION);

      for (let c = 0; c < CHUNKS_PER_SESSION; c++) {
        const chunkStr = new TextDecoder().decode(restoration.deltaChunks[c]);
        assert.equal(chunkStr, `s:${s}-c:${c};`, `Session ${sessId} chunk ${c} must match exactly`);
      }
    }
  });

  test('EC 3.2: Edge and falsy input handling', () => {
    const registry = new TerminalSessionRegistry();
    const sessId = 'falsy-inputs-sess';

    // Falsy chunks must not throw or create empty entries
    (registry as any).appendDelta(sessId, null);
    (registry as any).appendDelta(sessId, undefined);
    registry.appendDelta(sessId, new Uint8Array(0));
    registry.bufferSessionDelta(sessId, '');

    assert.equal(registry.get(sessId), undefined, 'No state should be created for purely empty/null deltas');

    // Negative / default parameters in saveSnapshot
    registry.saveSnapshot(sessId, 'valid-snap', -5, -80, -24);
    const state = registry.get(sessId)!;
    assert.equal(state.snapshot, 'valid-snap');
    assert.equal(state.savedViewportY, -5);
  });

  test('EC 3.3: Rapid tab switch and mid-stream closeSession hygiene', () => {
    const registry = new TerminalSessionRegistry();
    const sessId = 'rapid-tab-close-sess';

    registry.saveSnapshot(sessId, 'snap-before-close', 10, 80, 24);
    registry.appendDelta(sessId, new TextEncoder().encode('chunk before close'));

    // Tab killed
    registry.closeSession(sessId);

    // Verify total eviction
    assert.equal(registry.get(sessId), undefined);
    assert.equal(registry.consumeRestorationData(sessId), null);
    assert.equal(registry.isSessionActive(sessId), false);
    assert.equal(registry.hasSessionState(sessId), false);

    // If new deltas arrive for the closed session, they start fresh cleanly
    registry.appendDelta(sessId, new TextEncoder().encode('chunk after reopen'));
    const fresh = registry.consumeRestorationData(sessId)!;
    assert.equal(fresh.snapshot, '', 'Old snapshot must not leak into reopened session');
    assert.equal(fresh.deltaChunks.length, 1);
    assert.equal(new TextDecoder().decode(fresh.deltaChunks[0]), 'chunk after reopen');
  });
});
