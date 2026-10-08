import test, { describe } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

describe('Challenger M2 Empirical Stress Suite', () => {

  // --------------------------------------------------------------------------
  // 1. Initial Cursor Placement & Zero-Scrollback Suppression
  // --------------------------------------------------------------------------
  describe('Challenge 1: Smart Scrollback Pinning & BaseY Suppression', () => {

    test('Single-line prompt maintains baseY === 0 and suppresses scrollToBottom', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalls = 0;
      const fakeScrollToBottom = () => { scrollToBottomCalls++; };

      const prompt = 'tanmay@box:~/heimdall$ ';
      await writeToTerminal(term, prompt);

      const buffer = term.buffer.active;
      assert.equal(buffer.baseY, 0, 'baseY must be 0 for single line prompt');
      assert.equal(buffer.cursorY, 0, 'cursor row must remain at prompt line');
      assert.equal(buffer.cursorX, prompt.length, 'cursor column must sit immediately after prompt text');

      // ShellTerminalPane logic check
      const userScrolledUp = false;
      if (!userScrolledUp && buffer.baseY > 0) {
        fakeScrollToBottom();
      }
      assert.equal(scrollToBottomCalls, 0, 'scrollToBottom must NOT be called when baseY === 0');
      term.dispose();
    });

    test('Multi-line Starship/Zsh prompt fits in viewport, maintaining baseY === 0', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalls = 0;
      const fakeScrollToBottom = () => { scrollToBottomCalls++; };

      // 3-line complex prompt
      const prompt = '[12:00:00] user in ~/heimdall\r\n(main via ⬢ v20.0.0)\r\n❯ ';
      await writeToTerminal(term, prompt);

      const buffer = term.buffer.active;
      assert.equal(buffer.baseY, 0, 'baseY must be 0 for multi-line prompt that fits in viewport');
      assert.equal(buffer.cursorY, 2, 'cursor row must be at 3rd line (0-indexed 2)');
      assert.equal(buffer.cursorX, 2, 'cursor col must sit right after prompt symbol');

      const userScrolledUp = false;
      if (!userScrolledUp && buffer.baseY > 0) {
        fakeScrollToBottom();
      }
      assert.equal(scrollToBottomCalls, 0, 'scrollToBottom must NOT be called when baseY === 0');
      term.dispose();
    });

    test('MOTD / Neofetch burst filling 23 of 24 lines maintains baseY === 0', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalls = 0;
      const fakeScrollToBottom = () => { scrollToBottomCalls++; };

      const lines = Array.from({ length: 23 }, (_, i) => `system banner info line ${i + 1}`).join('\r\n');
      await writeToTerminal(term, lines);

      const buffer = term.buffer.active;
      assert.equal(buffer.baseY, 0, 'baseY must be 0 for 23 lines in a 24-row terminal');
      assert.equal(buffer.cursorY, 22, 'cursor row must be at line 23 (index 22)');

      const userScrolledUp = false;
      if (!userScrolledUp && buffer.baseY > 0) {
        fakeScrollToBottom();
      }
      assert.equal(scrollToBottomCalls, 0, 'scrollToBottom must NOT be called');
      term.dispose();
    });

    test('Exact boundary test: 24 lines without trailing CRLF vs with trailing CRLF', async () => {
      // Case A: 24 lines exactly without trailing CRLF
      const termA = new Terminal({ cols: 80, rows: 24 });
      const lines24NoTrailing = Array.from({ length: 24 }, (_, i) => `line ${i + 1}`).join('\r\n');
      await writeToTerminal(termA, lines24NoTrailing);
      assert.equal(termA.buffer.active.baseY, 0, '24 lines without trailing newline must fit with baseY === 0');
      assert.equal(termA.buffer.active.cursorY, 23, 'cursor on last row');
      termA.dispose();

      // Case B: 24 lines with trailing CRLF pushes into scrollback (baseY = 1)
      const termB = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalls = 0;
      const lines24WithTrailing = lines24NoTrailing + '\r\n';
      await writeToTerminal(termB, lines24WithTrailing);
      assert.equal(termB.buffer.active.baseY, 1, 'trailing CRLF on 24th line must increment baseY to 1');

      const userScrolledUp = false;
      if (!userScrolledUp && termB.buffer.active.baseY > 0) {
        scrollToBottomCalls++;
      }
      assert.equal(scrollToBottomCalls, 1, 'scrollToBottom must trigger when buffer.baseY > 0');
      termB.dispose();
    });

    test('Stress test: massive 1,000 line burst with chunk slicing and scrollback pinning', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalls = 0;
      let userScrolledUp = false;

      // Simulate onOutput write callback
      const writeWithPinning = (chunk: string): Promise<void> => {
        return new Promise((resolve) => {
          term.write(chunk, () => {
            const buffer = term.buffer.active;
            if (!userScrolledUp && buffer.baseY > 0) {
              scrollToBottomCalls++;
              term.scrollToBottom();
            }
            resolve();
          });
        });
      };

      // Emit 1000 lines in 50 chunks of 20 lines each
      for (let i = 0; i < 50; i++) {
        const chunk = Array.from({ length: 20 }, (_, j) => `bulk log ${i * 20 + j + 1}\r\n`).join('');
        await writeWithPinning(chunk);
      }

      const buffer = term.buffer.active;
      // 1000 lines ending in \r\n creates 1001 lines (cursor on new empty line 1001)
      assert.equal(buffer.baseY, 1001 - 24, 'baseY must equal total lines (including trailing cursor line) minus viewport rows');
      assert.ok(scrollToBottomCalls >= 49, 'scrollToBottom should trigger for all overflow chunks');
      assert.equal(buffer.viewportY, buffer.baseY, 'viewportY must remain anchored to baseY');

      // Now simulate user scrolling up
      userScrolledUp = true;
      const preScrollCalls = scrollToBottomCalls;
      await writeWithPinning('another line while user scrolled up\r\n');
      assert.equal(scrollToBottomCalls, preScrollCalls, 'scrollToBottom must NOT trigger when userScrolledUp is true');

      // User scrolls back down to bottom
      userScrolledUp = false;
      await writeWithPinning('line after user returned to bottom\r\n');
      assert.equal(scrollToBottomCalls, preScrollCalls + 1, 'scrollToBottom resumes when user returns to bottom');

      term.dispose();
    });
  });

  // --------------------------------------------------------------------------
  // 2. convertEol Decoupling & Timing Transitions
  // --------------------------------------------------------------------------
  describe('Challenge 2: convertEol Decoupling & Timing Transitions', () => {

    test('convertEol: false preserves cursor column on bare \\n (VT100 streaming standard)', async () => {
      const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
      // Write 10 characters, then bare \n
      await writeToTerminal(term, '1234567890\n');

      // On VT100 without convertEol, cursor moves down 1 row but stays at col 10
      assert.equal(term.buffer.active.cursorY, 1, 'cursor must advance to next row');
      assert.equal(term.buffer.active.cursorX, 10, 'cursor column must remain at 10 on bare \\n when convertEol is false');

      // Contrast with CRLF: \r\n
      await writeToTerminal(term, '\r\n');
      assert.equal(term.buffer.active.cursorX, 0, 'cursor column must reset to 0 on explicit \\r');
      term.dispose();
    });

    test('convertEol: true forces cursor column to 0 on bare \\n (legacy polling mode)', async () => {
      const term = new Terminal({ cols: 80, rows: 24, convertEol: true });
      await writeToTerminal(term, '1234567890\n');

      assert.equal(term.buffer.active.cursorY, 1, 'cursor must advance to next row');
      assert.equal(term.buffer.active.cursorX, 0, 'cursor column must reset to 0 on bare \\n when convertEol is true');
      term.dispose();
    });

    test('Simulated lifecycle: Mount -> Streaming -> Fallback -> Polling Repaint -> Reconnect', async () => {
      let isStreamingExperimentEnabled = true;
      let streamConnected = false;
      let fallbackToPolling = false;

      // Mount: isStreamingActive is computed WITHOUT streamConnected
      const computeStreamingActive = () => isStreamingExperimentEnabled && !fallbackToPolling;

      let isStreamingActive = computeStreamingActive();
      assert.equal(isStreamingActive, true, 'isStreamingActive must be true on mount even if streamConnected is false');

      // Terminal instantiated with convertEol: !isStreamingActive
      const term = new Terminal({ cols: 80, rows: 24, convertEol: !isStreamingActive });
      assert.equal(term.options.convertEol, false, 'convertEol must be false at initial mount');

      // Step 1: WebSocket connection establishes
      streamConnected = true;
      isStreamingActive = computeStreamingActive();
      term.options.convertEol = !isStreamingActive;
      assert.equal(term.options.convertEol, false, 'convertEol remains false when streamConnected becomes true');

      // Step 2: Stream error occurs -> triggers fallbackToPolling
      streamConnected = false;
      fallbackToPolling = true;
      isStreamingActive = computeStreamingActive();
      assert.equal(isStreamingActive, false, 'isStreamingActive becomes false upon fallback');
      term.options.convertEol = !isStreamingActive;
      assert.equal(term.options.convertEol, true, 'convertEol switches to true for polling repaints');

      // Step 3: Polling repaint arrives with bare \n snapshots
      term.reset();
      await writeToTerminal(term, 'polled line 1\npolled line 2');
      assert.equal(term.buffer.active.cursorX, 13, 'polled line 2 cursor col matches text length because col was reset to 0');

      // Step 4: User clicks retry -> triggers handleRetry
      fallbackToPolling = false;
      isStreamingActive = computeStreamingActive();
      assert.equal(isStreamingActive, true, 'isStreamingActive returns to true on retry');
      term.options.convertEol = !isStreamingActive;
      assert.equal(term.options.convertEol, false, 'convertEol returns to false for streaming');

      term.dispose();
    });

    test('Flapping streamConnected does NOT cause race condition in convertEol', () => {
      const isStreamingExperimentEnabled = true;
      let fallbackToPolling = false;
      let streamConnected = false;

      const term = new Terminal({ cols: 80, rows: 24, convertEol: !(isStreamingExperimentEnabled && !fallbackToPolling) });

      // Simulate connection flapping 50 times
      for (let i = 0; i < 50; i++) {
        streamConnected = !streamConnected;
        // The decoupled rule:
        const isStreamingActive = isStreamingExperimentEnabled && !fallbackToPolling;
        term.options.convertEol = !isStreamingActive;
        assert.equal(term.options.convertEol, false, `convertEol must remain strictly false during flapping (iteration ${i})`);
      }

      term.dispose();
    });
  });

  // --------------------------------------------------------------------------
  // 3. Geometry-First Write Sizing Gate & Flush Ordering
  // --------------------------------------------------------------------------
  describe('Challenge 3: Geometry-First Sizing Gate & Flush Ordering', () => {

    test('Buffered chunks remain unflushed while container is unmeasured, flush in exact FIFO order', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let isSized = false;
      const pendingStreamOutput: Uint8Array[] = [];
      const writtenChunks: string[] = [];

      const encoder = new TextEncoder();
      const decoder = new TextDecoder();

      const onOutput = (bytes: Uint8Array) => {
        if (!isSized) {
          pendingStreamOutput.push(bytes);
          return;
        }
        writtenChunks.push(decoder.decode(bytes));
        term.write(bytes);
      };

      // 5 chunks arrive before layout
      const rawMessages = [
        'chunk-1\r\n',
        'chunk-2\r\n',
        'chunk-3\r\n',
        'chunk-4\r\n',
        'chunk-5\r\n',
      ];
      for (const msg of rawMessages) {
        onOutput(encoder.encode(msg));
      }

      assert.equal(isSized, false);
      assert.equal(pendingStreamOutput.length, 5, 'all 5 chunks must be buffered');
      assert.equal(writtenChunks.length, 0, 'zero chunks written to terminal before layout');

      // Now layout completes: flushPendingOutput
      isSized = true;
      const flushPendingOutput = async () => {
        if (pendingStreamOutput.length > 0) {
          const queued = [...pendingStreamOutput];
          pendingStreamOutput.length = 0;
          for (const chunk of queued) {
            writtenChunks.push(decoder.decode(chunk));
            await writeToTerminal(term, chunk);
          }
        }
      };

      await flushPendingOutput();

      assert.equal(pendingStreamOutput.length, 0, 'queue must be drained');
      assert.deepEqual(writtenChunks, rawMessages, 'chunks must flush in strict FIFO order');
      assert.equal(term.buffer.active.cursorY, 5, 'cursor must sit on row 5 after 5 lines');

      // A 6th chunk arrives while isSized is true
      onOutput(encoder.encode('chunk-6\r\n'));
      assert.equal(writtenChunks.length, 6, 'chunk 6 must write immediately');
      assert.equal(writtenChunks[5], 'chunk-6\r\n');

      term.dispose();
    });

    test('getGeometry returns null when container is 0x0, preventing premature 80x24 announcement', () => {
      let isSized = false;
      const container = { clientWidth: 0, clientHeight: 0 };
      const term = { rows: 24, cols: 80 };

      const getGeometry = () => {
        if (!isSized && (!container || container.clientWidth === 0 || container.clientHeight === 0)) {
          return null;
        }
        return { rows: Math.max(term.rows, 1), cols: Math.max(term.cols, 40) };
      };

      assert.equal(getGeometry(), null, 'must return null when unmeasured');

      // Resize container
      container.clientWidth = 1200;
      container.clientHeight = 800;
      isSized = true;

      const geom = getGeometry();
      assert.notEqual(geom, null);
      assert.equal(geom?.rows, 24);
      assert.equal(geom?.cols, 80);
    });

    test('TUI Alternate Screen Buffer (\x1b[?1049h) maintains baseY === 0 throughout execution', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalls = 0;

      // Enter alternate screen buffer (like Neovim / Vim / Nano / Htop)
      await writeToTerminal(term, '\x1b[?1049h');
      assert.equal(term.buffer.active.type, 'alternate', 'active buffer must be alternate buffer');
      assert.equal(term.buffer.active.baseY, 0, 'alternate screen buffer baseY is strictly 0');

      // Paint 24 lines in alternate buffer with cursor moves
      for (let r = 1; r <= 24; r++) {
        await writeToTerminal(term, `\x1b[${r};1HLine ${r} in full-screen editor`);
      }

      assert.equal(term.buffer.active.baseY, 0, 'baseY must stay 0 in alternate buffer even when full');
      const userScrolledUp = false;
      if (!userScrolledUp && term.buffer.active.baseY > 0) {
        scrollToBottomCalls++;
      }
      assert.equal(scrollToBottomCalls, 0, 'scrollToBottom is never called in alternate buffer (no scrollback)');

      // Exit alternate screen buffer
      await writeToTerminal(term, '\x1b[?1049l');
      assert.equal(term.buffer.active.type, 'normal', 'returned to normal buffer');
      assert.equal(term.buffer.active.baseY, 0, 'normal buffer baseY is 0');
      term.dispose();
    });
  });
});

