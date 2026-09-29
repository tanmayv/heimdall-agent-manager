import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

/**
 * A push-only tick for shell-session consumers that are NOT RTK Query caches.
 *
 * REQ-SHELL-6 §6 deleted every shell poller and requires the UI to be driven from the
 * push channel instead. For the RTK Query consumers that is exact — `invalidateTags`
 * on a shell event refetches the detail view, the panels and the tab badge. But the
 * Shells LIST PAGE does not read RTK Query at all: it pages through `useInfiniteList`
 * with its own `fetchShellPage` promise (ShellListPage.tsx), which no tag can reach.
 * Its interval was therefore the only thing telling it a session had changed.
 *
 * Rather than leave that page on focus-refetch alone — which is not push, and would
 * have left a user watching the list seeing nothing until they clicked away and back —
 * `invalidateShellSession` bumps this counter from the same place it invalidates the
 * tags. The page selects the counter and probes page one when it moves, feeding its
 * existing "N new or updated" pill exactly as the interval used to.
 *
 * WHY A BARE COUNTER AND NOT THE EVENT ITSELF. The consumer does not need to know
 * WHICH session changed: `list.refresh()` re-probes page one and diffs, so any event
 * is the same instruction ("something moved, go look"). Storing session ids here would
 * be a second, weaker copy of state the server already owns — and per the chain's
 * output rule the row is the truth, not the message. A counter also collapses a burst
 * of events into one render, since every bump lands in the same reducer tick.
 */
export interface ShellState {
  /** Monotonic; the VALUE is meaningless, only that it changed. */
  eventSeq: number;
}

const initialState: ShellState = { eventSeq: 0 };

export const shellSlice = createSlice({
  name: 'shells',
  initialState,
  reducers: {
    // `_action` is accepted but unread so the event payload can be logged by the
    // store's action logger without this reducer growing a dependency on its shape.
    shellSessionEventReceived(state, _action: PayloadAction<{ sessionId?: string } | undefined>) {
      state.eventSeq += 1;
    },
  },
});

export const { shellSessionEventReceived } = shellSlice.actions;
export default shellSlice.reducer;
