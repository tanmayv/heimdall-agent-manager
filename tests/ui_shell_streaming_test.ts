// REQ-STREAM-IMPL-3: Automated unit and contract tests for Phase 3 UI streaming integration
//
// RUN: node --test tests/ui_shell_streaming_test.ts
//  OR: npx tsx tests/ui_shell_streaming_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as xtermModule from '@xterm/xterm';

import {
  dispatchShellInput,
  dispatchShellResize,
  pollingSubscriptionSessionId,
  resolveStreamRenderMode,
  resolveStreamingMode,
} from '../src/ui/components/shells/streamingMode.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const EXPERIMENTAL_PANEL = path.join(REPO_ROOT, 'src/ui/components/settings/ExperimentalPanel.tsx');
const USE_SHELL_STREAM = path.join(REPO_ROOT, 'src/ui/components/shells/useShellStream.ts');
const SHELL_TERMINAL_PANE = path.join(REPO_ROOT, 'src/ui/components/shells/ShellTerminalPane.tsx');
const USE_SHELL_PANE_SUB = path.join(REPO_ROOT, 'src/ui/hooks/useShellPaneSubscription.ts');
const STREAMING_MODE = path.join(REPO_ROOT, 'src/ui/components/shells/streamingMode.ts');

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => term.write(data, () => resolve()));
}

function renderedLines(term: any): string[] {
  const out: string[] = [];
  for (let i = 0; i < term.buffer.active.length; i++) {
    out.push(term.buffer.active.getLine(i)?.translateToString(true) ?? '');
  }
  while (out.length > 0 && out[out.length - 1] === '') out.pop();
  return out;
}

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

  // 3. Streaming path writes raw bytes through one helper, never through the polled repaint.
  // (This used to assert the substring 'term.write(bytes)', which a COMMENT in the source
  // satisfied — so it would have passed with the write path deleted entirely.)
  assert.ok(
    src.includes('writeStreamBytes(term, bytes)'),
    'onOutput must hand raw stream bytes to the single stream write path'
  );
  assert.ok(
    src.includes('const writeStreamBytes = useCallback((term: TerminalType, bytes: Uint8Array)'),
    'the stream write path must exist as one helper rather than being duplicated per call site'
  );
  assert.ok(
    src.includes('if (!isPolledRepaintOwner) return;'),
    'the destructive repaint must run only once polling genuinely owns the screen'
  );

  // 4. Graceful fallback upon error or disconnect
  assert.ok(src.includes('fallbackToPolling'), 'must track fallbackToPolling state');
  assert.ok(src.includes('setFallbackToPolling(true)'), 'must trigger fallbackToPolling on error or close');

  // 5. Clean isolation for future removal
  assert.ok(src.includes('STREAMING PATH'), 'must demarcate streaming path');
  assert.ok(src.includes('LEGACY POLLING PATH'), 'must demarcate legacy polling path');

  // 6. Zero-capture polling enforcement (REQ-STREAM-FIX-1), now routed through the resolver so
  // the reconnect window is covered behaviourally below rather than frozen as a substring.
  assert.ok(
    src.includes('sessionId: pollingSubscriptionSessionId(paneSessionId, streamingMode)'),
    'must derive the polling subscription session id from the streaming-mode resolver'
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

test('ShellTerminalPane.tsx disables convertEol in streaming mode, enforces >=40 column floor without 24-row floor, and allows horizontal scroll', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE), 'ShellTerminalPane.tsx must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  // 1. convertEol is disabled during active streaming
  assert.ok(src.includes('convertEol: !isStreamingActive'), 'must initialize Terminal with convertEol: !isStreamingActive');
  assert.ok(
    src.includes('terminalRef.current.options.convertEol = !isStreamingActive'),
    'must synchronize convertEol with streaming status'
  );

  // 2. Minimum column floor (>=40 cols) and row floor (no 24-row floor) enforced in resize handlers
  assert.ok(src.includes('const effectiveCols = Math.max(cols, 40);'), 'handleResize must enforce minimum 40 cols');
  assert.ok(!src.includes('const effectiveRows = Math.max(rows, 24);'), 'handleResize must not enforce minimum 24 rows');
  assert.ok(!src.includes('Math.max(rows, 24)'), 'must not enforce 24-row floor in handleResize');
  assert.ok(!src.includes('Math.max(term.rows, 24)'), 'must not enforce 24-row floor in term.resize');
  assert.ok(
    src.includes('term.resize(Math.max(term.cols, 40), term.rows)'),
    'dispatchResize and observers must enforce >=40 cols and fit rows directly'
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
    ],
    'a new ShellTerminalPane call site must be added to this test AND keyed by session id'
  );
});

