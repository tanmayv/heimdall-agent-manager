// REQ-SHELL-29: the agent pane must announce its REAL geometry before the SIGWINCH nudge.
//
// WHY THIS TEST IS ABOUT ORDER, NOT VALUES. The hub captures the late-join screen snapshot
// from the FIRST resize frame it sees. The REQ-STREAM-REDRAW-2 micro-nudge deliberately
// sends a WRONG width (cols - 1) and restores the real one 25ms later. If the nudge goes
// out first, the snapshot is captured one column narrow — the width is what the capture
// WRAPS AT, so a full-width line breaks early and every following line shifts, and a shell
// sitting at a prompt never writes anything to correct it.
//
// A test asserting merely that "a frame with cols" and "a frame with cols - 1" are both sent
// PASSES under the broken code, because both calls exist either way. Only their order
// distinguishes fixed from broken, so that is what is asserted here.
//
// RUN: node --test tests/ui_agent_stream_snapshot_geometry_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const USE_AGENT_STREAM = path.join(REPO_ROOT, 'src/ui/components/chat/useAgentStream.ts');
const USE_SHELL_STREAM = path.join(REPO_ROOT, 'src/ui/components/shells/useShellStream.ts');

test('useAgentStream sends unmodified cols BEFORE the cols - 1 nudge', () => {
  assert.ok(fs.existsSync(USE_AGENT_STREAM), 'useAgentStream.ts must exist');
  const src = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  const honest = src.indexOf('sendResize(targetRows, targetCols);');
  const nudge = src.indexOf('sendResize(targetRows, targetCols - 1);');

  assert.ok(honest >= 0, 'must send the real geometry (targetCols) on open');
  assert.ok(nudge >= 0, 'must still send the cols - 1 nudge (REQ-STREAM-REDRAW-2)');
  assert.ok(
    honest < nudge,
    'the REAL geometry must be sent BEFORE the cols - 1 nudge, or the hub captures the ' +
      'REQ-SHELL-29 snapshot one column narrow',
  );
});

test('useAgentStream still restores the real geometry after the nudge (REQ-STREAM-REDRAW-2 intact)', () => {
  const src = fs.readFileSync(USE_AGENT_STREAM, 'utf8');

  // The pty must still observe cols -> cols - 1 -> cols, so SIGWINCH is still delivered.
  const occurrences = src.split('sendResize(targetRows, targetCols);').length - 1;
  assert.equal(
    occurrences,
    2,
    'real geometry is sent twice: once up front for the snapshot, once to restore after the nudge',
  );
  assert.ok(src.includes('}, 25);'), 'the 25ms restore timer must be preserved');
});

// The shells hook has no nudge and already announces measured geometry on open, so it is
// NOT affected. Pinned so a future nudge added there does not silently reintroduce the bug.
test('useShellStream announces measured geometry on open and has no cols - 1 nudge', () => {
  assert.ok(fs.existsSync(USE_SHELL_STREAM), 'useShellStream.ts must exist');
  const src = fs.readFileSync(USE_SHELL_STREAM, 'utf8');

  assert.ok(src.includes('sendGeometry(socket);'), 'must send measured geometry on open');
  assert.ok(
    !src.includes('- 1)'),
    'a cols - 1 nudge here would capture the REQ-SHELL-29 snapshot at the wrong width too',
  );
});
