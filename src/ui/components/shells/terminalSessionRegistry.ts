/**
 * Client Terminal Session Registry (Milestone M3)
 * 
 * Provides centralized client-side persistence for terminal sessions across
 * tab switches, dock toggling, and route navigations.
 * 
 * Features:
 * 1. Serialized terminal grid and scrollback persistence via @xterm/addon-serialize.
 * 2. Unmounted delta chunk buffering with strict 1MB cap per session.
 * 3. Exact viewport scroll offset retention and restoration.
 * 4. Gated remount restoration preventing live-stream race conditions.
 * 5. Full compliance with PROJECT.md Interface Contracts and DISPATCH.md specifications.
 */

import type { Terminal as TerminalType } from '@xterm/xterm';
import type { SerializeAddon as SerializeAddonType } from '@xterm/addon-serialize';
import * as serializeModule from '@xterm/addon-serialize';

// Dual-support constructor resolution for ESM/CJS runtime interop
const serializeObj = serializeModule as Record<string, any>;
export const SerializeAddon = (
  serializeObj.SerializeAddon ||
  serializeObj['default']?.SerializeAddon ||
  serializeObj['default']
) as typeof SerializeAddonType;

/** Maximum delta bytes buffered per unmounted session (1 MB cap per specification) */
export const MAX_DELTA_BYTES = 1024 * 1024;

/**
 * Saved state interface satisfying both PROJECT.md Contract and DISPATCH.md specifications
 */
export interface SavedTerminalState {
  sessionId: string;
  snapshot: string;
  // Scroll position: scrollOffset and savedViewportY alias each other
  scrollOffset: number;
  savedViewportY: number;
  // Delta buffers: deltaBuffer and deltaChunks alias each other
  deltaBuffer: Uint8Array[];
  deltaChunks: Uint8Array[];
  totalDeltaBytes: number;
  /**
   * Set once the cap has discarded bytes, and cleared only by a drain (REQ-FIX-7).
   *
   * Both eviction vectors cut the byte stream at an arbitrary offset: the tail slice in
   * `bufferSessionDelta` and the FIFO `shift()` below it. Neither respects a UTF-8 code point or
   * an escape sequence, so whatever survives can begin mid-character or mid-CSI. Replaying from
   * there corrupts the restored screen, and it would fire precisely when a backgrounded tab is
   * busy enough to reach the cap. The bytes are still retained — the cap is what bounds memory —
   * but this flag makes the REPLAY refuse them; see `drainSessionDeltas`.
   */
  truncated: boolean;
  updatedAt: number;
  cols: number;
  rows: number;
  isSized: boolean;
}

/**
 * Atomic restoration payload returned upon remount
 */
export interface TerminalRestorationData {
  snapshot: string;
  /** Empty when `truncated` is set — a truncated buffer is never replayed (REQ-FIX-7). */
  deltaChunks: Uint8Array[];
  /**
   * The delta buffer overflowed its cap, so the consumer must NOT expect continuity with the
   * snapshot. Restore the snapshot alone and let the live stream carry the screen forward; the
   * server sends a full `screen` frame on every (re)connect, so the pane self-heals.
   */
  truncated: boolean;
  savedViewportY: number;
  scrollOffset: number;
  cols: number;
  rows: number;
}

export class TerminalSessionRegistry {
  private sessions = new Map<string, SavedTerminalState>();
  private activeSessions = new Set<string>();
  private serializeAddons = new Map<string, SerializeAddonType>();

  // --------------------------------------------------------------------------
  // Addon Lifecycle Integration
  // --------------------------------------------------------------------------

  /**
   * Registers a SerializeAddon attached to an active Terminal instance
   */
  registerSerializeAddon(sessionId: string, addon: SerializeAddonType): void {
    this.serializeAddons.set(sessionId, addon);
  }

  /**
   * Unregisters and disposes the SerializeAddon associated with a session
   */
  unregisterSerializeAddon(sessionId: string): void {
    this.serializeAddons.delete(sessionId);
  }

  // --------------------------------------------------------------------------
  // State Persistence & Inspection
  // --------------------------------------------------------------------------

  /**
   * Checks whether the registry contains saved state for the given session ID
   */
  hasSessionState(sessionId: string): boolean {
    return this.sessions.has(sessionId);
  }

