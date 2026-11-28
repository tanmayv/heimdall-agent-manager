import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

// G12: agent output is streamed, not stored. ACP assistant text (and any other
// streamed output the Hub relays as `agent_output` events) lives ONLY in this
// slice: never in an RTK Query cache, the Hub's chat tables or browser storage.
// A reload starts empty, and that is accepted. The chat transcript shows only
// messages (user input and the agent's explicit `chat send` replies); this
// slice feeds the muted "working" blocks under the last message.
//
// Only turns after the agent's last sent message matter: when a new agent
// reply arrives, finished turns before it are dropped. The live turn stays.

export const AGENT_OUTPUT_TURNS_PER_CONVERSATION = 12;
export const AGENT_OUTPUT_SEGMENTS_PER_TURN = 64;

export type AgentOutputSegment = {
  messageId: string;
  // 'text' (assistant text) today; the field leaves room for thoughts/plans.
  kind: string;
  // Position within the turn: the bridge suffixes later segments `:s<N>`.
  index: number;
  revision: number;
  status: 'pending' | 'complete' | 'failed';
  stopReason: string;
  // Sealed for the owner vault; decrypted only while rendering.
  body: string;
};

export type AgentOutputTurn = {
  turnKey: string;
  agentInstanceId: string;
  startedAt: number;
  finished: boolean;
  failed: boolean;
  segments: AgentOutputSegment[];
};

export type AgentOutputState = {
  byConversation: Record<string, AgentOutputTurn[]>;
};

const initialState: AgentOutputState = { byConversation: {} };

export type AgentOutputSegmentPayload = {
  conversationId: string;
  agentInstanceId: string;
  turnId: string;
  messageId: string;
  kind?: string;
  revision: number;
  status: string;
  stopReason?: string;
  body: string;
  receivedAt?: number;
};

const SEGMENT_SUFFIX = /:s(\d+)$/;

export function agentOutputTurnKey(turnId: string): string {
  return String(turnId || '').replace(SEGMENT_SUFFIX, '');
}

function segmentIndex(turnId: string): number {
  const match = SEGMENT_SUFFIX.exec(String(turnId || ''));
  return match ? Number(match[1]) : 0;
}

function normalizeStatus(status: string): AgentOutputSegment['status'] {
  return status === 'complete' || status === 'failed' ? status : 'pending';
}

// A turn ends with a failed segment, or with a complete segment that carries
// the prompt's stop reason. A complete segment without one only closed at a
// tool boundary inside the turn. A newer turn also ends every earlier one.
function segmentEndsTurn(segment: AgentOutputSegment): boolean {
  return segment.status === 'failed' || (segment.status === 'complete' && segment.stopReason !== '');
}

const agentOutputSlice = createSlice({
  name: 'agentOutput',
  initialState,
  reducers: {
    agentOutputSegmentReceived(state, action: PayloadAction<AgentOutputSegmentPayload>) {
      const p = action.payload;
      const conversationId = String(p?.conversationId || '');
      const messageId = String(p?.messageId || '');
      const turnKey = agentOutputTurnKey(p?.turnId);
      const revision = Number(p?.revision) || 0;
      if (!conversationId || !messageId || !turnKey || revision < 1) return;
      const turns = state.byConversation[conversationId] || (state.byConversation[conversationId] = []);
      let turn = turns.find((entry) => entry.turnKey === turnKey);
      if (!turn) {
        for (const older of turns) older.finished = true;
        turn = { turnKey, agentInstanceId: String(p.agentInstanceId || ''), startedAt: Number(p.receivedAt) || Date.now(), finished: false, failed: false, segments: [] };
        turns.push(turn);
        if (turns.length > AGENT_OUTPUT_TURNS_PER_CONVERSATION) turns.splice(0, turns.length - AGENT_OUTPUT_TURNS_PER_CONVERSATION);
      }
      const next: AgentOutputSegment = {
        messageId,
        kind: String(p.kind || 'text'),
        index: segmentIndex(p.turnId),
        revision,
        status: normalizeStatus(String(p.status || '')),
        stopReason: String(p.stopReason || ''),
        body: String(p.body || ''),
      };
      const at = turn.segments.findIndex((segment) => segment.messageId === messageId);
      if (at >= 0) {
        const current = turn.segments[at];
        // Snapshots replace the whole body. Older revisions and a terminal
        // segment reopening as pending are stale retries.
        if (revision <= current.revision || (current.status !== 'pending' && next.status === 'pending')) return;
        turn.segments[at] = next;
      } else {
        turn.segments.push(next);
        turn.segments.sort((a, b) => a.index - b.index);
        if (turn.segments.length > AGENT_OUTPUT_SEGMENTS_PER_TURN) turn.segments.splice(0, turn.segments.length - AGENT_OUTPUT_SEGMENTS_PER_TURN);
      }
      if (segmentEndsTurn(next)) {
        turn.finished = true;
        turn.failed = next.status === 'failed';
      }
    },
    // The agent sent a message: earlier finished turns no longer matter.
    agentReplyReceived(state, action: PayloadAction<{ conversationId: string }>) {
      const conversationId = String(action.payload?.conversationId || '');
      const turns = state.byConversation[conversationId];
      if (!turns) return;
      const live = turns.filter((turn) => !turn.finished);
      if (live.length) state.byConversation[conversationId] = live;
      else delete state.byConversation[conversationId];
    },
    agentOutputCleared(state, action: PayloadAction<{ conversationId?: string } | undefined>) {
      const conversationId = String(action.payload?.conversationId || '');
      if (conversationId) delete state.byConversation[conversationId];
      else state.byConversation = {};
    },
  },
});

export const { agentOutputSegmentReceived, agentReplyReceived, agentOutputCleared } = agentOutputSlice.actions;
export default agentOutputSlice.reducer;

const NO_TURNS: AgentOutputTurn[] = [];
export function selectAgentOutputTurns(state: any, conversationId: string | null | undefined): AgentOutputTurn[] {
  if (!conversationId) return NO_TURNS;
  return (state?.agentOutput as AgentOutputState | undefined)?.byConversation?.[conversationId] ?? NO_TURNS;
}

// A turn is streaming: the activity tail shows "Responding…".
export function hasLiveAgentOutput(turns: readonly AgentOutputTurn[]): boolean {
  return turns.some((turn) => !turn.finished);
}

// Maps a raw Hub `agent_output` / `assistant_segment` event to the payload.
export function agentOutputPayloadFromEvent(raw: any, receivedAt = Date.now()): AgentOutputSegmentPayload | null {
  if (raw?.type !== 'agent_output' || raw?.event !== 'assistant_segment') return null;
  const conversationId = String(raw.conversation_id || '');
  const messageId = String(raw.message_id || '');
  const turnId = String(raw.turn_id || '');
  if (!conversationId || !messageId || !turnId) return null;
  return {
    conversationId,
    agentInstanceId: String(raw.agent_instance_id || ''),
    turnId,
    messageId,
    kind: String(raw.kind || 'text'),
    revision: Number(raw.revision) || 0,
    status: String(raw.message_status || ''),
    stopReason: String(raw.stop_reason || ''),
    body: String(raw.body || ''),
    receivedAt,
  };
}
