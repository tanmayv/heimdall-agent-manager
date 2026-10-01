/**
 * Wire frames for the shell stream WebSocket, as pure functions.
 * ---------------------------------------------------------------------------
 * REQ-SHELL-18. Split out of `useShellStream` with NO imports, so the decision
 * "is this geometry worth sending, and what exactly goes on the wire" is
 * executable in `node --test` instead of only reachable through a React hook
 * that needs a live WebSocket and a live PTY to observe.
 *
 * The bug this guards: geometry used to be pushed to the PTY from exactly two
 * places — xterm's `onResize` (which fires only when the pane's own dimensions
 * CHANGE) and a mount-effect fit. Both run before the socket is open, and the
 * send path drops any frame on a non-OPEN socket, so on a freshly created
 * session the PTY never learned the pane's size and stayed at its 80x24
 * default until something resized the window.
 */

export type ShellGeometry = { rows: number; cols: number };

/**
 * The `resize` frame for a geometry, or `null` when there is nothing worth sending.
 *
 * Returning `null` rather than a zero-valued frame matters: a PTY told it is 0x0
 * is worse off than one left at its default, and both an unmounted terminal
 * (`null` geometry) and one whose renderer has not measured a cell yet (0 rows or
 * 0 cols) are transient states we expect to see on a cold mount.
 */
export function shellResizeFrame(geom: ShellGeometry | null | undefined): string | null {
  if (!geom) return null;
  const { rows, cols } = geom;
  if (!Number.isFinite(rows) || !Number.isFinite(cols)) return null;
  if (rows <= 0 || cols <= 0) return null;
  return JSON.stringify({ type: 'resize', rows, cols });
}
