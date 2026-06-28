# Chat Window Audit Implementation Plan

This document is for the next agent working on chat window correctness and UX issues in the Heimdall Electron UI and daemon sync path.

## Goal

Fix chat-window state sync bugs, delivery/read-status mismatches, unread-count drift, and unsafe UX behaviors like cross-agent draft leakage.

---

## Summary of Problems

Key issues identified in the audit:

1. Message updates from daemon are not merged correctly in the UI.
2. Delivery failure status exists in the daemon but is not surfaced in the UI.
3. Read semantics are inconsistent: daemon tracks conversation-level reads, while UI behaves as if reads are per-message.
4. Composer draft can leak across agents and be sent to the wrong target.
5. Sending state is global instead of per-agent.
6. Pagination can trigger false “New Messages” UX.
7. Unread counts can drift from daemon truth.
8. Full chat refresh can clobber optimistic local message state.
9. Background/fallback fetches for non-selected chats are brittle.

---

## Files Likely Involved

### UI
- `src/ui/store/chatSlice.ts`
- `src/ui/components/ChatPane.tsx`
- `src/ui/components/Composer.tsx`
- `src/ui/components/MessageBubble.tsx`
- `src/ui/components/App.tsx`
- `src/ui/api/daemonApi.ts`

### Daemon
- `src/daemon/user_rpc.odin`
- `src/daemon/chat_events.odin`
- `src/daemon/chat_rest.odin`
- `src/daemon/chat_store.odin`
- `src/daemon/message_db_service.odin`

---

## Implementation Phases

## Phase 1: Correctness and Sync

### 1. Merge message updates by `message_id`

#### Problem
The UI currently ignores later daemon updates for an existing message ID instead of merging them. This causes delivered/read/failure status changes to be lost.

#### Work
- Update `src/ui/store/chatSlice.ts`
- Change `appendMessage` behavior:
  - if message already exists by `id`, merge server fields into the existing message
  - if optimistic local message exists, reconcile it with the real server message
- Prefer daemon fields for:
  - `deliveredUnixMs`
  - `deliveredAt`
  - `readUnixMs`
  - `readAt`
  - `deliveryFailedUnixMs`
  - `deliveryError`

#### Desired outcome
A single chat bubble should evolve correctly from optimistic send -> persisted -> delivered -> read/failure.

---

### 2. Surface async delivery failure in UI

#### Problem
Daemon already tracks async delivery failures, but UI does not map or render them.

#### Work
- Extend `mapMessage(...)` in `src/ui/store/chatSlice.ts` to include:
  - `deliveryFailedUnixMs`
  - `deliveryError`
- Update `src/ui/components/MessageBubble.tsx`
- Message status priority should be:
  1. `sending`
  2. local `error`
  3. `deliveryFailedUnixMs > 0` -> `Delivery failed`
  4. `readUnixMs > 0` -> `Read`
  5. `deliveredUnixMs > 0` -> `Delivered`
  6. else `Sent`
- Optionally show delivery failure reason in tooltip or secondary text if available.

#### Desired outcome
If daemon persists a message but fails to notify the agent, the UI should show failure instead of false success.

---

### 3. Fix unread-count ownership

#### Problem
`refreshAgents()` preserves in-memory unread counts over daemon data, which can cause badge drift after reconnects, external reads, or other clients.

#### Work
- Update `src/ui/store/chatSlice.ts`
- In `refreshAgents`, do not blindly overwrite daemon unread counts with local ones.
- Preferred policy:
  - daemon unread value wins on refresh
  - WS events update unread counts between refreshes
  - only preserve local unread values if daemon omitted the field entirely

#### Desired outcome
Unread badges converge back to daemon truth after refresh/reconnect.

---

## Phase 2: UX Safety

### 4. Fix cross-agent draft leakage

#### Problem
The composer uses an uncontrolled textarea and can carry a draft from one selected agent to another.

#### Work
Choose one of these approaches:

#### Preferred
- Store per-agent drafts keyed by `agentId`
- Manage draft state in `ChatPane` or Redux
- Restore draft when switching back to an agent

#### Simpler fallback
- Key the composer by `selectedAgent?.id` so it resets on agent switch

#### Files
- `src/ui/components/Composer.tsx`
- `src/ui/components/ChatPane.tsx`
- possibly `src/ui/store/chatSlice.ts`

#### Desired outcome
Text typed for agent A should never be sent to agent B by accident.

---

### 5. Replace global sending state with per-agent sending state

#### Problem
One pending send disables the composer for all chats.

#### Work
- Replace `sending: boolean` with something like:
  - `sendingByAgentId: Record<string, boolean>`
