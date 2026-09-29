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

test('ShellTerminalPane.tsx disables convertEol in streaming mode, enforces >=80 column floor, and allows horizontal scroll', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE), 'ShellTerminalPane.tsx must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  // 1. convertEol is disabled during active streaming
  assert.ok(src.includes('convertEol: !isStreamingActive'), 'must initialize Terminal with convertEol: !isStreamingActive');
  assert.ok(
    src.includes('terminalRef.current.options.convertEol = !isStreamingActive'),
    'must synchronize convertEol with streaming status'
  );

  // 2. Minimum column floor (>=80 cols) and row floor (>=24 rows) enforced in resize handlers
  assert.ok(src.includes('const effectiveCols = Math.max(cols, 80);'), 'handleResize must enforce minimum 80 cols');
  assert.ok(src.includes('const effectiveRows = Math.max(rows, 24);'), 'handleResize must enforce minimum 24 rows');
  assert.ok(
    src.includes('term.resize(Math.max(term.cols, 80), Math.max(term.rows, 24))'),
    'dispatchResize and observers must enforce >=80 cols and >=24 rows'
  );

  // 3. Terminal container styling enables horizontal scrolling
  assert.ok(
    src.includes('overflow-x-auto'),
    'terminal container must include overflow-x-auto for narrow viewports'
  );
  assert.ok(
    src.includes('chat-scrollbar') && src.includes('overflow-x-auto'),
    'terminal container must include chat-scrollbar and overflow-x-auto'
  );
});


// ===========================================================================
// REQ-SHELL-18 — session bleed on switch, and geometry never reaching the PTY.
//
// WHAT IS EXECUTED HERE vs WHAT IS NOT, stated plainly because the split matters:
//
//   EXECUTED: shellResizeFrame's truth table. It is a pure function with no
//   imports precisely so the "is this geometry worth sending, and what goes on
//   the wire" decision is checkable without a browser.
//
//   STATIC: the `key` on the three call sites, and the send-on-open wiring.
//   Both are React reconciliation and WebSocket lifecycle behaviour; observing
//   them for real needs a live PTY, and the hub forbids an agent from creating
//   an interactive `shell` session at all. These assertions cannot prove the
//   bleed is gone — only that the mechanism that causes it is not back.
// ===========================================================================

import { shellResizeFrame } from '../src/ui/components/shells/shellStreamFrames.ts';

const BOTTOM_DOCK = path.join(REPO_ROOT, 'src/ui/components/shell/BottomDock.tsx');
const SHELLS_PANEL = path.join(REPO_ROOT, 'src/ui/components/shells/ShellsPanel.tsx');
const SHELL_DETAIL = path.join(REPO_ROOT, 'src/ui/components/shells/ShellDetail.tsx');

test('REQ-SHELL-18: shellResizeFrame sends real geometry and refuses the rest', () => {
  // The frame that had been going missing on create.
  assert.equal(
    shellResizeFrame({ rows: 24, cols: 200 }),
    '{"type":"resize","rows":24,"cols":200}',
    'a real geometry must produce a resize frame with rows and cols'
  );

  // Nothing to send: no terminal mounted yet.
  assert.equal(shellResizeFrame(null), null, 'null geometry must not produce a frame');
  assert.equal(shellResizeFrame(undefined), null, 'undefined geometry must not produce a frame');

  // A PTY told it is 0 columns wide is WORSE off than one left at its default,
  // and 0 is exactly what an unmeasured xterm renderer reports on a cold mount.
  assert.equal(shellResizeFrame({ rows: 0, cols: 200 }), null, '0 rows must not produce a frame');
  assert.equal(shellResizeFrame({ rows: 24, cols: 0 }), null, '0 cols must not produce a frame');
  assert.equal(shellResizeFrame({ rows: -1, cols: 80 }), null, 'negative rows must not produce a frame');
  assert.equal(shellResizeFrame({ rows: 24, cols: -1 }), null, 'negative cols must not produce a frame');
  assert.equal(shellResizeFrame({ rows: NaN, cols: 80 }), null, 'NaN rows must not produce a frame');
  assert.equal(
    shellResizeFrame({ rows: 24, cols: Infinity }),
    null,
    'non-finite cols must not produce a frame'
  );
});

test('REQ-SHELL-18: useShellStream pushes geometry when the socket opens, not from an effect', () => {
  const src = fs.readFileSync(USE_SHELL_STREAM, 'utf8');

  assert.ok(src.includes('getGeometry?: () => { rows: number; cols: number } | null'),
    'useShellStream must accept a getGeometry pull so it can read geometry at open time');
  assert.ok(src.includes('const sendGeometry = (socket: WebSocket)'),
    'useShellStream must have a sendGeometry helper taking the socket directly');
  assert.ok(src.includes('shellResizeFrame(getGeometryRef.current?.())'),
    'sendGeometry must build its frame from the pulled geometry via shellResizeFrame');

  // The load-bearing bit: the call sits INSIDE socket.onopen. An effect keyed on
  // `connected` would be a React round-trip late, and would not fire at all for a
  // backoff reconnect that leaves `connected` true throughout.
  const onOpen = src.slice(src.indexOf('socket.onopen = () => {'));
  const onOpenBody = onOpen.slice(0, onOpen.indexOf('socket.onmessage'));
  assert.ok(onOpenBody.includes('sendGeometry(socket)'),
    'sendGeometry(socket) must be called from inside socket.onopen');

  // The drop that caused the bug must still be the documented behaviour of sendResize,
  // so nobody "fixes" it into a silent queue and hides the next instance of this.
  assert.ok(src.includes('if (!s || s.readyState !== WebSocket.OPEN) return;'),
    'sendResize must still refuse a non-OPEN socket rather than queueing');
});

