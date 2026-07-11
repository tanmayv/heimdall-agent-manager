# Needs attention tab — actionable inbox plan

## Current state

- `App.tsx` renders `AttentionPlaceholder`, filtered by `task.status === 'blocked' | 'review_ready'`.
- Approve/Reject buttons are gated on a task participant whose `agent_instance_id === 'user_proxy'`.
- Nothing else surfaces: memory proposals, chain merges, and smart-answer approvals sent via `chat.send_to_user` are invisible.
- Chat approvals from agents (`{"type":"smart_answer", "suggested_replies":[...]}` and similar) are stored as regular chat messages. They have no expiry, no chain binding beyond `chain_id` on the message, and no way to see or act on them from Needs attention.
- Memory proposals already have `refreshMemory` and `decideMemoryProposal` in `memorySlice`.
- Chain merge state exists (`chain.status === 'reviewing'`, `vcs_workspace` merge_pending); no card renders it.

## Goal

Needs attention becomes the single actionable inbox for operator. It shows durable, chain-bound cards for:

1. Memory proposals pending decision (approve / reject).
2. Task chains in reviewing / merge-pending state (open merge preview / approve merge / reject).
3. Tasks pending user approval (user_proxy `lgtm_required`, and blocked-on-user reasons).
4. Chat approvals from agents sent via `send_to_user` with `smart_answer` / `questions` / structured suggested replies. Every such approval must:
   - be bound to an existing task chain,
   - carry an explicit expiry,
   - support one-click replies that get routed back as if the operator typed the suggested answer.

Non-actionable items must not appear.

## Card model (frontend)

Unified type `AttentionCard`:

```ts
type AttentionCard = {
  key: string;                       // stable id for React
  kind: 'memory' | 'chain_merge' | 'task_approval' | 'chat_approval';
  chainId?: string;                  // required for chat_approval + chain_merge, optional otherwise
  chainTitle?: string;
  projectId?: string;
  title: string;                     // short, action-oriented
  description: string;
  createdAtUnixMs: number;
  expiresAtUnixMs?: number;          // required for chat_approval
  actions: AttentionAction[];        // buttons
  meta: Record<string, string>;      // small key/value under the title
  raw: any;                          // the source record for debugging
};

type AttentionAction = {
  key: string;
  label: string;
  tone: 'primary' | 'positive' | 'negative' | 'neutral';
  invoke: () => Promise<void>;
};
```

## Card sources

### 1. Memory proposals

- Source: `memorySlice.recordsById` filtered by `status === 'pending'`.
- On mount of Needs attention, dispatch `refreshMemory()` if not recently loaded.
- Card:
  - title: `Memory proposal: {title}` (fallback to `subject_agent` + type).
  - description: proposal `body`.
  - meta: subject_agent, type, scope, source_task_id (as chain link if it maps to a chain).
  - actions:
    - Approve → `decideMemoryProposal({ proposalId, decision: 'approve' })`.
    - Reject → `decideMemoryProposal({ proposalId, decision: 'reject' })`.
    - View → open memory detail side-sheet.
- Expiry: none by default (memory proposals are durable).
- Chain binding: if `source_task_id` resolves to a `chainId`, expose chain link.

### 2. Chain merge attention

- Source: `chainsById` filtered by:
  - `chain.status === 'reviewing'`, or
  - `chainView.workspaceByChainId[chainId]?.merge_status === 'merge_pending'`.
- Card:
  - title: `Merge review: {chain.title}`.
  - description: brief workspace summary if present.
  - meta: coordinator, team, workspace status.
  - actions:
    - Preview merge → dispatch `previewWorkspaceMerge(chainId)` then open chain view.
    - Open chain → `openChain(chainId)`.
    - Approve merge / Reject merge → placeholders wired to existing `handle_workspace_merge_for_chain` and chain complete/reject endpoints (final approval action still lives in ChainView but Attention should at least deep-link).
- Expiry: none by default.
- Chain binding: intrinsic.

### 3. Task pending user approval

- Source: `tasksById` where any of the following is true:
  - `task.status === 'review_ready'` and any participant with `role === 'lgtm_required'` and `agent_instance_id === 'user_proxy'`.
  - `task.status === 'blocked'` and `notActionableReason` starts with `awaiting_user_` or `manual_block:` containing `user`/`operator`.