- Update thunk reducers in `src/ui/store/chatSlice.ts`
- Update `ChatPane.tsx` and `Composer.tsx` to use the active agent’s sending state only

#### Desired outcome
A send in one chat should not block composing in another.

---

### 6. Separate pagination from new-message UX

#### Problem
Loading older history can be mistaken for new inbound messages and show the “New Messages” button incorrectly.

#### Work
- Update `src/ui/components/ChatPane.tsx`
- Distinguish:
  - prepending older paginated messages
  - appending newer live messages
- Track first/last message IDs or use a specific pagination flag
- Only show “New Messages” when the newest message changes while user is away from bottom

#### Desired outcome
Scrolling up for history should not trigger misleading new-message affordances.

---

## Phase 3: Model Cleanup and Hardening

### 7. Make read semantics coherent

#### Problem
The daemon stores conversation-level read timestamps, but the UI behaves like reads are per-message.

#### Option A: Recommended Fast Path
- Keep daemon conversation-level read model
- Update UI to stop implying exact per-message read status if not available
- Possibly show only `Sent` / `Delivered`

#### Option B: Full fidelity
- Compute per-message `read_unix_ms` at serialization time on the server
- Compare message `created_unix_ms` against the relevant read cutoff
- Update daemon serialization path in:
  - `src/daemon/message_db_service.odin`
  - `src/daemon/chat_rest.odin`
  - `src/daemon/chat_events.odin`
  - any shared message JSON writer path

#### Recommendation
Do Option A first unless exact per-message read receipts are required.

#### Desired outcome
UI semantics should match the daemon’s actual state model.

---

### 8. Prevent optimistic-message clobbering on full refresh

#### Problem
Initial or replacement chat fetches can overwrite local optimistic messages during races.

#### Work
- In `fetchSelectedChat.fulfilled`, merge server-fetched messages with any outstanding optimistic messages
- Drop optimistic messages only after matching to a real server message
- Reuse a shared merge helper if possible

#### Desired outcome
No disappearing or duplicated pending messages during send/fetch races.

---

### 9. Improve fallback fetch behavior for non-selected chats

#### Problem
When WS sends a chat event without embedded message payload, fallback fetches for non-selected uncached chats may be blocked.

#### Work
- Review `fetchSelectedChat.condition`
- Allow explicit background fetches triggered by WS
- If cleaner, add a dedicated thunk such as:
  - `fetchChatByAgentIdBackground(agentId)`

#### Desired outcome
WS-driven updates should still populate chat state for non-selected chats when needed.

---

## Suggested Order of Execution

1. Merge message updates by ID
2. Surface delivery failure state in UI
3. Fix unread-count refresh ownership
4. Fix draft leakage across agents
5. Make sending state per-agent
6. Fix pagination vs new-message toast behavior
7. Clean up read semantics
8. Harden optimistic-message merge behavior
9. Improve fallback/background fetch behavior

---

## Validation Checklist

Run manual validation after each phase.

### Message lifecycle
- Send a message and confirm optimistic bubble appears
- Confirm optimistic bubble reconciles to real server message
- Confirm delivered status updates if agent notification succeeds
- Confirm failure status updates if delivery fails

### Read behavior
- Open a chat with unread agent messages
- Mark read path should update unread badge correctly
- Verify read labeling matches actual implemented model

### Draft safety
- Type a draft for agent A
- Switch to agent B
- Confirm A draft is not accidentally sent to B
- If per-agent drafts are implemented, switch back and confirm draft restoration

### Multi-chat behavior
- Start sending in one chat
- Switch to another chat
- Confirm composer is still usable there

### Pagination behavior
- Scroll to top and trigger older-message fetch
- Confirm no false “New Messages” button appears
- While scrolled up, receive a real new message and confirm the button does appear

### Unread correctness
- Read a chat and confirm badge clears
- Refresh agent list and confirm badge stays correct
- Test reconnect and confirm unread values realign with daemon state

### Race conditions
- Trigger a send and a fetch close together
- Confirm no duplicate message and no disappearing optimistic message

---

## Notes for the Next Agent

- Start with the UI store logic in `chatSlice.ts`; that is the highest-leverage fix.
- Keep daemon as source of truth wherever possible.
- Avoid introducing a second competing message-state model in the UI.
- If changing read semantics, make sure UI labels match actual daemon guarantees.
- Prefer small, verifiable steps with manual testing after each.

---

## Expected Deliverables

- Updated chat Redux/store merge logic
- Updated message mapping for failure state
- Safer composer behavior across agent switches
- Per-agent sending state
- Improved pagination/new-message behavior
- Read-model cleanup decision and implementation
- Manual test notes or evidence summary
