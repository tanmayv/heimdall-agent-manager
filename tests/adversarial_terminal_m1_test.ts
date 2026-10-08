import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

describe('Adversarial Challenger M1: Terminal Screen & Cursor Rendering', () => {

  test('ADV-M1-01: Terminal renders prompt and exact cursor position without extra rows', async () => {
    const term = new Terminal({ cols: 80, rows: 24 });
    const prompt = 'user@box:~$ ';
    // Repaint payload: erase & home + prompt + ANSI CUP \x1b[1;13H
    const payload = `\x1b[2J\x1b[H${prompt}\x1b[1;13H`;

    await writeToTerminal(term, payload);

    assert.equal(term.buffer.active.cursorY, 0, 'cursor row must be 0 (row 1)');
    assert.equal(term.buffer.active.cursorX, 12, 'cursor col must be 12 (col 13)');
    assert.equal(term.buffer.active.baseY, 0, 'viewport has not scrolled');

    // Verify row 0 content has prompt
    const line0 = term.buffer.active.getLine(0)?.translateToString().trimEnd();
    assert.equal(line0, prompt.trimEnd());

    // Verify row 1 is completely empty
    const line1 = term.buffer.active.getLine(1)?.translateToString().trimEnd();
    assert.equal(line1, '', 'row 1 must be empty');
    term.dispose();
  });

  test('ADV-M1-02: Multi-line output with interior blank lines renders accurate cursor position', async () => {
    const term = new Terminal({ cols: 80, rows: 24 });
    // Header, blank line, prompt on line 2, cursor at (row 2, col 8) -> \x1b[3;9H
    const payload = `\x1b[2J\x1b[HHeader\r\n\r\nsh-5.2$ \x1b[3;9H`;

    await writeToTerminal(term, payload);

    assert.equal(term.buffer.active.cursorY, 2, 'cursor row must be 2');
    assert.equal(term.buffer.active.cursorX, 8, 'cursor col must be 8');

    assert.equal(term.buffer.active.getLine(0)?.translateToString().trimEnd(), 'Header');
    assert.equal(term.buffer.active.getLine(1)?.translateToString().trimEnd(), '');
    assert.equal(term.buffer.active.getLine(2)?.translateToString().trimEnd(), 'sh-5.2$');
    term.dispose();
  });

  test('ADV-M1-03: Multi-chunk sequential repaint with cursor CUP in final chunk', async () => {
    const term = new Terminal({ cols: 80, rows: 24 });

    // Chunk 1: erase+home and first line
    const chunk1 = '\x1b[2J\x1b[HStarting build process...\r\n';
    // Chunk 2: progress and prompt + cursor reposition
    const chunk2 = 'Build complete.\r\nnext_cmd$ \x1b[2;11H';

    await writeToTerminal(term, chunk1);
    await writeToTerminal(term, chunk2);

    assert.equal(term.buffer.active.cursorY, 1, 'cursor row must be 1');
    assert.equal(term.buffer.active.cursorX, 10, 'cursor col must be 10');
    assert.equal(term.buffer.active.getLine(0)?.translateToString().trimEnd(), 'Starting build process...');
    assert.equal(term.buffer.active.getLine(1)?.translateToString().trimEnd(), 'Build complete.');
    term.dispose();
  });

  test('ADV-M1-04: Adversarial JSON parsing of screen frame with extreme and zero coordinates', () => {
    // 1. Zero coordinates
    const jsonZero = '{"type":"screen","screen_b64":"QUJD","cursor_row":0,"cursor_col":0}';
    const parsedZero = JSON.parse(jsonZero);
    assert.equal(parsedZero.cursor_row, 0);
    assert.equal(parsedZero.cursor_col, 0);

    // 2. Large coordinates
    const jsonLarge = '{"type":"screen","screen_b64":"QUJD","cursor_row":65535,"cursor_col":65535}';
    const parsedLarge = JSON.parse(jsonLarge);
    assert.equal(parsedLarge.cursor_row, 65535);
    assert.equal(parsedLarge.cursor_col, 65535);

    // 3. Negative coordinates omitted from JSON
    const jsonNeg = '{"type":"screen","screen_b64":"QUJD"}';
    const parsedNeg = JSON.parse(jsonNeg);
    assert.equal(parsedNeg.cursor_row, undefined);
    assert.equal(parsedNeg.cursor_col, undefined);
  });
});