- Card:
  - title: `Approve task: {task.title}`.
  - description: task description (trimmed).
  - meta: chain title, assignee, reviewer.
  - actions:
    - Approve → dispatch `voteOnAttentionTask({ approved: true })`.
    - Request changes → dispatch `voteOnAttentionTask({ approved: false })` with a prompt for a short reason.
    - Open task → open chain view and select the task.
- Expiry: none.
- Chain binding: intrinsic.

### 4. Chat approvals (smart_answer / questions)

- Source: durable chat messages with `direction === 'agent_to_user'`, addressed to `operator@local`, whose body parses as JSON with `type` in `{smart_answer, questions, approval_request}` and non-empty `suggested_replies` or `options`.
- Every such approval must be bound to a chain. To enforce this durably we introduce:

#### Backend: `chat_approvals` projection

- New event kind or new table `chat_approvals`:
  - `approval_id TEXT PRIMARY KEY`
  - `message_id TEXT NOT NULL`
  - `chain_id TEXT NOT NULL`  (rejected if empty)
  - `user_id TEXT NOT NULL`
  - `agent_instance_id TEXT NOT NULL` (sender)
  - `kind TEXT NOT NULL`       (`smart_answer` | `questions` | `approval_request`)
  - `title TEXT`
  - `body TEXT`
  - `options_json TEXT`        (structured suggested replies)
  - `expires_at_unix_ms INTEGER NOT NULL`
  - `state TEXT NOT NULL`      (`open` | `answered` | `expired` | `cancelled`)
  - `answered_reply TEXT`
  - `answered_at_unix_ms INTEGER`
  - `created_unix_ms INTEGER NOT NULL`
- Insertion path: extend `agent_chat_send_to_user` / `chat_service.chat_service_send_to_user` so that when `body` parses as an approval-shaped JSON payload:
  - require a `chain_id` (reject with 400 `chain_id_required_for_approval` if missing / not member of the sending agent’s chains).
  - default `expires_at_unix_ms` = now + `chat_approval_default_ttl_ms` (config, default 30 min). Agents can supply `expires_in_ms` in the JSON body or a top-level field.
  - persist an `Chat_Approval` row and set `state = open`.
- New endpoints:
  - `GET /chat-approvals/pending` (user_client authenticated) → list open, non-expired approvals for `operator@local`.
  - `POST /chat-approvals/answer` → body `{approval_id, reply}`. Validates:
    - approval `open` and `expires_at_unix_ms > now`.
    - `reply` matches one of `options_json.suggested_replies` values (or is a free-form reply if `kind === questions` and `free_form=true`).
    - persists `answered_reply`, `answered_at_unix_ms`, `state=answered`.
    - re-uses the existing `chat_store_append_message_with_chain` path to send the reply as a normal `user_to_agent` message on that `chain_id`, so agent side stays uniform.
  - `POST /chat-approvals/cancel` (optional, allows the sending agent to withdraw).
- Expiry:
  - lightweight sweeper in `task_nudge_scheduler` tick, or piggy-back on periodic autoscaler tick, moving `state = open` and `expires_at_unix_ms <= now` to `state = expired` and emitting a WS `chat_approval_expired` event so the UI can hide/mark them.

#### Frontend

- New `attentionSlice`:
  - `chatApprovalsById`, `chatApprovalIds`.
  - `refreshChatApprovals` thunk hitting `GET /chat-approvals/pending`.
  - `answerChatApproval` thunk hitting `POST /chat-approvals/answer`.
  - Handle `chat_approval_created`, `chat_approval_answered`, `chat_approval_expired` WS events.
- Card:
  - title from `title` or first line of `body`.
  - description = trimmed body.
  - meta: chain title, sender agent, expires-in relative time (e.g. `expires in 12m`).
  - actions: one button per `suggested_replies` entry (labels from structured field or fallback to raw text). Free-form reply is a small textarea + Send when `free_form=true`.
  - Open chain button always present.
- Client-side expiry countdown: tick every 30s to hide expired cards even without a WS event.

## Aggregation, ordering, and empty state

- Assemble cards in a memoized selector:
  - `chat_approval` first, ordered by soonest expiry.
  - `task_approval` next, ordered by chain then task creation time.
  - `chain_merge` next.
  - `memory` last, most-recent first.
- Badge count = total cards.
- Empty state: friendly note with links to Home and Memory tabs.

## UI structure

- Replace `AttentionPlaceholder` with `AttentionSurface`.
- Sub-components:
  - `AttentionCard` (generic renderer).
  - `ChatApprovalCard` (extends generic with countdown + suggested reply buttons + optional free-form input).
  - `MergeApprovalCard`.
  - `TaskApprovalCard`.
  - `MemoryProposalCard`.