  /**
   * Retrieves saved terminal state for the given session ID (DISPATCH.md specification)
   */
  getSessionState(sessionId: string): SavedTerminalState | undefined {
    return this.sessions.get(sessionId);
  }

  /**
   * Alias for getSessionState (PROJECT.md Interface Contract & E2E tests)
   */
  get(sessionId: string): SavedTerminalState | undefined {
    return this.getSessionState(sessionId);
  }

  /**
   * Saves terminal state. Supports either an xterm Terminal instance or pre-serialized string.
   */
  saveSessionState(
    sessionId: string,
    termOrSnapshot: TerminalType | string,
    scrollOffset?: number,
    cols?: number,
    rows?: number
  ): void {
    let snapshot = '';
    let viewportY = scrollOffset ?? 0;
    let terminalCols = cols ?? 80;
    let terminalRows = rows ?? 24;

    if (typeof termOrSnapshot === 'string') {
      snapshot = termOrSnapshot;
    } else if (termOrSnapshot && typeof termOrSnapshot === 'object') {
      const term = termOrSnapshot as TerminalType;
      terminalCols = cols ?? term.cols;
      terminalRows = rows ?? term.rows;
      viewportY = scrollOffset ?? (term.buffer?.active?.viewportY ?? 0);

      const addon = this.serializeAddons.get(sessionId);
      if (addon) {
        try {
          snapshot = addon.serialize();
        } catch (err) {
          console.warn(`[TerminalSessionRegistry] Failed to serialize session ${sessionId}:`, err);
        }
      }
    }

    const existing = this.sessions.get(sessionId);
    const deltaList = existing ? existing.deltaBuffer : [];
    const totalBytes = existing ? existing.totalDeltaBytes : 0;
    // A snapshot save must not launder away an overflow that already happened.
    const wasTruncated = existing ? existing.truncated : false;

    const state: SavedTerminalState = {
      sessionId,
      snapshot,
      scrollOffset: viewportY,
      savedViewportY: viewportY,
      deltaBuffer: deltaList,
      deltaChunks: deltaList,
      totalDeltaBytes: totalBytes,
      truncated: wasTruncated,
      updatedAt: Date.now(),
      cols: terminalCols,
      rows: terminalRows,
      isSized: true,
    };

    this.sessions.set(sessionId, state);
  }

  /**
   * Alias for saveSessionState matching PROJECT.md Interface Contract & E2E tests
   */
  saveSnapshot(
    sessionId: string,
    snapshot: string,
    viewportY: number,
    cols: number,
    rows: number
  ): void {
    this.saveSessionState(sessionId, snapshot, viewportY, cols, rows);
  }

  // --------------------------------------------------------------------------
  // Delta Buffering & Memory Protection (1MB Cap)
  // --------------------------------------------------------------------------

  /**
   * Buffers an incoming WebSocket delta chunk for an unmounted or background session.
   * Enforces strict MAX_DELTA_BYTES (1MB) threshold by pruning oldest chunks.
   * (DISPATCH.md specification)
   */
  bufferSessionDelta(sessionId: string, chunk: Uint8Array | string): void {
    if (!chunk || chunk.length === 0) return;

    const bytes = typeof chunk === 'string'
      ? new TextEncoder().encode(chunk)
      : chunk;

    if (bytes.length === 0) return;

    // Defensive copy / handle single chunk > MAX_DELTA_BYTES
    let safeChunk: Uint8Array;
    let droppedBytes = false;
    if (bytes.byteLength > MAX_DELTA_BYTES) {
      // Cuts at an arbitrary offset — see SavedTerminalState.truncated.
      safeChunk = bytes.slice(bytes.byteLength - MAX_DELTA_BYTES);
      droppedBytes = true;
    } else {
      safeChunk = new Uint8Array(bytes);
    }

    let state = this.sessions.get(sessionId);
    if (!state) {
      const buffer = [safeChunk];
      state = {
        sessionId,
        snapshot: '',
        scrollOffset: 0,
        savedViewportY: 0,
        deltaBuffer: buffer,
        deltaChunks: buffer,
        totalDeltaBytes: safeChunk.byteLength,
        truncated: droppedBytes,
        updatedAt: Date.now(),
        cols: 80,
        rows: 24,
        isSized: false,
      };
      this.sessions.set(sessionId, state);
      return;
    }

    state.deltaBuffer.push(safeChunk);
    state.totalDeltaBytes += safeChunk.byteLength;
    state.updatedAt = Date.now();
    if (droppedBytes) {
      state.truncated = true;
    }

    // Prune oldest chunks until total buffered bytes <= MAX_DELTA_BYTES.
    // Chunk boundaries are wherever the socket happened to split the stream, so dropping whole
    // chunks is no safer than slicing one — either way the remainder can start mid-sequence.
    while (state.totalDeltaBytes > MAX_DELTA_BYTES && state.deltaBuffer.length > 0) {
      const removed = state.deltaBuffer.shift();
      if (removed) {
        state.totalDeltaBytes -= removed.byteLength;
        state.truncated = true;
      }
    }
  }

