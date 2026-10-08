/**
 * Challenger M1 Independent Empirical Stress Test Suite
 * 
 * Verifies backend changes under adversarial conditions:
 * 1. Trailing row trimming invariants and edge cases
 * 2. ANSI VT100 compliance and headless terminal behavior
 * 3. Protocol backward compatibility with missing / legacy coordinates
 * 4. Fuzzing and high-scale performance
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

const SHELL_SCREEN_REPAINT_PREFIX = '\x1b[2J\x1b[H';

/**
 * Exact replica of Odin's _shell_screen_trim_trailing_blank_rows logic from
 * src/hub/transport/http/shell_stream_screen_snapshot.odin
 */
function odinTrimTrailingBlankRows(s: string): string {
  if (s.length === 0) return '';

  let last_non_blank_end = -1;
  let line_start = 0;
  let line_has_content = false;

  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\n') {
      if (line_has_content) {
        let end = i;
        if (end > line_start && s[end - 1] === '\r') end -= 1;
        last_non_blank_end = end;
      }
      line_start = i + 1;
      line_has_content = false;
    } else if (c !== ' ' && c !== '\t' && c !== '\r') {
      line_has_content = true;
    }
  }

  if (line_has_content) {
    let end = s.length;
    if (end > line_start && s[end - 1] === '\r') end -= 1;
    last_non_blank_end = end;
  }

  if (last_non_blank_end <= 0) return '';
  return s.substring(0, last_non_blank_end);
}

/**
 * Exact replica of Odin's _shell_screen_lf_to_crlf
 */
function odinLfToCrlf(s: string): string {
  let result = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\n' && (i === 0 || s[i - 1] !== '\r')) {
      result += '\r';
    }
    result += c;
  }
  return result;
}

/**
 * Exact replica of Odin's _shell_screen_repaint_text
 */
function odinRepaintText(paneOutput: string, cursorRow = -1, cursorCol = -1): string {
  const trimmed = odinTrimTrailingBlankRows(paneOutput);
  const body = odinLfToCrlf(trimmed);

  if (cursorRow >= 0 && cursorCol >= 0) {
    const cup = `\x1b[${cursorRow + 1};${cursorCol + 1}H`;
    return `${SHELL_SCREEN_REPAINT_PREFIX}${body}${cup}`;
  }
  return `${SHELL_SCREEN_REPAINT_PREFIX}${body}`;
}

function writeToTerminal(term: any, data: string): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