test('REQ-SHELL-DOCK-NO-VSCROLL-23: the 40-col floor is kept deliberately without 24-row floor, with reason recorded', () => {
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  // Kept, not removed. The floor pairs with overflow-x-auto to keep 40 usable
  // columns on a narrow pane instead of reflowing a TUI into unreadability.
  assert.ok(src.includes('DELIBERATE MINIMUM'),
    'the floors must be justified in a comment as a deliberate minimum, not left bare');
  // And the reason they are NOT the cause of the width symptom, so it is not re-derived.
  assert.ok(src.includes('monotonic'),
    'the comment must record that Math.max is monotonic and binds only below 40, so the floor '
    + 'cannot make a wide pane render narrow and was never masking the geometry bug');
  assert.ok(!src.includes('Math.max(rows, 24)'), 'must not enforce 24-row floor in handleResize');
  assert.ok(!src.includes('Math.max(term.rows, 24)'), 'must not enforce 24-row floor in term.resize');
});

// REQ-FIX-2 — these four tests replace a pair of source-substring assertions that pinned
// `isStreamingActive = isStreamingExperimentEnabled && !fallbackToPolling` as the routing
// predicate. That substring passed while the pane handed keystrokes to a closed socket and
// painted nothing for the whole ~8s reconnect backoff, because a substring cannot observe a
// disconnected socket. These execute the decision instead.

test('REQ-FIX-2: convertEol routing stays decoupled from streamConnected', () => {
  // The render mode is what drives convertEol. A momentary disconnect must NOT flip the pane
  // into LF-translating mode, or a frame arriving in the same tick as the reconnect is corrupted.
  const connected = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false });
  assert.equal(connected.isStreamingActive, true);

  // Same inputs minus the connection: the render mode does not take streamConnected at all, so
  // there is no value of it that can change the answer.
  assert.equal(
    resolveStreamingMode(connected, false).isStreamingActive,
    true,
    'a dropped socket must not change how bytes are decoded'
  );
  assert.equal(resolveStreamingMode(connected, true).isStreamingActive, true);

  // Exhausted retries are different: polling owns the screen, so LF translation comes back.
  const fallen = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: true });
  assert.equal(fallen.isStreamingActive, false, 'fallback hands the screen to the polled repaint');
  assert.equal(fallen.isStreamEnabled, false, 'and stops reopening the socket');
});

test('REQ-FIX-2: a stream drop degrades to polling for input, resize and repaint', () => {
  const renderMode = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false });

  // The reconnect window: socket down, retries NOT yet exhausted, so fallbackToPolling is false.
  // This is the state the regression could not see.
  const dropped = resolveStreamingMode(renderMode, false);
  assert.equal(dropped.isStreamTransportReady, false, 'a closed socket cannot carry input or resize');
  assert.equal(dropped.isPollingTransport, true, 'polling must take over input and resize');
  assert.equal(dropped.isStreamEnabled, true, 'the socket must still be trying to reconnect');

  // The screen does NOT change hands. Activating the subscription starts fetching captures, and
  // every capture feeds a term.reset() that would destroy scrollback the capture cannot replace.
  assert.equal(dropped.isPolledRepaintOwner, false, 'a transient drop must not hand over the screen');
  assert.equal(
    pollingSubscriptionSessionId('sess-1', dropped),
    null,
    'the polled capture must stay idle during the drop, or its repaint resets live scrollback'
  );

  // Reconnected: the stream takes everything back and polling goes idle.
  const live = resolveStreamingMode(renderMode, true);
  assert.equal(live.isStreamTransportReady, true);
  assert.equal(live.isPollingTransport, false);
  assert.equal(live.isPolledRepaintOwner, false);
  assert.equal(
    pollingSubscriptionSessionId('sess-1', live),
    null,
    'no duplicate capture polling while the stream is live'
  );
});

