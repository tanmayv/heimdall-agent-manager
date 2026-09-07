import { createSlice, PayloadAction } from '@reduxjs/toolkit';

// Transient, ephemeral agent-activity state that powers the push-only "activity
// bubbles" shown above the chat composer (see AgentActivityBubbles in P3). This
// slice is deliberately DECOUPLED from RTK Query: `agent_action` events are
// fire-and-forget presence signals, so routing them here must NEVER invalidate or
// refetch a cache. The state is bounded (last few actions per instance) and is
// reset with the rest of the client state on user switch via the root reducer's
// `priorUserClientStateCleared` handling (store.ts), so it needs no explicit
// clear-on-logout reducer.

// Ring buffer: keep only the last N actions per instance (enough to replay recent
// activity when the user opens that instance's conversation).
export const AGENT_ACTIVITY_RING_CAP = 4;
// Replay window: on focus/open we replay buffered actions newer than this; older
// buffered actions are dropped (never replayed).
export const AGENT_ACTIVITY_REPLAY_WINDOW_MS = 5 * 60_000;

export type AgentActionItem = {
  // Stable React key; unique across replayed + live bubbles for the same instance.
  id: string;
  // Machine kind (e.g. 'task_comment') — optional icon/telemetry, never shown raw.
  action: string;
  // Human-readable, id-free summary composed by the hub (already clipped).
  summary: string;
  // Hub unix-ms timestamp; used for the replay window and ordering.
  ts: number;
};

type AgentActivityState = {
  // Per-instance ring buffer (cap AGENT_ACTIVITY_RING_CAP), oldest-first.
  byInstance: Record<string, AgentActionItem[]>;
  // Per-instance most-recent action time; feeds the working-indicator decoupling
  // in P4 (dots animate while now - lastActionAt is within a short window).
  lastActionAt: Record<string, number>;
  // Monotonic counter so concurrent same-ts actions still get unique ids.
  seq: number;
};

const initialState: AgentActivityState = {
  byInstance: {},
  lastActionAt: {},
  seq: 0,
};

export type AgentActionReceivedPayload = {
  instanceId: string;
  action: string;
  summary: string;
  ts: number;
};

const agentActivitySlice = createSlice({
  name: 'agentActivity',
  initialState,
  reducers: {
    // Append one agent action to the acting instance's ring buffer and bump its
    // lastActionAt. Ignores malformed events (no instance/summary). The visible
    // 4s per-bubble lifetime is owned by the component, not this slice — here we
    // only retain enough history to replay on open.
    agentActionReceived(state, action: PayloadAction<AgentActionReceivedPayload>) {
      const instanceId = String(action.payload?.instanceId || '');
      const summary = String(action.payload?.summary || '');
      if (!instanceId || !summary) return;
      const ts = Number(action.payload?.ts) || Date.now();
      state.seq += 1;
      const item: AgentActionItem = {
        id: `${instanceId}:${ts}:${state.seq}`,
        action: String(action.payload?.action || ''),
        summary,
        ts,
      };
      const buffer = state.byInstance[instanceId] || (state.byInstance[instanceId] = []);
      buffer.push(item);
      // Trim oldest so the buffer never exceeds the ring cap.
      if (buffer.length > AGENT_ACTIVITY_RING_CAP) {
        buffer.splice(0, buffer.length - AGENT_ACTIVITY_RING_CAP);
      }
      state.lastActionAt[instanceId] = Math.max(Number(state.lastActionAt[instanceId] || 0), ts);
    },
    // Drop an instance's buffered activity (e.g. when it is stopped/removed).
    agentActivityInstanceCleared(state, action: PayloadAction<string>) {
      const instanceId = String(action.payload || '');
      if (!instanceId) return;
      delete state.byInstance[instanceId];
      delete state.lastActionAt[instanceId];
    },
  },
});

// selectReplayableActions returns the buffered actions still within the replay
// window (< AGENT_ACTIVITY_REPLAY_WINDOW_MS old), oldest-first — the exact set the
// bubble row replays (staggered) when the user opens/focuses the conversation.
// Pure so the component (P3) and the unit tests share one implementation.
export function selectReplayableActions(
  buffer: AgentActionItem[] | undefined,
  now: number,
): AgentActionItem[] {
  if (!buffer || buffer.length === 0) return [];
  return buffer
    .filter((item) => now - Number(item?.ts || 0) < AGENT_ACTIVITY_REPLAY_WINDOW_MS)
    .slice()
    .sort((left, right) => Number(left?.ts || 0) - Number(right?.ts || 0));
}

// Stable empty reference so selectors don't churn renders for instances with no
// buffered activity.
const EMPTY_BUFFER: AgentActionItem[] = [];

export const selectAgentActivityBuffer = (state: any, instanceId: string): AgentActionItem[] =>
  state?.agentActivity?.byInstance?.[instanceId] || EMPTY_BUFFER;

export const selectAgentLastActionAt = (state: any, instanceId: string): number =>
  Number(state?.agentActivity?.lastActionAt?.[instanceId] || 0);

export const { agentActionReceived, agentActivityInstanceCleared } = agentActivitySlice.actions;
export default agentActivitySlice.reducer;
