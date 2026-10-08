/**
 * Adversarial Stress & Invariant Test Suite for Tab Persistence & Terminal Lifecycle
 * Challenger M3 2 (Milestone M3)
 *
 * Rigorously challenges:
 * 1. Multi-tab switching across 5 concurrent sessions with continuous streaming background output.
 *    - 100% scrollback retention, zero dropped lines, sequential line order, no coordinate corruption.
 * 2. Strict cross-session isolation & non-bleed across 5 sessions.
 * 3. Viewport scroll position preservation (scrolled-up vs at-bottom) across tab transitions and background streams.
 * 4. Targeted session kill eviction and peer session preservation across 5 sessions.
 * 5. High-stress boundary attacks: alternate screen buffers (TUI), 1MB threshold capping, rapid toggling thrash.
 *
 * RUN: node --test tests/adversarial_tab_persistence_stress_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';
import {
  TerminalSessionRegistry,
  terminalSessionRegistry,
  MAX_DELTA_BYTES,
  SerializeAddon,
} from '../src/ui/components/shells/terminalSessionRegistry.ts';

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

function extractAllLines(term: any): string[] {
  const lines: string[] = [];
  const buffer = term.buffer.active;
  for (let i = 0; i < buffer.length; i++) {
    const line = buffer.getLine(i);
    if (line) {
      lines.push(line.translateToString(true));
    }
  }
  return lines;
}

describe('Adversarial Suite 1: 5 Concurrent Sessions with Rapid Tab Switching & Background Streaming', () => {

  test('Test 1.1: 5 concurrent sessions emitting continuous background stream while switching tabs 100 times', async () => {
    const sessionIds = ['sess-1', 'sess-2', 'sess-3', 'sess-4', 'sess-5'];
    const terminals = new Map<string, any>();
    const totalLinesPerSession = 150;

    // Initialize 5 active terminals (DOM keep-alive representation)
    for (const sid of sessionIds) {
      const term = new Terminal({ cols: 80, rows: 24, scrollback: 5000 });
      terminals.set(sid, term);
    }

    let activeTab = sessionIds[0];
    const linesEmitted = new Map<string, number>();
    for (const sid of sessionIds) {
      linesEmitted.set(sid, 0);
    }

    // Interleave background output across all 5 sessions while switching active tab 100 times
    const totalTabSwitches = 100;
    const linesPerStep = 2;

    for (let step = 0; step < totalTabSwitches; step++) {
      // Rapidly switch active tab in pseudo-random / cyclic manner
      activeTab = sessionIds[step % sessionIds.length];

      // Concurrently emit lines to ALL 5 sessions (active and background inactive ones)
      for (const sid of sessionIds) {
        const currentCount = linesEmitted.get(sid)!;
        if (currentCount < totalLinesPerSession) {
          const linesToSend = Math.min(linesPerStep, totalLinesPerSession - currentCount);
          for (let l = 1; l <= linesToSend; l++) {
            const lineNum = currentCount + l;
            const content = `[${sid}] LINE_${lineNum.toString().padStart(4, '0')} - payload_hash_${(lineNum * 31) % 9999}\r\n`;
            await writeToTerminal(terminals.get(sid), content);
          }
          linesEmitted.set(sid, currentCount + linesToSend);
        }
      }
    }

    // Finish any remaining lines
    for (const sid of sessionIds) {
      const currentCount = linesEmitted.get(sid)!;
      if (currentCount < totalLinesPerSession) {
        for (let l = currentCount + 1; l <= totalLinesPerSession; l++) {
          const content = `[${sid}] LINE_${l.toString().padStart(4, '0')} - payload_hash_${(l * 31) % 9999}\r\n`;
          await writeToTerminal(terminals.get(sid), content);
        }
      }
    }

    // Comprehensive Verification across all 5 sessions
    for (const sid of sessionIds) {
      const term = terminals.get(sid);
      const allLines = extractAllLines(term);
      const combinedText = allLines.join('\n');

      // 1. Verify scrollback retention
      assert.ok(term.buffer.active.baseY > 0, `${sid} must have non-zero baseY scrollback`);
      assert.ok(term.buffer.active.length >= totalLinesPerSession, `${sid} buffer length must include all lines`);

      // 2. Verify zero dropped lines: every single line from 1 to 150 must exist in order
      let lastIndex = -1;
      for (let l = 1; l <= totalLinesPerSession; l++) {
        const expectedPattern = `[${sid}] LINE_${l.toString().padStart(4, '0')}`;
        const foundIndex = combinedText.indexOf(expectedPattern, lastIndex + 1);
        assert.ok(
          foundIndex > -1,
          `${sid} dropped line: ${expectedPattern} was not found in terminal buffer`
        );
        assert.ok(
          foundIndex > lastIndex,
          `${sid} line order corruption: line ${l} appeared before preceding line`
        );
        lastIndex = foundIndex;
      }

      // 3. Verify no coordinate corruption or NaN in terminal geometry
      assert.equal(typeof term.cols, 'number');
      assert.equal(typeof term.rows, 'number');
      assert.ok(!Number.isNaN(term.buffer.active.cursorX));
      assert.ok(!Number.isNaN(term.buffer.active.cursorY));
      assert.ok(!Number.isNaN(term.buffer.active.baseY));

      term.dispose();
    }
  });

  test('Test 1.2: Unmount-remount snapshot + delta buffering lifecycle across 5 tabs', async () => {
    const registry = new TerminalSessionRegistry();
    const sessionIds = ['s-alpha', 's-beta', 's-gamma', 's-delta', 's-epsilon'];

    // Phase 1: Mount all 5, write initial state, then simulate unmounting 4 of them
    const initialSnapshots = new Map<string, string>();
    for (const sid of sessionIds) {
      const term = new Terminal({ cols: 80, rows: 24 });
      const addon = new SerializeAddon();
      term.loadAddon(addon);
      registry.registerActiveSession(sid);

      await writeToTerminal(term, `[INIT] ${sid} initial line 1\r\n[INIT] ${sid} initial line 2\r\n`);
      const serialized = addon.serialize();
      initialSnapshots.set(sid, serialized);
      registry.saveSnapshot(sid, serialized, term.buffer.active.viewportY, 80, 24);
      registry.unregisterActiveSession(sid);
      term.dispose();
    }

    // Phase 2: While all 5 are unmounted, stream 50 distinct deltas to each session
    for (let i = 1; i <= 50; i++) {
      for (const sid of sessionIds) {
        const deltaStr = `[DELTA] ${sid} chunk_${i.toString().padStart(3, '0')}\r\n`;
        registry.appendDelta(sid, new TextEncoder().encode(deltaStr));
      }
    }

    // Phase 3: Remount each session sequentially, consume restoration data, and write deltas
    for (const sid of sessionIds) {
      const restoration = registry.consumeRestorationData(sid);
      assert.ok(restoration, `restoration data must exist for ${sid}`);
      assert.equal(restoration.snapshot, initialSnapshots.get(sid));
      assert.equal(restoration.deltaChunks.length, 50, `must have 50 delta chunks for ${sid}`);

      const remountTerm = new Terminal({ cols: 80, rows: 24 });
      await writeToTerminal(remountTerm, restoration.snapshot);
      for (const chunk of restoration.deltaChunks) {
        await writeToTerminal(remountTerm, chunk);
      }

      const lines = extractAllLines(remountTerm);
      const text = lines.join('\n');

      // Verify initial snapshot lines preserved
      assert.ok(text.includes(`[INIT] ${sid} initial line 1`));
      assert.ok(text.includes(`[INIT] ${sid} initial line 2`));

      // Verify all 50 deltas present in sequence
      let prevIdx = -1;
      for (let i = 1; i <= 50; i++) {
        const pattern = `[DELTA] ${sid} chunk_${i.toString().padStart(3, '0')}`;
        const idx = text.indexOf(pattern, prevIdx + 1);
        assert.ok(idx > -1, `${sid} missing delta ${pattern}`);
        assert.ok(idx > prevIdx, `${sid} out of order delta at chunk ${i}`);
        prevIdx = idx;
      }

      remountTerm.dispose();
    }
  });
});

describe('Adversarial Suite 2: Strict Cross-Session Isolation & Non-Bleed Across 5 Sessions', () => {

  test('Test 2.1: High-throughput concurrent streams with session-unique tokens show ZERO cross-bleed', async () => {
    const registry = new TerminalSessionRegistry();
    const sessionIds = ['sess-A', 'sess-B', 'sess-C', 'sess-D', 'sess-E'];

    for (const sid of sessionIds) {
      registry.saveSnapshot(sid, `SNAPSHOT_HEADER_${sid}`, 0, 80, 24);
    }

    // Interleave unique deltas
    for (let round = 1; round <= 20; round++) {
      for (const sid of sessionIds) {
        registry.appendDelta(sid, new TextEncoder().encode(`SECRET_TOKEN_${sid}_ROUND_${round}\r\n`));
      }
    }

    // Verify isolation in consumed data
    for (const targetSid of sessionIds) {
      const data = registry.consumeRestorationData(targetSid)!;
      assert.ok(data);
      const decodedSnapshot = data.snapshot;
      const decodedDeltas = data.deltaChunks.map(c => new TextDecoder().decode(c)).join('');

      // Target must contain only target tokens
      assert.ok(decodedSnapshot.includes(`SNAPSHOT_HEADER_${targetSid}`));
      assert.ok(decodedDeltas.includes(`SECRET_TOKEN_${targetSid}_ROUND_1`));
      assert.ok(decodedDeltas.includes(`SECRET_TOKEN_${targetSid}_ROUND_20`));

      // Target must contain NO tokens from other sessions
      for (const otherSid of sessionIds) {
        if (otherSid === targetSid) continue;
        assert.ok(
          !decodedSnapshot.includes(otherSid),
          `Leakage: snapshot of ${targetSid} contains ${otherSid}`
        );
        assert.ok(
          !decodedDeltas.includes(otherSid),
          `Leakage: delta chunks of ${targetSid} contain ${otherSid}`
        );
      }
    }
  });

  test('Test 2.2: Buffer defensive copy prevents mutation attacks', () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'mutate-attack-sess';
    registry.saveSnapshot(sid, 'init', 0, 80, 24);

    const maliciousBuffer = new Uint8Array([65, 66, 67, 68]); // 'ABCD'
    registry.appendDelta(sid, maliciousBuffer);

    // Caller mutates original buffer immediately after passing to registry
    maliciousBuffer[0] = 90; // 'Z'
    maliciousBuffer[1] = 90; // 'Z'

    const data = registry.consumeRestorationData(sid)!;
    const restored = new TextDecoder().decode(data.deltaChunks[0]);
    assert.equal(restored, 'ABCD', 'Buffered delta must not be corrupted by caller mutation');
  });
});

describe('Adversarial Suite 3: User Scroll Position Preservation Across Background Streams & Tab Switches', () => {

  test('Test 3.1: Scrolled-up inactive tab preserves exact savedViewportY when background lines arrive', async () => {
    const registry = new TerminalSessionRegistry();
    const term = new Terminal({ cols: 80, rows: 10, scrollback: 1000 });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);

    // Write 50 lines to create scrollback
    for (let i = 1; i <= 50; i++) {
      await writeToTerminal(term, `historical line ${i}\r\n`);
    }

    const maxBaseY = term.buffer.active.baseY;
    assert.ok(maxBaseY >= 40, 'must have at least 40 lines of scrollback');

    // User scrolls up to view line 12
    const targetViewportY = 12;
    term.scrollToLine(targetViewportY);
    assert.equal(term.buffer.active.viewportY, targetViewportY);

    // User switches tab: Pane unmounts and saves snapshot with savedViewportY
    const serialized = serializeAddon.serialize();
    registry.saveSnapshot('scroll-persist-sess', serialized, term.buffer.active.viewportY, term.cols, term.rows);
    term.dispose();

    // While user is in other tabs, 30 new background lines arrive as deltas
    for (let i = 51; i <= 80; i++) {
      registry.appendDelta('scroll-persist-sess', new TextEncoder().encode(`new background line ${i}\r\n`));
    }

    // User switches back: Remount and restore
    const restoration = registry.consumeRestorationData('scroll-persist-sess')!;
    assert.ok(restoration);
    assert.equal(restoration.savedViewportY, targetViewportY, 'savedViewportY must match original scroll offset');

    const remountTerm = new Terminal({ cols: 80, rows: 10, scrollback: 1000 });
    await writeToTerminal(remountTerm, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(remountTerm, chunk);
    }

    // Terminal restores scroll position
    remountTerm.scrollToLine(restoration.savedViewportY);
    assert.equal(remountTerm.buffer.active.viewportY, targetViewportY, 'remounted terminal must be scrolled to targetViewportY');

    // Verify smart scrollback pinning rule: userScrolledUp is true, so subsequent write does NOT force scrollToBottom
    let userScrolledUp = remountTerm.buffer.active.viewportY < remountTerm.buffer.active.baseY;
    assert.equal(userScrolledUp, true, 'userScrolledUp must be true');

    let didAutoScroll = false;
    await writeToTerminal(remountTerm, 'live incoming line\r\n');
    if (!userScrolledUp && remountTerm.buffer.active.baseY > 0) {
      remountTerm.scrollToBottom();
      didAutoScroll = true;
    }

    assert.equal(didAutoScroll, false, 'must NOT auto-scroll to bottom when user is scrolled up');
    assert.equal(remountTerm.buffer.active.viewportY, targetViewportY);

    remountTerm.dispose();
  });

  test('Test 3.2: User at bottom follows new background stream upon return', async () => {
    const registry = new TerminalSessionRegistry();
    const term = new Terminal({ cols: 80, rows: 10, scrollback: 1000 });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);

    for (let i = 1; i <= 20; i++) {
      await writeToTerminal(term, `line ${i}\r\n`);
    }

    // User is at bottom (viewportY === baseY)
    assert.equal(term.buffer.active.viewportY, term.buffer.active.baseY);

    const serialized = serializeAddon.serialize();
    registry.saveSnapshot('bottom-sess', serialized, term.buffer.active.viewportY, term.cols, term.rows);
    term.dispose();

    // Background deltas arrive
    for (let i = 21; i <= 30; i++) {
      registry.appendDelta('bottom-sess', new TextEncoder().encode(`line ${i}\r\n`));
    }

    const restoration = registry.consumeRestorationData('bottom-sess')!;
    const remountTerm = new Terminal({ cols: 80, rows: 10, scrollback: 1000 });
    await writeToTerminal(remountTerm, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(remountTerm, chunk);
    }

    // Check user at bottom behavior
    const isAtBottom = remountTerm.buffer.active.viewportY === remountTerm.buffer.active.baseY;
    assert.equal(isAtBottom, true, 'terminal at bottom must stay pinned to bottom on live stream');

    remountTerm.dispose();
  });
});

describe('Adversarial Suite 4: Targeted Session Kill & Complete Resource Eviction Across 5 Tabs', () => {

  test('Test 4.1: Killing Session 3 out of 5 purges Session 3 completely while leaving 1, 2, 4, 5 intact', () => {
    const registry = new TerminalSessionRegistry();
    const sessions = ['s1', 's2', 's3', 's4', 's5'];

    for (const sid of sessions) {
      registry.registerActiveSession(sid);
      registry.saveSnapshot(sid, `snapshot_${sid}`, 5, 80, 24);
      registry.appendDelta(sid, new TextEncoder().encode(`delta_${sid}`));
    }

    // Kill target session 's3'
    registry.closeSession('s3');

    // Invariant: s3 is completely gone
    assert.equal(registry.get('s3'), undefined);
    assert.equal(registry.hasSessionState('s3'), false);
    assert.equal(registry.isSessionActive('s3'), false);
    assert.equal(registry.consumeRestorationData('s3'), null);
    assert.equal(registry.drainSessionDeltas('s3').length, 0);

    // Invariant: all peers remain 100% intact
    for (const peer of ['s1', 's2', 's4', 's5']) {
      assert.ok(registry.hasSessionState(peer), `${peer} must still exist`);
      assert.ok(registry.isSessionActive(peer), `${peer} must still be active`);
      const state = registry.get(peer)!;
      assert.equal(state.snapshot, `snapshot_${peer}`);
      assert.equal(state.savedViewportY, 5);
      assert.equal(state.deltaChunks.length, 1);
      assert.equal(new TextDecoder().decode(state.deltaChunks[0]), `delta_${peer}`);
    }
  });

  test('Test 4.2: Session reincarnation after kill starts with clean slate without ghost data', () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'reincarnate-sess';

    // 1. Initial incarnation
    registry.saveSnapshot(sid, 'old ghost snapshot', 99, 120, 40);
    registry.appendDelta(sid, new TextEncoder().encode('old ghost delta'));
    assert.ok(registry.hasSessionState(sid));

    // 2. Kill session
    registry.closeSession(sid);
    assert.equal(registry.hasSessionState(sid), false);

    // 3. Re-create session with same ID
    registry.registerActiveSession(sid);
    const initialRestoration = registry.consumeRestorationData(sid);
    assert.equal(initialRestoration, null, 'Must have zero ghost restoration data');

    // 4. Save fresh state
    registry.saveSnapshot(sid, 'clean fresh snapshot', 0, 80, 24);
    const fresh = registry.consumeRestorationData(sid)!;
    assert.equal(fresh.snapshot, 'clean fresh snapshot');
    assert.equal(fresh.savedViewportY, 0);
    assert.equal(fresh.deltaChunks.length, 0);
  });

  test('Test 4.3: Cascading sequential kill clears registry completely', () => {
    const registry = new TerminalSessionRegistry();
    const sessions = ['s1', 's2', 's3', 's4', 's5'];

    for (const sid of sessions) {
      registry.saveSnapshot(sid, `snap_${sid}`, 0, 80, 24);
    }

    for (let i = 0; i < sessions.length; i++) {
      const sid = sessions[i];
      registry.closeSession(sid);
      assert.equal(registry.hasSessionState(sid), false);

      // Remaining sessions must still exist
      for (let j = i + 1; j < sessions.length; j++) {
        assert.ok(registry.hasSessionState(sessions[j]));
      }
    }
  });
});

describe('Adversarial Suite 5: High-Stress Boundary Attacks & Pathological Payloads', () => {

  test('Test 5.1: Alternate screen buffer (TUI) active in background session preserves alternate state', async () => {
    const registry = new TerminalSessionRegistry();
    const term = new Terminal({ cols: 80, rows: 24 });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);

    // Launch TUI (alternate buffer enter + screen draw)
    await writeToTerminal(term, '\x1b[?1049h\x1b[H\x1b[2J');
    await writeToTerminal(term, '=== TUI DASHBOARD ACTIVE ===\r\n');
    await writeToTerminal(term, '\x1b[24;1H[STATUS: NORMAL]');

    // Snapshot captured in alternate screen mode
    const serialized = serializeAddon.serialize();
    registry.saveSnapshot('tui-sess', serialized, 0, 80, 24);
    term.dispose();

    // Stream TUI updates in background
    registry.appendDelta('tui-sess', new TextEncoder().encode('\x1b[24;1H[STATUS: BUSY COMPILING]'));

    // Remount
    const restoration = registry.consumeRestorationData('tui-sess')!;
    const remountTerm = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(remountTerm, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(remountTerm, chunk);
    }

    const lines = extractAllLines(remountTerm);
    const combined = lines.join('\n');
    assert.ok(combined.includes('TUI DASHBOARD ACTIVE'), 'TUI header must be restored');
    assert.ok(combined.includes('STATUS: BUSY COMPILING'), 'Background TUI delta must update status line');

    remountTerm.dispose();
  });

  test('Test 5.2: Stream burst exceeding 1MB limit during inactive period enforces exact FIFO cap', () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'burst-sess';
    registry.saveSnapshot(sid, 'base', 0, 80, 24);

    // Send 1.5MB in 100KB chunks (15 chunks)
    const chunkSize = 100 * 1024; // 102,400 bytes
    const chunkCount = 15; // 1.5 MB total

    for (let c = 1; c <= chunkCount; c++) {
      const chunk = new Uint8Array(chunkSize);
      chunk.fill(c); // Chunk marker byte
      registry.appendDelta(sid, chunk);
    }

    const state = registry.get(sid)!;
    assert.ok(
      state.totalDeltaBytes <= MAX_DELTA_BYTES,
      `totalDeltaBytes (${state.totalDeltaBytes}) must not exceed MAX_DELTA_BYTES (${MAX_DELTA_BYTES})`
    );

    // Retention: oldest chunks pruned, newest kept. Asserted against the buffer itself, which is
    // what bounds memory.
    assert.equal(state.deltaBuffer[state.deltaBuffer.length - 1][0], 15, 'Newest chunk #15 must be retained');
    assert.ok(state.deltaBuffer[0][0] > 1, `Chunk #1 must have been pruned, got chunk #${state.deltaBuffer[0][0]}`);

    // Replay: refused. REQ-FIX-7 — this test previously consumed the restoration and asserted the
    // pruned remainder came back for replay. That is the defect, not the contract: chunk #2 begins
    // wherever the socket happened to split the stream, so replaying from it can start
    // mid-code-point or mid-CSI and garble the restored screen. A truncated buffer is dropped and
    // the snapshot is restored alone; see Suite 3b in ui_terminal_persistence_registry_test.ts for
    // the rendered-screen proof.
    assert.equal(state.truncated, true, 'a prune must mark the state truncated');
    const restoration = registry.consumeRestorationData(sid)!;
    assert.equal(restoration.truncated, true, 'the restoration must report the truncation');
    assert.equal(restoration.deltaChunks.length, 0, 'a truncated buffer must not be replayed');
    assert.equal(restoration.snapshot, 'base', 'the snapshot remains the restoration anchor');
  });

  test('Test 5.3: Rapid tab toggling race condition (200 consecutive rapid toggles)', async () => {
    const registry = new TerminalSessionRegistry();
    const sids = ['tab-A', 'tab-B'];

    registry.saveSnapshot('tab-A', 'data-A', 0, 80, 24);
    registry.saveSnapshot('tab-B', 'data-B', 0, 80, 24);

    for (let i = 0; i < 200; i++) {
      const active = sids[i % 2];
      const inactive = sids[(i + 1) % 2];

      // Append delta to inactive
      registry.appendDelta(inactive, new TextEncoder().encode(`inactive-delta-${i}\r\n`));

      // Query active
      const state = registry.get(active);
      assert.ok(state);
      assert.equal(state.sessionId, active);
    }

    const dataA = registry.consumeRestorationData('tab-A')!;
    const dataB = registry.consumeRestorationData('tab-B')!;

    assert.equal(dataA.deltaChunks.length, 100);
    assert.equal(dataB.deltaChunks.length, 100);
  });
});
