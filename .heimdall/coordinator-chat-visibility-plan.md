# Coordinator Chat Visibility Fix Plan

Target project: `/Users/tanmayvijay/heimdall-agent-manager`
Chain: `chain-19f500dc5ca`
Planner task: `task-19f5016c3fb`
Status: planning only; no code changes until reviewer/risk LGTM and user/proxy approval.

## Approved RCA summary

Coordinator chain chat is chain-scoped, but agent replies sent with `ham-ctl chat send-to-user` are persisted as unscoped direct-chat messages:

- UI chain view fetches `/chats/{coordinator}/messages?...&chain_id=<focused-chain>` via `src/ui/store/chainViewSlice.ts` and `src/ui/api/daemonApi.ts`.
- REST fetch filters by `chain_id` in `src/daemon/chat_rest.odin`.
- `ham-ctl chat send-to-user` builds an agent RPC payload without `chain_id` in `src/ctl/main.odin`.
- `src/daemon/agent_rpc.odin` accepts `send_to_user` without chain context.
- `src/daemon/chat_service.odin` persists through `chat_store_append_message(...)`, which stores empty `chain_id`.
- Direct chat remains intentionally unscoped; `tests/test_send_to_user_empty_chain_id.py` locks that compatibility behavior.
- `chat_event` websocket fanout lacks `chain_id`, so focused chain refresh cannot be targeted precisely when one coordinator serves multiple chains.

## Product decision proposed

Preserve existing direct-chat semantics by default and add an explicit chain-aware coordinator reply path:

1. `send_to_user` remains valid without `chain_id` and continues to persist empty-chain direct-chat messages.
2. `send_to_user` accepts optional `chain_id` when the sending agent is the chain coordinator.
3. When `chain_id` is supplied and valid, the agent-to-user reply is persisted with that `chain_id`, making it visible in the coordinator chain chat.
4. `chat_event` includes `chain_id` when the changed message is chain-scoped, allowing UI refresh targeting.
5. CLI exposes `ham-ctl chat send-to-user --chain-id <chain>` / `--chain <chain>` for coordinator replies in chain context.

## Implementation tasks after approval

### Task A — Backend/CLI chain-aware send-to-user

Assignee: `coder@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:
- Update `src/ctl/main.odin` `ctl_agent_chat` so `chat send-to-user` accepts optional `--chain-id` / `--chain` and includes `chain_id` in the agent RPC JSON only when supplied.
- Update help text for `chat send-to-user` to document optional chain scope.
- Update `src/daemon/agent_rpc.odin` `handle_agent_rpc_send_to_user` to parse optional `chain_id`.
- Validate `chain_id` when supplied:
  - chain exists;
  - sending agent is that chain's `coordinator_agent_instance_id`;
  - retain existing user validation.
- Add a new service helper, e.g. `chat_append_agent_to_user_with_chain(user_id, agent_instance_id, body, chain_id)`, that calls `chat_store_append_message_with_chain(...)` when scoped and current unscoped behavior when not scoped.
- Return `chain_id` in the RPC response when supplied.

Acceptance criteria:
- Existing unscoped `send_to_user` behavior and response remain backward compatible.
- Supplying a valid coordinator `chain_id` persists `agent_to_user` with that exact `chain_id`.
- Supplying an unknown chain or a chain whose coordinator is not the sending agent fails with a clear 4xx error and does not persist a message.
- Existing `tests/test_send_to_user_empty_chain_id.py` still passes unchanged or with only non-semantic harness updates.

### Task B — Chain-aware websocket chat events

Assignee: `coder@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:
- Extend chat event fanout to include optional `chain_id`.
- Prefer an additive helper/signature so existing calls can continue emitting unscoped events without behavior changes.
- Ensure events remain compact and do not embed large message bodies.
- Update call sites for chain-scoped user-to-coordinator and coordinator-to-user messages to pass chain_id.