- Filter chips: `All | Chat | Tasks | Merge | Memory` and a `Show expired` toggle for chat approvals.
- Keep `data-debug-id` attributes:
  - `attention-card-{kind}-{key}`
  - `attention-card-{kind}-{key}-action-{actionKey}`

## WS / refresh strategy

- On surface mount: dispatch `refreshMemory`, `refreshChatApprovals`, `refreshTaskBoard`, and a workspace fetch for reviewing chains.
- Live updates:
  - `memory_proposed`, `memory_decided` → rerun `refreshMemory` or apply patch to `memorySlice`.
  - `task_event` for `review_ready`/`approved` → already reflected in `tasksSlice`.
  - `chat_approval_created`, `chat_approval_answered`, `chat_approval_expired` → patch `attentionSlice`.
  - Chain workspace merge state changes (existing) → refresh workspace/preview.

## Backend touchpoints (files)

- `src/daemon/chat_service.odin` or new `src/daemon/chat_approval_service.odin`.
- `src/daemon/chat_store.odin` (recognize approval JSON payloads).
- `src/daemon/message_db_service.odin` (new `chat_approvals` table + prepared statements).
- `src/daemon/chat_http.odin` (`GET /chat-approvals/pending`, `POST /chat-approvals/answer`, `POST /chat-approvals/cancel`).
- `src/daemon/agent_rpc.odin` / `src/daemon/agent_chat.odin` (persist `Chat_Approval` on `send_to_user` when body shape matches).
- `src/daemon/task_nudge_scheduler.odin` (periodic expiry sweep).
- `src/daemon/user_pref_rest.odin` (nudge template for `msg_chat_approval_expired` if wanted).
- `src/daemon/task_service.odin` (existing `task_user_proxy_review_card_json` now also creates a Chat_Approval so the operator sees a card).

## CLI

- `ham-ctl chat approvals list --token <user_token>`
- `ham-ctl chat approvals answer --token <user_token> --approval-id <id> --reply <text>`
- `ham-ctl chat approvals cancel --token <agent_token> --approval-id <id>`

## Validation plan

- `tests/test_chat_approval_requires_chain.py` — approval-shaped send_to_user without chain_id returns 400.
- `tests/test_chat_approval_expiry.py` — TTL default, `answered` and `expired` transitions, sweeper flips state.
- `tests/test_chat_approval_answer_reply_persisted.py` — answering sends a `user_to_agent` message on the same chain.
- `tests/test_needs_attention_surface.py` (source-level UI test) — surface renders card for each kind and buttons carry expected `data-debug-id`.
- `tests/test_ui_chat_approval_countdown.py` — timer removes expired cards client-side.
- `python3 tests/test_ui_new_project_creation.py` and existing UI tests remain green.
- `nix build .#ham-daemon .#ham-wrapper .#ham-ctl` and `npm run build`.

## Rollout order (small, safe steps)

1. Backend: add `chat_approvals` table + service + endpoints, without changing existing chat flows. Cover with tests.
2. Backend: extend `agent_chat_send_to_user` to detect approval payloads, require `chain_id`, and insert Chat_Approval. Existing chat message still stored so agents that don’t know about approvals keep working. Add tests.
3. Backend: replace `task_user_proxy_review_card_json` insertion to also create a Chat_Approval (bound to the task’s chain).
4. Frontend: add `attentionSlice`, thunks, WS handlers.
5. Frontend: replace `AttentionPlaceholder` with `AttentionSurface` and 4 card renderers. Wire filter chips. Add UI tests.
6. Frontend: wire memory + merge + task-approval cards through existing slices; no new backend needed for those.
7. CLI: add `chat approvals` subcommands. Add smoke test.
8. Docs update in `docs/teams-v1/` + `.heimdall/coordinator-chat-visibility-plan.md` cross-reference.

## Improvements over the original brief

- Made chain binding a hard backend invariant with a 400 error instead of hoping frontend enforces it.
- Persisted the approval as its own durable record, not just a chat message, so expiry and state are queryable and testable.
- Chose reply-fanout via the existing `user_to_agent` chat path so agents don’t need a new receive channel.
- Added a periodic expiry sweeper and WS events for reactive UI hiding.
- Kept the surface pluggable: the same generic card shape is used across all four kinds, so we can add more sources (e.g. workspace conflict prompts) without rewriting the surface.