describe('Challenger M1 Stress Test Suite', () => {

  describe('Adversarial Invariant 1: Trailing Row Trimming & Space Preservation', () => {

    test('Prompt with trailing whitespace must preserve exact prompt space', () => {
      const prompt = 'user@hostname:~/projects$ ';
      const input = prompt + '\n' + '\n'.repeat(23);
      const trimmed = odinTrimTrailingBlankRows(input);
      assert.equal(trimmed, prompt);
      assert.equal(trimmed.endsWith(' '), true, 'trailing space must be preserved');
      assert.equal(trimmed.length, prompt.length);
    });

    test('Prompt with trailing tabs and spaces', () => {
      const prompt = 'admin# \t ';
      const input = prompt + '\n   \n\t\t\n   \t   ';
      const trimmed = odinTrimTrailingBlankRows(input);
      assert.equal(trimmed, prompt);
    });

    test('Interior blank and whitespace rows must be completely preserved', () => {
      const input = 'Header Line\n\n   \nMiddle Line\n\n\n\n';
      const trimmed = odinTrimTrailingBlankRows(input);
      assert.equal(trimmed, 'Header Line\n\n   \nMiddle Line');
    });

    test('Screen with only blank and whitespace rows must return empty string', () => {
      const testCases = [
        '',
        ' ',
        '\t',
        '\r',
        '\r\n',
        '\n\n\n',
        '   \n\t\t\n  \r\n   ',
        '\n'.repeat(100),
        '   \r\n   \r\n   ',
      ];
      for (const tc of testCases) {
        assert.equal(odinTrimTrailingBlankRows(tc), '', `Failed for ${JSON.stringify(tc)}`);
      }
    });

    test('CRLF line endings before trailing lines are handled cleanly without trailing CR', () => {
      const input = 'Line 1\r\nLine 2\r\n\r\n\r\n';
      const trimmed = odinTrimTrailingBlankRows(input);
      assert.equal(trimmed, 'Line 1\r\nLine 2');
      assert.equal(trimmed.endsWith('\r'), false);
    });

    test('Single character on first line without newline', () => {
      assert.equal(odinTrimTrailingBlankRows('x'), 'x');
    });

    test('Single character on first line with newline and blank rows', () => {
      assert.equal(odinTrimTrailingBlankRows('x\n\n\n'), 'x');
    });

    test('Unicode and multi-byte runes in prompt and lines are preserved', () => {
      const prompt = '🚀 ❯ [main] repo ⚡: ';
      const input = prompt + '\n\n\n';
      const trimmed = odinTrimTrailingBlankRows(input);
      assert.equal(trimmed, prompt);
    });

    test('Line containing ANSI escape sequences is preserved and counted as content', () => {
      const colored = '\x1b[32muser\x1b[0m@\x1b[34mhost\x1b[0m:~$ ';
      const input = colored + '\n\n\n';
      const trimmed = odinTrimTrailingBlankRows(input);
      assert.equal(trimmed, colored);
    });

    test('Fuzzing trimming invariant with 5,000 pseudo-random line combinations', () => {
      const chars = ['a', ' ', '\t', '\r', '\x1b', '1', '$'];
      for (let iter = 0; iter < 5000; iter++) {
        const numLines = Math.floor(Math.random() * 15) + 1;
        const lines: string[] = [];
        let hasAnyNonWhitespace = false;

        for (let l = 0; l < numLines; l++) {
          const len = Math.floor(Math.random() * 20);
          let line = '';
          for (let c = 0; c < len; c++) {
            line += chars[Math.floor(Math.random() * chars.length)];
          }
          if (line.replace(/[ \t\r]/g, '').length > 0) {
            hasAnyNonWhitespace = true;
          }
          lines.push(line);
        }

        const eol = Math.random() > 0.5 ? '\n' : '\r\n';
        const input = lines.join(eol);
        const result = odinTrimTrailingBlankRows(input);

        if (!hasAnyNonWhitespace) {
          assert.equal(result, '', `Expected empty string for non-content input on iter ${iter}`);
        } else {
          assert.ok(result.length > 0, `Expected non-empty result on iter ${iter}`);
          // Last character of result must not be bare LF or part of trailing blank row
          assert.ok(!result.endsWith('\n'), `Result should not end with newline on iter ${iter}`);
        }
      }
    });
  });

  describe('Adversarial Invariant 2: ANSI VT100 Repaint & Headless xterm Alignment', () => {

    test('Prompt at row 0, col 14: xterm cursor lands exactly at row 0, col 14', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const prompt = 'user@box:~/app$ ';
      const pane = prompt + '\n' + '\n'.repeat(23);
      const repaint = odinRepaintText(pane, 0, prompt.length);

      await writeToTerminal(term, repaint);

      assert.equal(term.buffer.active.cursorY, 0, 'cursorY must be 0 (top line)');
      assert.equal(term.buffer.active.cursorX, prompt.length, 'cursorX must be at prompt end');
      assert.equal(term.buffer.active.baseY, 0, 'baseY must be 0 (no viewport scroll)');
      term.dispose();
    });

    test('Multi-line output with prompt on row 3: cursor lands exactly at row 3, col 2', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const pane = 'Line 0: starting build\nLine 1: build succeeded\nLine 2:\n$ \n' + '\n'.repeat(20);
      const repaint = odinRepaintText(pane, 3, 2);

      await writeToTerminal(term, repaint);

      assert.equal(term.buffer.active.cursorY, 3, 'cursorY must be at row 3');
      assert.equal(term.buffer.active.cursorX, 2, 'cursorX must be after "$ "');
      assert.equal(term.buffer.active.baseY, 0);
      term.dispose();
    });

    test('Omitted coordinates (-1, -1): cursor naturally sits at prompt end without bottom drift', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const prompt = 'user@box:~$ ';
      const pane = prompt + '\n' + '\n'.repeat(23);
      const repaint = odinRepaintText(pane, -1, -1);

      await writeToTerminal(term, repaint);

      // Because trailing blank rows were trimmed, the text stops right after prompt!
      assert.equal(term.buffer.active.cursorY, 0, 'cursorY naturally stays at 0 without trailing CRLFs');
      assert.equal(term.buffer.active.cursorX, prompt.length, 'cursorX naturally stays at prompt length');
      assert.equal(term.buffer.active.baseY, 0);
      term.dispose();
    });

    test('Repaint on non-standard terminal dimensions (120x40 and 40x12)', async () => {
      const sizes = [
        { cols: 120, rows: 40, cursorRow: 5, cursorCol: 30 },
        { cols: 40, rows: 12, cursorRow: 1, cursorCol: 10 },
      ];

      for (const s of sizes) {
        const term = new Terminal({ cols: s.cols, rows: s.rows });
        const pane = Array.from({ length: s.cursorRow + 1 }, (_, i) => `Row ${i} output`).join('\n') + '\n'.repeat(s.rows);
        const repaint = odinRepaintText(pane, s.cursorRow, s.cursorCol);

        await writeToTerminal(term, repaint);

        assert.equal(term.buffer.active.cursorY, s.cursorRow, `cursorY on ${s.cols}x${s.rows}`);
        assert.equal(term.buffer.active.cursorX, s.cursorCol, `cursorX on ${s.cols}x${s.rows}`);
        assert.equal(term.buffer.active.baseY, 0);
        term.dispose();
      }
    });

    test('Full-width row (exactly 80 characters) does not produce unwanted wrap or blank row', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const fullWidthLine = 'X'.repeat(80);
      const pane = fullWidthLine + '\n' + '\n'.repeat(23);
      const repaint = odinRepaintText(pane, 0, 79);

      await writeToTerminal(term, repaint);

      // Terminal should not have wrapped to row 1 before CUP positions cursor
      assert.equal(term.buffer.active.cursorY, 0);
      assert.equal(term.buffer.active.cursorX, 79);
      term.dispose();
    });

    test('Absolute repaint clears previous terminal state without lingering ghost lines', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      // Dirty the terminal with 20 rows of junk
      await writeToTerminal(term, 'Junk text\r\n'.repeat(20));
      assert.ok(term.buffer.active.cursorY > 0);

      // Repaint with a single prompt
      const prompt = 'clean@box:~$ ';
      const repaint = odinRepaintText(prompt + '\n'.repeat(23), 0, prompt.length);
      await writeToTerminal(term, repaint);

      assert.equal(term.buffer.active.cursorY, 0, 'cursor must be on row 0');
      assert.equal(term.buffer.active.cursorX, prompt.length);
      const line0 = term.buffer.active.getLine(0)?.translateToString(true);
      assert.equal(line0, prompt);
      const line1 = term.buffer.active.getLine(1)?.translateToString(true);
      assert.equal(line1, '', 'subsequent lines must be erased by repaint');
      term.dispose();
    });
  });

  describe('Adversarial Invariant 3: Protocol Backward Compatibility & Wire Framing', () => {

    test('JSON serialization with coordinates present', () => {
      const frame = {
        type: 'screen',
        screen_b64: Buffer.from('hello').toString('base64'),
        cursor_row: 0,
        cursor_col: 10,
      };
      const jsonStr = JSON.stringify(frame);
      const parsed = JSON.parse(jsonStr);
      assert.equal(parsed.type, 'screen');
      assert.equal(parsed.cursor_row, 0);
      assert.equal(parsed.cursor_col, 10);
    });

    test('Legacy client/bridge frame omitting cursor coordinates parses cleanly', () => {
      const legacyJson = '{"type":"screen","screen_b64":"aGVsbG8="}';
      const parsed = JSON.parse(legacyJson);
      assert.equal(parsed.type, 'screen');
      assert.equal(parsed.cursor_row, undefined);
      assert.equal(parsed.cursor_col, undefined);
      assert.equal(Buffer.from(parsed.screen_b64, 'base64').toString('utf8'), 'hello');
    });

    test('Client with fallback defaults when cursor coordinates omitted', () => {
      const legacyFrame: any = { type: 'screen', screen_b64: 'QUJD' };
      const cursorRow = legacyFrame.cursor_row ?? -1;
      const cursorCol = legacyFrame.cursor_col ?? -1;
      assert.equal(cursorRow, -1);
      assert.equal(cursorCol, -1);
    });
  });

  describe('Adversarial Invariant 4: Large Scale & Performance Bounds', () => {

    test('Screen with 10,000 trailing blank rows trims within 20 milliseconds', () => {
      const start = performance.now();
      const largeInput = 'user@box:~$ \n' + '\n'.repeat(10000);
      const trimmed = odinTrimTrailingBlankRows(largeInput);
      const elapsed = performance.now() - start;

      assert.equal(trimmed, 'user@box:~$ ');
      assert.ok(elapsed < 20, `Trimming took ${elapsed.toFixed(2)}ms, expected < 20ms`);
    });

    test('Screen with 2,000 filled rows (100KB+) trims and formats CRLF efficiently', () => {
      const start = performance.now();
      const lines = Array.from({ length: 2000 }, (_, i) => `log line ${i + 1} with some realistic diagnostic content`);
      lines.push(...Array(100).fill(''));
      const input = lines.join('\n');
      const repaint = odinRepaintText(input, 1999, 10);
      const elapsed = performance.now() - start;

      assert.ok(repaint.startsWith(SHELL_SCREEN_REPAINT_PREFIX));
      assert.ok(repaint.endsWith('\x1b[2000;11H'));
      assert.ok(elapsed < 50, `Formatting took ${elapsed.toFixed(2)}ms, expected < 50ms`);
    });
  });
});