Acceptance criteria:
- `chat_event` for chain-scoped messages contains `chain_id`.
- `chat_event` for unscoped direct chat omits `chain_id` or sends it as empty string consistently.
- Existing large-message websocket compaction behavior remains intact.

### Task C — UI refresh targeting for chain chat

Assignee: `coder@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:
- Update `src/ui/components/App.tsx` chat event handling:
  - if payload has `chain_id`, revalidate the focused chain only when it matches the focused chain;
  - preserve current fallback for events without `chain_id` by matching focused chain coordinator, so legacy/unscoped events still refresh reasonably;
  - keep direct chat refresh behavior for selected direct agent.
- Keep coordinator chat rendering unchanged; once messages are persisted with chain_id, existing chain fetch/render should show them.

Acceptance criteria:
- Focused chain refreshes when receiving a matching chain-scoped event.
- Non-focused chains are not unnecessarily refreshed by chain-scoped events.
- Legacy unscoped events preserve existing behavior.

### Task D — Regression/e2e tests

Assignee: `tester@swe-team`
Required reviewers: `reviewer@swe-team`, `risk-analyst@swe-team`

Scope:
- Add backend regression test for chain-scoped coordinator replies, likely `tests/test_send_to_user_chain_id.py`:
  - register/create coordinator agent and user;
  - create or insert a chain with that coordinator;
  - call `/agent-rpc` `send_to_user` with `chain_id`;
  - assert persisted/fetched message has matching `chain_id`;
  - assert chain-filtered `/chats/{agent}/messages?chain_id=...` returns the reply;
  - assert unscoped/direct fetch still returns appropriately per existing semantics.
- Add negative authorization test cases for unknown chain and non-coordinator sender.
- Update/add websocket test to assert compact `chat_event` includes `chain_id` for scoped sends and remains compact for large bodies.
- Add/update UI test around `App.tsx` or an e2e smoke path to prove the coordinator chain view refreshes and displays the coordinator reply.

Acceptance criteria:
- New tests fail on current behavior and pass with the implementation.
- Existing direct-chat and empty-chain tests continue passing.

### Task E — Final validation and review package

Assignee: `tester@swe-team` for validation; `reviewer@swe-team` and `risk-analyst@swe-team` for final LGTM

Validation commands/evidence to collect:
- `python3 tests/test_send_to_user_empty_chain_id.py`
- `python3 tests/test_send_to_user_chain_id.py` (new)
- `python3 tests/test_large_chat_event_compact.py` or updated equivalent
- Targeted UI/static test, e.g. `python3 tests/test_ui_live_chat_ws_fallback.py` plus any new chain-event targeting test
- If available in project workflow: full relevant test suite command documented by implementer after inspecting repo scripts
- Manual smoke command after build/restart:
  - send coordinator reply with `ham-ctl chat send-to-user --token <coordinator-token> --user-id operator@local --chain-id <chain-id> --body <text>`;
  - verify SQLite row has `chain_id=<chain-id>`;
  - verify chain coordinator chat surface displays the reply;
  - verify direct unscoped `ham-ctl chat send-to-user` still creates empty-chain direct chat.

## Risks and mitigations

- Compatibility risk: existing direct chat depends on empty-chain messages. Mitigation: optional `chain_id`, old test stays.
- Authorization/model risk: arbitrary agents could write into chain chat. Mitigation: require sending agent to be chain coordinator for supplied chain.
- Multi-chain refresh risk: coordinator owns multiple chains. Mitigation: include `chain_id` in websocket event and target refresh by focused chain.
- Test fragility risk: daemon tests may require isolated DB/ports. Mitigation: model new test on `tests/test_send_to_user_empty_chain_id.py` harness.

## Approval gate

Before any coding task starts:
1. `task-19f5016c3fb` plan receives required LGTM from `reviewer@swe-team` and `risk-analyst@swe-team`.
2. Principal/coordinator obtains explicit user/proxy approval for this plan and product decision.
3. Only then create/activate implementation tasks for coder/tester/reviewer, or explicitly move pre-created tasks from planning to ready.