  /**
   * Alias for bufferSessionDelta matching PROJECT.md Interface Contract & E2E tests
   */
  appendDelta(sessionId: string, chunk: Uint8Array): void {
    this.bufferSessionDelta(sessionId, chunk);
  }

  // --------------------------------------------------------------------------
  // Delta Draining & Remount Restoration
  // --------------------------------------------------------------------------

  /**
   * Drains and returns all buffered delta chunks, clearing the delta buffer for the session.
   * (DISPATCH.md specification)
   */
  drainSessionDeltas(sessionId: string): Uint8Array[] {
    const state = this.sessions.get(sessionId);
    if (!state) return [];

    // REQ-FIX-7: a truncated buffer is dropped rather than replayed. Resuming from a cut offset
    // can begin mid-code-point or mid-CSI and garble the restored screen, which is strictly worse
    // than a stale one — the caller falls back to the snapshot and the live stream repaints.
    const deltas = state.truncated ? [] : [...state.deltaBuffer];

    // Mutated in place: deltaBuffer and deltaChunks alias one another (see SavedTerminalState).
    // Assigning a fresh array here would desync them with no type error and no failing test.
    state.deltaBuffer.length = 0;
    state.totalDeltaBytes = 0;
    // The drain re-anchors the stream: bytes buffered from here on are contiguous again.
    state.truncated = false;
    return deltas;
  }

  /**
   * Atomically consumes restoration payload and clears pending deltas.
   * (PROJECT.md Interface Contract & E2E tests)
   */
  consumeRestorationData(sessionId: string): TerminalRestorationData | null {
    const state = this.sessions.get(sessionId);
    if (!state) return null;

    const wasTruncated = state.truncated;
    const deltas = this.drainSessionDeltas(sessionId);
    return {
      snapshot: state.snapshot,
      deltaChunks: deltas,
      truncated: wasTruncated,
      savedViewportY: state.savedViewportY,
      scrollOffset: state.scrollOffset,
      cols: state.cols,
      rows: state.rows,
    };
  }

  // --------------------------------------------------------------------------
  // Active Session Lifecycle & Cleanup
  // --------------------------------------------------------------------------

  /**
   * Registers a session as active
   */
  registerActiveSession(sessionId: string): void {
    this.activeSessions.add(sessionId);
  }

  /**
   * Unregisters a session from active set
   */
  unregisterActiveSession(sessionId: string): void {
    this.activeSessions.delete(sessionId);
  }

  /**
   * Checks if session is registered as active
   */
  isSessionActive(sessionId: string): boolean {
    return this.activeSessions.has(sessionId);
  }

  /**
   * Alias for isSessionActive (test convenience)
   */
  isActive(sessionId: string): boolean {
    return this.isSessionActive(sessionId);
  }

  /**
   * Clears saved state for the specified session (DISPATCH.md specification)
   */
  clearSessionState(sessionId: string): void {
    this.sessions.delete(sessionId);
    this.activeSessions.delete(sessionId);
    this.serializeAddons.delete(sessionId);
  }

  /**
   * Closes session and purges all state (PROJECT.md Contract & E2E tests)
   */
  closeSession(sessionId: string): void {
    this.clearSessionState(sessionId);
  }

  /**
   * Clears all session states (for test teardown and full system reset)
   */
  clearAll(): void {
    this.sessions.clear();
    this.activeSessions.clear();
    this.serializeAddons.clear();
  }
}

// Global Singleton Export
export const terminalSessionRegistry = new TerminalSessionRegistry();
export default terminalSessionRegistry;
