/**
 * Streaming-mode resolution for the shell terminal pane (REQ-FIX-2).
 *
 * Extracted as pure functions on purpose. These booleans used to be one `isStreamingActive`
 * inside ShellTerminalPane, and that overloading is the defect this module closes: a single flag
 * governed BOTH how bytes are decoded (convertEol) and WHICH transport carries input, resize and
 * repaints. Those two questions have different answers while the socket is down, so no single
 * boolean can be right for both.
 *
 * Two layers, because the pane needs the first one BEFORE it can have the second: `isStreamEnabled`
 * is what opens the socket, and `streamConnected` only exists once it is open.
 *
 * Keeping the decision here also makes the reconnect window executable in a test rather than
 * asserted as a source substring, which is how the regression stayed locked in before.
 */

export interface StreamRenderModeInput {
  /** `streaming_terminal_pane` experiment flag. */
  isStreamingExperimentEnabled: boolean;
  /** Set once reconnect attempts are exhausted; a one-way latch until the user retries. */
  fallbackToPolling: boolean;
}

export interface StreamRenderMode {
  /**
   * The stream is the renderer: raw PTY bytes are written through verbatim and the polled
   * `term.reset()` repaint is not in charge of the screen.
   *
   * DELIBERATELY INDEPENDENT OF `streamConnected`. This is the flag that drives `convertEol`, and
   * a brief disconnect must not flip the pane into LF-translating mode — a frame arriving in the
   * same tick as the reconnect would be corrupted. That decoupling is right; what went wrong was
   * using this same flag for transport routing too (see `isStreamTransportReady`).
   */
  isStreamingActive: boolean;
  /** The socket should be open or attempting to open. */
  isStreamEnabled: boolean;
}

export interface StreamingMode extends StreamRenderMode {
  /**
   * The stream can actually carry bytes right now.
   *
   * Gates input, resize, the polled repaint and the polling subscription. Unlike
   * `isStreamingActive` this REQUIRES a live socket, because `sendInput`/`sendResize` silently
   * drop frames when the socket is not OPEN. During the reconnect backoff
   * (MAX_RECONNECT_ATTEMPTS=3, rising to MAX_RECONNECT_DELAY_MS=5000, so roughly 8s)
   * `fallbackToPolling` is still false — so routing on `isStreamingActive` alone throws keystrokes
   * away with no feedback and leaves the pane unpainted for the whole window.
   */
  isStreamTransportReady: boolean;
  /** Polling must carry input and resize. */
  isPollingTransport: boolean;
  /**
   * The polled capture owns the SCREEN, so the destructive `term.reset()` repaint may run.
   *
   * Deliberately NOT the same as `isPollingTransport`, and this distinction is the whole reason
   * this module exists. A dropped socket hands over input and resize, but it must NOT hand over
   * the screen: the polled capture is bounded at 120 lines (`useShellPaneSubscription` lineLimit)
   * while the terminal holds 5000 lines of scrollback, and the repaint gets there via
   * `term.reset()`. Letting a transient blip run it destroys thousands of lines of the user's real
   * history to recover a 120-line capture — strictly worse than the stale pane it replaces, and it
   * would also reset over a restoration whose deltas `consumeRestorationData` has already drained
   * and cannot hand back.
   *
   * So the screen changes hands only once polling genuinely owns the pane: the experiment is off,
   * or retries are exhausted and `fallbackToPolling` has latched. A reconnect repaints the grid
   * from the server's `screen` frame; nothing brings destroyed scrollback back.
   */
  isPolledRepaintOwner: boolean;
}

/**
 * Resolves how bytes are decoded and whether the socket should be up. Connection-independent, so
 * the pane can call it before it has a connection to report.
 */
export function resolveStreamRenderMode({
  isStreamingExperimentEnabled,
  fallbackToPolling,
}: StreamRenderModeInput): StreamRenderMode {
  const isStreamingActive = isStreamingExperimentEnabled && !fallbackToPolling;
  return { isStreamingActive, isStreamEnabled: isStreamingActive };
}