test('REQ-SHELL-18: every ShellTerminalPane call site is keyed by session id', () => {
  // A pane reused across a session change keeps the previous session's scrollback:
  // the Terminal is built in a mount effect with an empty dependency array.
  const sites: Array<[string, string, string]> = [
    [BOTTOM_DOCK, 'key={activeSession.session_id}', 'BottomDock.tsx (the bottom bar the user reported)'],
    [SHELLS_PANEL, 'key={activePaneSession.session_id}', 'ShellsPanel.tsx'],
    [SHELL_DETAIL, 'key={record.session_id}', 'ShellDetail.tsx (unkeyed ShellDetailPane swaps record)'],
  ];

  // Per-CALL-SITE, not per-file. A second <ShellTerminalPane> added to a file that already
  // keys its first one would leave `src.includes(expectedKey)` true, the enumeration below
  // unchanged, and the suite green while the bleed is back — a silent path to a regression of
  // the exact bug this test exists to catch. So every opening tag is checked on its own.
  const openingTags = (src: string): string[] => {
    const tags: string[] = [];
    let i = src.indexOf('<ShellTerminalPane');
    while (i !== -1) {
      let depth = 0;
      let end = i;
      while (end < src.length) {
        const ch = src[end];
        if (ch === '{') depth += 1;
        else if (ch === '}') depth -= 1;
        else if (ch === '>' && depth === 0) break;
        end += 1;
      }
      tags.push(src.slice(i, end + 1));
      i = src.indexOf('<ShellTerminalPane', end);
    }
    return tags;
  };

  for (const [file, expectedKey, label] of sites) {
    const src = fs.readFileSync(file, 'utf8');
    const tags = openingTags(src);
    assert.ok(tags.length > 0, `${label} must render ShellTerminalPane`);
    assert.ok(src.includes(expectedKey), `${label} must key ShellTerminalPane with ${expectedKey}`);
    tags.forEach((tag, n) => {
      assert.match(
        tag,
        /\skey=\{/,
        `${label}: <ShellTerminalPane> occurrence #${n + 1} has no key= of its own. Every call `
          + 'site needs its own key={...session_id}; a sibling having one does not cover it.'
      );
    });
  }

  // Guard against a FOURTH call site appearing without a key. Counted across the
  // whole UI tree so this fails on the new file, not silently after it ships.
  //
  // KNOWN LIMITS OF THIS ENUMERATION, analysed and deliberately NOT closed — recorded so the
  // next reader inherits the decision instead of re-deriving it (REQ-SHELL-18 review):
  //   - An ALIASED import (`import { ShellTerminalPane as Pane }`) would render as `<Pane` and
  //     not be seen. Nothing in this tree aliases it and the repo has no such idiom.
  //   - The walk covers src/ui only. Complete today: `find src -name '*.tsx' -not -path 'src/ui/*'`
  //     returns nothing, so every .tsx in the repo is already inside the walk.
  //   - A call built with React.createElement rather than JSX would not be seen. The tree is
  //     uniformly JSX.
  // Each costs more than it buys today. If one of the three premises above stops holding, the
  // corresponding limit becomes real and this test should be tightened then.
  const uiRoot = path.join(REPO_ROOT, 'src/ui');
  const walk = (dir: string, out: string[] = []): string[] => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full, out);
      else if (entry.name.endsWith('.tsx')) out.push(full);
    }
    return out;
  };
  const callSites = walk(uiRoot).filter((f) => {
    // The component's own file is not a call site: its doc comment shows the keyed
    // usage callers are required to copy, so it matches the same substring.
    if (path.resolve(f) === path.resolve(SHELL_TERMINAL_PANE)) return false;
    const src = fs.readFileSync(f, 'utf8');
    return src.includes('<ShellTerminalPane');
  });
  assert.deepEqual(
    callSites.map((f) => path.relative(REPO_ROOT, f)).sort(),
    [
      'src/ui/components/shell/BottomDock.tsx',
      'src/ui/components/shells/ShellDetail.tsx',
      'src/ui/components/shells/ShellsPanel.tsx',
    ],
    'a new ShellTerminalPane call site must be added to this test AND keyed by session id'
  );
});

test('REQ-SHELL-18: the 80x24 floors are kept deliberately, with the reason recorded', () => {
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  // AC4: kept, not removed. The floors pair with overflow-x-auto to keep 80 usable
  // columns on a narrow pane instead of reflowing a TUI into unreadability.
  assert.ok(src.includes('DELIBERATE MINIMUM'),
    'the floors must be justified in a comment as a deliberate minimum, not left bare');
  // And the reason they are NOT the cause of the width symptom, so it is not re-derived.
  assert.ok(src.includes('monotonic'),
    'the comment must record that Math.max is monotonic and binds only below 80, so the floor '
    + 'cannot make a wide pane render narrow and was never masking the geometry bug');
});