test('REQ-FIX-2: exhausted retries and a disabled experiment both route everything to polling', () => {
  for (const [label, input] of [
    ['fallback latched', { isStreamingExperimentEnabled: true, fallbackToPolling: true }],
    ['experiment off', { isStreamingExperimentEnabled: false, fallbackToPolling: false }],
    ['both', { isStreamingExperimentEnabled: false, fallbackToPolling: true }],
  ] as const) {
    const renderMode = resolveStreamRenderMode(input);
    for (const connected of [false, true]) {
      const mode = resolveStreamingMode(renderMode, connected);
      assert.equal(mode.isStreamTransportReady, false, `${label}: stream must not own the transport`);
      assert.equal(mode.isPollingTransport, true, `${label}: polling owns the transport`);
      // Here the screen DOES change hands — polling is the only thing that can paint at all.
      assert.equal(mode.isPolledRepaintOwner, true, `${label}: polling owns the screen`);
      assert.equal(pollingSubscriptionSessionId('sess-1', mode), 'sess-1', `${label}: polling stays subscribed`);
    }
  }
});

test('REQ-FIX-2: a null session id never produces a subscription', () => {
  const renderMode = resolveStreamRenderMode({ isStreamingExperimentEnabled: false, fallbackToPolling: false });
  assert.equal(pollingSubscriptionSessionId(null, resolveStreamingMode(renderMode, false)), null);
});

test('REQ-FIX-2: a stream drop preserves the rendered scrollback and the restored deltas', async () => {
  // Mirrors the real order of the two effects against a real terminal: restore on mount, then let
  // the polled repaint effect run IF the resolver says polling owns the screen.
  //
  // This is the case that made the first attempt at REQ-FIX-2 destructive. The polled capture is
  // bounded at 120 lines (useShellPaneSubscription lineLimit) while the terminal holds 5000 of
  // scrollback, and the repaint reaches it through term.reset() — so gating that reset on the
  // TRANSPORT meant every reconnect blip destroyed thousands of lines of real history, plus the
  // deltas consumeRestorationData had already drained and could not hand back.
  const POLLED_CAPTURE = 'CURRENT SCREEN ONLY\r\n';

  async function mountRestoreThenDrop(mode: ReturnType<typeof resolveStreamingMode>) {
    const term = new Terminal({ cols: 80, rows: 24, scrollback: 5000 });
    // Mount: restoration writes the serialized snapshot (which carries scrollback) and the
    // withheld deltas drained from the registry.
    for (let i = 1; i <= 30; i++) {
      await writeToTerminal(term, `HISTORY LINE ${i}\r\n`);
    }
    await writeToTerminal(term, 'WITHHELD DELTA OUTPUT\r\n');

    // The polled repaint effect, gated exactly as the pane gates it.
    if (mode.isPolledRepaintOwner) {
      term.options.convertEol = true;
      term.reset();
      await writeToTerminal(term, POLLED_CAPTURE);
    }
    const lines = renderedLines(term);
    term.dispose();
    return lines;
  }

  const renderMode = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false });

  // The drop: history and the restored delta must both still be on screen.
  const afterDrop = await mountRestoreThenDrop(resolveStreamingMode(renderMode, false));
  assert.ok(afterDrop.includes('HISTORY LINE 1'), 'the oldest scrollback line must survive a drop');
  assert.ok(afterDrop.includes('HISTORY LINE 30'), 'recent scrollback must survive a drop');
  assert.ok(
    afterDrop.includes('WITHHELD DELTA OUTPUT'),
    'the restored deltas must survive a drop — the registry already drained them, so a reset loses them for good'
  );
  assert.ok(
    !afterDrop.includes('CURRENT SCREEN ONLY'),
    'no polled capture may repaint the pane while the stream owns the screen'
  );

  // Reconnected: likewise untouched.
  const afterReconnect = await mountRestoreThenDrop(resolveStreamingMode(renderMode, true));
  assert.ok(afterReconnect.includes('HISTORY LINE 1'));
  assert.ok(afterReconnect.includes('WITHHELD DELTA OUTPUT'));

  // CONTROL — the repaint path is still wired and still works when polling genuinely owns the
  // pane. Without this the test above would pass just as well with the repaint deleted.
  const latched = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: true });
  const afterFallback = await mountRestoreThenDrop(resolveStreamingMode(latched, false));
  assert.deepEqual(
    afterFallback,
    ['CURRENT SCREEN ONLY'],
    'control: once retries are exhausted the polled capture does own the screen and repaints it'
  );
});