/**
 * Resolves which transport owns input, resize and repainting, given a live connection state.
 */
export function resolveStreamingMode(
  renderMode: StreamRenderMode,
  streamConnected: boolean
): StreamingMode {
  const isStreamTransportReady = renderMode.isStreamingActive && streamConnected;
  return {
    ...renderMode,
    isStreamTransportReady,
    isPollingTransport: !isStreamTransportReady,
    isPolledRepaintOwner: !renderMode.isStreamingActive,
  };
}

/**
 * Session id to hand the polled-capture subscription, or null to leave it idle.
 *
 * Tied to `isPolledRepaintOwner`, not to the transport. Activating the subscription also starts
 * fetching captures — `useShellPaneSubscription` fires one IMMEDIATELY on activation, not on its
 * next interval — and every capture that lands feeds the destructive repaint. Leaving it idle
 * while the stream owns the render is what keeps a reconnect from resetting the screen, and keeps
 * a mount-time GET from racing the restoration.
 */
export function pollingSubscriptionSessionId(
  sessionId: string | null,
  mode: StreamingMode
): string | null {
  return mode.isPolledRepaintOwner ? sessionId : null;
}

/** Which transport actually carried a frame. Returned so the choice is assertable, not inferred. */
export type ShellTransportTarget = 'stream' | 'http';

/** The two ways a keystroke can leave the pane. Exactly one is called per dispatch. */
export interface ShellInputSinks {
  /** `useShellStream`'s `sendInput` — silently drops the frame unless the socket is OPEN. */
  sendOverStream: (data: string) => void;
  /** The legacy `sendShellInput` POST plus its debounced capture refetch. */
  sendOverHttp: (data: string) => void;
}

/** The two ways a geometry change can leave the pane. Exactly one is called per dispatch. */
export interface ShellResizeSinks {
  sendOverStream: (rows: number, cols: number) => void;
  sendOverHttp: (rows: number, cols: number) => void;
}

/**
 * Routes one keystroke and reports where it went (REQ-FIX-8).
 *
 * The routing lives HERE, not in the pane, for one reason: the pane cannot be rendered in a test —
 * this repo has no DOM harness — so an `if` inside `handleInput` was unreachable by every
 * assertion, and that is precisely how F2 survived. Reverting the predicate below to
 * `isStreamingActive` hands keystrokes to a closed socket for the whole ~8s reconnect backoff;
 * tests/ui_shell_streaming_test.ts drives this function with recording sinks and fails when it
 * does. A source-substring check could not: the pane has two of these call sites, so the string
 * stays matched when only one is reverted.
 *
 * Deliberately NOT sharing a predicate helper with `dispatchShellResize`. They were two
 * independent inline branches in the pane and they stay independently revertible, so each has its
 * own test and neither mutation can hide behind the other's coverage.
 */
export function dispatchShellInput(
  mode: StreamingMode,
  data: string,
  sinks: ShellInputSinks
): ShellTransportTarget {
  if (mode.isStreamTransportReady) {
    sinks.sendOverStream(data);
    return 'stream';
  }
  sinks.sendOverHttp(data);
  return 'http';
}

/**
 * Routes one resize and reports where it went (REQ-FIX-8).
 *
 * Same contract and same rationale as `dispatchShellInput`. A dropped resize is quieter than a
 * dropped keystroke and worse: the PTY keeps the stale geometry until something else resizes the
 * pane, so a TUI reflows against dimensions the terminal no longer has. Callers apply their
 * minimum-geometry floors BEFORE dispatching; this function does not touch the numbers.
 */
export function dispatchShellResize(
  mode: StreamingMode,
  rows: number,
  cols: number,
  sinks: ShellResizeSinks
): ShellTransportTarget {
  if (mode.isStreamTransportReady) {
    sinks.sendOverStream(rows, cols);
    return 'stream';
  }
  sinks.sendOverHttp(rows, cols);
  return 'http';
}