test('REQ-FIX-2: the polled capture is written with LF translation, at every write site', async () => {
  // Measured, not assumed: a capture written with convertEol false staircases.
  const capture = 'LINE ONE\nLINE TWO\nLINE THREE';

  const staircased = new Terminal({ cols: 80, rows: 24, convertEol: false });
  await writeToTerminal(staircased, capture);
  assert.deepEqual(
    renderedLines(staircased),
    ['LINE ONE', '        LINE TWO', '                LINE THREE'],
    'this is what a polled capture looks like without LF translation'
  );
  staircased.dispose();

  const correct = new Terminal({ cols: 80, rows: 24, convertEol: false });
  correct.options.convertEol = true; // what both polled write sites must assert
  await writeToTerminal(correct, capture);
  assert.deepEqual(renderedLines(correct), ['LINE ONE', 'LINE TWO', 'LINE THREE']);
  correct.dispose();

  // Both polled write sites must set it; the mount-time one was the single exception.
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');
  const polledWrites = src.split('term.options.convertEol = true;').length - 1;
  assert.equal(polledWrites, 2, 'both the mount-time paint and the repaint effect must assert convertEol');
});

test('streamingMode.ts is the single source of the routing decision', () => {
  assert.ok(fs.existsSync(STREAMING_MODE), 'streamingMode.ts must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  // The pane must not re-derive the predicate inline; that is how the two concerns got conflated.
  assert.ok(
    !src.includes('isStreamingActive = isStreamingExperimentEnabled'),
    'the pane must not recompute the streaming predicate inline'
  );
  assert.ok(src.includes("from './streamingMode'"), 'the pane must import the resolver');
  assert.ok(src.includes('resolveStreamRenderMode({'), 'the pane must resolve the render mode');
  assert.ok(src.includes('resolveStreamingMode('), 'the pane must resolve the transport mode');
});

test('ShellTerminalPane.tsx implements smart scrollback pinning gated on buffer.baseY > 0 and user scroll state', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE), 'ShellTerminalPane.tsx must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  assert.ok(
    src.includes('!userScrolledUpRef.current && buffer.baseY > 0'),
    'must gate scrollToBottom on buffer.baseY > 0 and !userScrolledUpRef.current'
  );
});

test('ShellTerminalPane.tsx enforces geometry-first initialization gate buffering writes until container is sized', () => {
  assert.ok(fs.existsSync(SHELL_TERMINAL_PANE), 'ShellTerminalPane.tsx must exist');
  const src = fs.readFileSync(SHELL_TERMINAL_PANE, 'utf8');

  assert.ok(src.includes('isSizedRef'), 'must maintain isSizedRef tracking container layout');
  assert.ok(src.includes('flushPendingOutput'), 'must provide flushPendingOutput helper');

  // REQ-FIX-1 — the withheld output goes into the registry's CAPPED delta buffer. This used to
  // assert `pendingStreamOutputRef`, a plain array on the component with no cap and no eviction:
  // a pane in a backgrounded dock tab reports clientWidth === 0 for the life of the tab, so that
  // queue grew without bound for exactly as long, and was discarded on unmount.
  assert.ok(
    src.includes('terminalSessionRegistry.bufferSessionDelta(sessionId, bytes)'),
    'withheld stream output must be buffered through the registry cap'
  );
  assert.ok(
    src.includes('terminalSessionRegistry.drainSessionDeltas(sessionId)'),
    'the flush must drain the same registry buffer — one queue, so replay cannot interleave'
  );
  assert.ok(
    !src.includes('pendingStreamOutputRef'),
    'no uncapped component-local output queue may remain'
  );
  assert.ok(
    src.includes('container.clientWidth === 0 || container.clientHeight === 0'),
    'getGeometry must return null when container is unmeasured'
  );
});

// ---------------------------------------------------------------------------
// REQ-FIX-8 — the transport choice for input and resize, asserted BEHAVIOURALLY
//
// These tests exist because F2's fix had no test that failed when it was removed. The reviewer
// reverted `handleInput` and `handleResize` to `isStreamingActive` and the whole suite stayed
// green: the predicate lived in an `if` inside the pane, the pane cannot be rendered here (no DOM
// harness in this repo), so nothing executed it. A source-substring check is NOT a substitute and
// is deliberately not used below — the pane has two such call sites, so the string stays matched
// when only one of them is reverted, which is the vacuous-assertion trap F4 was about.
//
// What is executed instead: the dispatchers, with recording sinks, over every state the pane can
// be in. The load-bearing case is the reconnect backoff — experiment on, retries not yet
// exhausted, socket down — where `isStreamingActive` is TRUE while the socket cannot carry a
// byte. Routing on it there throws keystrokes away for the whole ~8s window with no feedback.
// ---------------------------------------------------------------------------

/** Records which sink fired and with what, so the assertion is on behaviour, not on a flag. */
function recordingInputSinks() {
  const stream: string[] = [];
  const http: string[] = [];
  return {
    stream,
    http,
    sinks: {
      sendOverStream: (data: string) => stream.push(data),
      sendOverHttp: (data: string) => http.push(data),
    },
  };
}

function recordingResizeSinks() {
  const stream: Array<[number, number]> = [];
  const http: Array<[number, number]> = [];
  return {
    stream,
    http,
    sinks: {
      sendOverStream: (rows: number, cols: number) => stream.push([rows, cols]),
      sendOverHttp: (rows: number, cols: number) => http.push([rows, cols]),
    },
  };
}

/** The four pane states, named by what the user is living through. */
const TRANSPORT_STATES = [
  {
    label: 'experiment off: polling owns everything',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: false, fallbackToPolling: false }),
      false
    ),
    expected: 'http' as const,
  },
  {
    label: 'stream live: the socket is open',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false }),
      true
    ),
    expected: 'stream' as const,
  },
  {
    // THE REGRESSION WINDOW. isStreamingActive is true here; isStreamTransportReady is not.
    label: 'reconnect backoff: experiment on, retries not exhausted, socket down',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false }),
      false
    ),
    expected: 'http' as const,
  },
  {
    label: 'fallback latched: retries exhausted',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: true }),
      false
    ),
    expected: 'http' as const,
  },
];

test('REQ-FIX-8: a keystroke in the reconnect backoff is CARRIED by HTTP, not handed to the dead socket', () => {
  const backoff = TRANSPORT_STATES[2].mode;

  // The precondition that makes this test non-vacuous: the old predicate says "streaming" here.
  // If this ever stops holding, the mutation this test guards is no longer expressible and the
  // test below would pass for the wrong reason.
  assert.equal(backoff.isStreamingActive, true, 'the render mode must still be streaming in the backoff');
  assert.equal(backoff.isStreamTransportReady, false, 'the transport must not be ready in the backoff');

  const { stream, http, sinks } = recordingInputSinks();
  const target = dispatchShellInput(backoff, 'ls -la\r', sinks);

  assert.equal(target, 'http', 'input must route over HTTP while the socket is down');
  assert.deepEqual(stream, [], 'not one byte may be handed to a socket that is not OPEN — it would be dropped silently');
  assert.deepEqual(http, ['ls -la\r'], 'the keystroke must actually arrive at the HTTP sink, intact');
});

test('REQ-FIX-8: a resize in the reconnect backoff is CARRIED by HTTP, not handed to the dead socket', () => {
  const backoff = TRANSPORT_STATES[2].mode;
  const { stream, http, sinks } = recordingResizeSinks();

  const target = dispatchShellResize(backoff, 24, 120, sinks);

  assert.equal(target, 'http', 'resize must route over HTTP while the socket is down');
  assert.deepEqual(stream, [], 'a dropped resize leaves the PTY on stale geometry until something else resizes the pane');
  assert.deepEqual(http, [[24, 120]], 'the geometry must arrive at the HTTP sink unchanged');
});

test('REQ-FIX-8: input routing follows the live socket across every pane state', () => {
  for (const { label, mode, expected } of TRANSPORT_STATES) {
    const { stream, http, sinks } = recordingInputSinks();
    const target = dispatchShellInput(mode, 'x', sinks);

    assert.equal(target, expected, `${label}: wrong transport chosen`);
    if (expected === 'stream') {
      assert.deepEqual(stream, ['x'], `${label}: the stream sink must receive the keystroke`);
      assert.deepEqual(http, [], `${label}: HTTP must not double-send`);
    } else {
      assert.deepEqual(http, ['x'], `${label}: the HTTP sink must receive the keystroke`);
      assert.deepEqual(stream, [], `${label}: the stream sink must not be called`);
    }
  }
});

test('REQ-FIX-8: resize routing follows the live socket across every pane state', () => {
  for (const { label, mode, expected } of TRANSPORT_STATES) {
    const { stream, http, sinks } = recordingResizeSinks();
    const target = dispatchShellResize(mode, 30, 200, sinks);

    assert.equal(target, expected, `${label}: wrong transport chosen`);
    if (expected === 'stream') {
      assert.deepEqual(stream, [[30, 200]], `${label}: the stream sink must receive the geometry`);
      assert.deepEqual(http, [], `${label}: HTTP must not double-send`);
    } else {
      assert.deepEqual(http, [[30, 200]], `${label}: the HTTP sink must receive the geometry`);
      assert.deepEqual(stream, [], `${label}: the stream sink must not be called`);
    }
  }
});

test('REQ-FIX-8: exactly one transport is used per dispatch, in every state', () => {
  // Double-sending is the other way to be wrong, and it is not hypothetical: the HTTP path also
  // schedules a capture refetch, so a frame sent twice races the stream's own echo.
  for (const { label, mode } of TRANSPORT_STATES) {
    const input = recordingInputSinks();
    dispatchShellInput(mode, 'a', input.sinks);
    assert.equal(input.stream.length + input.http.length, 1, `${label}: input must be sent exactly once`);

    const resize = recordingResizeSinks();
    dispatchShellResize(mode, 24, 80, resize.sinks);
    assert.equal(resize.stream.length + resize.http.length, 1, `${label}: resize must be sent exactly once`);
  }
});

test('REQ-FIX-8: the pane owns the geometry floors, the dispatcher does not touch the numbers', () => {
  // The 40-col floor must stay in the pane (REQ-SHELL-DOCK-NO-VSCROLL-23); if it migrated into
  // the dispatcher the polled path would quietly stop receiving the floored value.
  const live = TRANSPORT_STATES[1].mode;
  const { stream, sinks } = recordingResizeSinks();
  dispatchShellResize(live, 1, 12, sinks);
  assert.deepEqual(stream, [[1, 12]], 'the dispatcher must forward the caller-floored geometry verbatim');
});
