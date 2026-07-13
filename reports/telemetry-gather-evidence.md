# Telemetry Gather Evidence

Task: `task-19f594d6f23`  
Chain: `chain-19f594d6ea8`  
Scope: evidence gathering only. This file intentionally does **not** make the final architecture recommendation; it gives source-grounded findings for synthesis in `task-19f594d6f25` after the restart gate.

## Requirements covered

- **TEL-1** — Evidence identifies where/how QPS, live agent count, and inter-agent message counts could be measured.
- **TEL-2** — Evidence compares plausible telemetry backends/visualization/storage approaches, including Grafana-compatible options.
- **TEL-3** — Evidence notes data model/query history useful for future memory audits.
- **TEL-5** — This persisted artifact under `reports/` lists evidence, source paths, and commands for reviewer audit.

## Commands and source-inspection methods

Commands run from workspace `/tmp/heimdall-worktrees/heimdall-agent-manager/team/team-chain-19f594d6ea8/we-want-to-add-graffana-backed-telemetry`:

```sh
find src/daemon src/wrapper src/ctl src/lib src/contracts tests -maxdepth 2 -type f | sort | head -220
rg -n "(listen|serve|route|endpoint|/health|/clients|agent-rpc|user-rpc|ws|WebSocket|handle_|POST|GET|metrics|telemetry|prometheus|opentelemetry)" src/daemon/{server.odin,http.odin,rest_router.odin,agent_rpc.odin,user_rpc.odin,ws.odin,user_ws.odin,ws_events.odin} src/wrapper/daemon_client.odin package.json flake.nix
rg -n "(agent_instance_id|connected|disconnected|heartbeat|last_seen|runtime|status|client|register|unregister|start|stop|ttl|active)" src/daemon/{registry.odin,agent_runtime_tracker.odin,agent_lifecycle_notifications.odin,user_client_registry.odin,user_client_lifecycle.odin,agents_start.odin,agents_stop.odin} tests/test_agent_runtime_tracker_backend.py tests/test_activity_daemon_projection.py tests/test_chain_completion_agent_shutdown.py
rg -n "(message|Message|Chat|chat|event|Event|notify|notification|outbox|queue|deliver|failed|retry|send|receive|append|jsonl)" src/daemon/{message_bus.odin,message_service.odin,message_queue.odin,message_hooks.odin,message_db_service.odin,chat_service.odin,chat_store.odin,chat_events.odin,task_notifications.odin,task_notification_outbox.odin,user_ws.odin,ws_events.odin} tests/test_send_to_user_chain_id.py tests/test_offline_queue_e2e.py tests/test_user_inbox_offline_send.py tests/test_task_notification_recipient_scope.py
rg -n "(opentelemetry|prometheus|grafana|metrics|statsd|monarch|mimir|victoria|thanos|openmetrics)" . -g '!vendor' -g '!node_modules'
rg -n "(sqlite|odin|curl|prometheus|opentelemetry|metrics|grafana|nodejs|buildInputs|nativeBuildInputs)" flake.nix src tests package.json
```

Primary files read:

- `src/daemon/server.odin`
- `src/daemon/http.odin`
- `src/daemon/rest_router.odin`
- `src/daemon/agent_rpc.odin`
- `src/daemon/user_rpc.odin`
- `src/daemon/ws.odin`
- `src/daemon/user_ws.odin`
- `src/daemon/registry.odin`
- `src/daemon/agent_runtime_tracker.odin`
- `src/daemon/agents_start.odin`
- `src/daemon/message_service.odin`
- `src/daemon/message_bus.odin`
- `src/lib/message_provider/memory.odin`
- `src/contracts/message_provider.odin`
- `src/daemon/message_db_service.odin`
- `src/daemon/chat_service.odin`
- `src/daemon/chat_store.odin`
- `src/daemon/chat_events.odin`
- `src/daemon/task_store.odin`
- `src/daemon/task_notifications.odin`
- `src/daemon/task_notification_outbox.odin`
- `src/daemon/memory_service.odin`
- `src/daemon/memory_db_service.odin`
- `src/daemon/audit_db_service.odin`
- `src/daemon/memory_auditor_orchestrator.odin`
- `src/daemon/router_adapter.odin`
- `src/daemon/central_hub_store.odin`
- `src/daemon/hub_sync.odin`
- `package.json`

## Existing telemetry / observability evidence

### Current request telemetry is log-only and content-heavy

`src/daemon/server.odin` creates a thread-local `Request_Telemetry` object in `handle_client`, assigning method, parsed path, start tick, and either body params for mutating requests or query params for reads before dispatching to REST and legacy routes. `src/daemon/http.odin` emits `[RPC TELEMETRY]` lines from `write_response`, including method, path, params, status, latency, response size, and short response bodies. Heartbeat routes are skipped to reduce noise.

Implications:

- There is already a central HTTP/RPC observation point suitable for request counters and latency histograms.
- It is currently log output, not a queryable metrics endpoint or durable metric store.
- It currently logs request params and short response bodies. That is useful for debugging but risky for telemetry: final design should avoid exporting prompt/message/memory bodies and should either remove or sanitize params/body fields from metrics.

### No existing Prometheus/OpenTelemetry/Grafana integration found

Repository-wide searches for `prometheus`, `opentelemetry`, `grafana`, `statsd`, and `openmetrics` found no first-class telemetry dependency or metrics endpoint in source/package manifests. `package.json` contains Electron/Vite/React dependencies, not telemetry packages. Odin daemon code imports system SQLite in multiple database services but not a metrics library.

Implication: any metrics support is likely new work. For low-friction implementation, a custom in-process metric registry plus `/metrics` OpenMetrics text output may be more practical than adopting a full SDK immediately.

## TEL-1 evidence: QPS measurement points

### Central HTTP request/QPS instrumentation point

Facts:

- `src/daemon/server.odin` accepts TCP clients in `run_server` and dispatches each client on a thread via `thread.run_with_poly_data(client, handle_client)`.
- `handle_client` parses method/path via `parse_route_context`, then dispatches all major daemon endpoints: `/health`, `/ws/*`, `/user-ws/*`, `/register`, `/heartbeat`, `/user-client/heartbeat`, `/user-rpc`, `/agent-rpc`, chat routes, agents routes, hub routes, memory routes, project routes, task routes, workspace routes, backup routes, `/clients`, `/attention`, teams, and workspace requests.
- `src/daemon/http.odin` is a common response writer for JSON HTTP responses and computes request latency from `current_telemetry`.

Useful metrics:

| Metric candidate | Type | Where to measure | Suggested labels | Notes |
|---|---:|---|---|---|
| `heimdall_http_requests_total` | counter | `handle_client` or `write_response` | `method`, normalized `route`, `status_class`, maybe `caller_type` | Use normalized routes, not raw paths with IDs, to avoid cardinality explosion. |
| `heimdall_http_request_duration_seconds` | histogram | `write_response` after latency calculation | `method`, normalized `route`, `status_class` | Existing `Request_Telemetry.start_tick` supports this. |
| `heimdall_http_in_flight_requests` | gauge | increment at `handle_client` entry, decrement on exit | `method` optional | Current threaded handler makes this useful for load visibility. |
| `heimdall_rpc_actions_total` | counter | `handle_agent_rpc`, `handle_user_rpc` | `rpc=agent|user`, `action`, `status_class` | Captures meaningful app-level QPS beyond generic `/agent-rpc`. |
| `heimdall_rpc_action_duration_seconds` | histogram | around action dispatch | `rpc`, `action`, `status_class` | Required because many daemon actions share `/agent-rpc` or `/user-rpc`. |

Cardinality cautions:

- Do **not** label metrics by raw `task_id`, `message_id`, `memory_id`, `client_instance_id`, or full `agent_instance_id` in Prometheus-style metrics.
- Prefer low-cardinality labels: route family, RPC action, caller kind (`agent`, `user`, `operator`), status class, team kind, project id only if the project count is known to be small or if metric backend supports high cardinality.
- Per-agent/per-task correlations should go to structured events/logs/SQLite rollups, not high-cardinality time-series labels.

### RPC/action-level QPS points

Facts:

- `src/daemon/agent_rpc.odin` dispatches agent actions including `send_message`, `fetch_messages`, `send_to_user`, `fetch_user_chat`, `user_presence`, memory proposal/decision/list/show/history, `start_success`, and guide RPC actions.
- `src/daemon/user_rpc.odin` dispatches user actions including chat fetch/list/send/mark-read, task operations, memory operations, project operations, and agent reorder.
- Many distinct product behaviors are multiplexed through `POST /agent-rpc` and `POST /user-rpc`.

Implication: HTTP route QPS alone will under-explain system load. Gather evidence supports an action-level metric layer keyed by `rpc` + `action`.

## TEL-1 evidence: live agent count measurement points

### Runtime registry is the core live-agent source

Facts:

- `src/daemon/registry.odin` defines `Agent_Record` with `connected`, `has_ws`, `last_seen_unix_ms`, `startup_status`, `activity_status`, `provider_profile`, `provider_tier`, `project_id`, `run_dir`, `tmux_pane`, `pid`, `exec_state`, and `blocked_reason`.
- `registry_register` creates/updates in-memory records and marks agents connected at registration time.
- `registry_set_ws`, `registry_clear_ws`, `registry_clear_ws_if_socket`, and `registry_mark_ws_stale` maintain WebSocket liveness.
- `registry_heartbeat` updates `connected=true` and `last_seen_unix_ms` and persists last-seen to auth DB.
- `registry_agent_live` returns true only when the agent is `connected`, has a WebSocket, has `startup_status == "ready"`, and has a fresh heartbeat under `DUPLICATE_HEARTBEAT_FRESH_MS` (15s).
- `registry_list_json` exposes `/clients`/agent status fields including connected, has_ws, last_seen, startup_status, activity_status, provider profile/tier, and project id.

### Agent runtime tracker records lifecycle transitions

Facts:

- `src/daemon/agent_runtime_tracker.odin` observes registration, WebSocket connect/disconnect, heartbeat, startup report, `start_success`, stop requests, stop completion, startup timeout, and heartbeat timeout.
- It emits lifecycle events via `agent_lifecycle_emit` and log lines such as `AGENT_TRACKER ... event=ws_connected`, `event=heartbeat`, `event=start_success`, and `event=disconnected`.
- `agent_runtime_tracker_apply_heartbeat_timeout` marks agents offline after missing heartbeats for 30s.
- `src/daemon/ws.odin` calls `agent_runtime_tracker_observe_ws_connected` after WebSocket upgrade and `agent_runtime_tracker_observe_ws_disconnected` on close/error, and flushes durable task notifications when an agent reconnects.

Useful live-agent metrics:

| Metric candidate | Type | Source | Suggested labels | Notes |
|---|---:|---|---|---|
| `heimdall_agents_live` | gauge | count `registry_agent_live(...)` over registry | `project_id` maybe, `provider_profile`, `provider_tier` | Core live-agent count. Avoid raw agent label unless backend supports it. |
| `heimdall_agents_connected` | gauge | registry `connected && has_ws` | `startup_status`, `provider_profile` | Useful to distinguish WS connections from ready agents. |
| `heimdall_agent_lifecycle_events_total` | counter | runtime tracker callbacks | `event`, `reason`, `startup_status` | Tracks churn/restarts/heartbeat timeouts. |
| `heimdall_agent_heartbeats_total` | counter | heartbeat handler/tracker | `status_class` | Current logging skips heartbeat request telemetry, but aggregate metrics should still count heartbeats. |
| `heimdall_agent_heartbeat_age_seconds` | gauge/histogram | `last_seen_unix_ms` | maybe `provider_profile`, `project_id` | Detect stale agents. |
| `heimdall_agent_starts_total` / `heimdall_agent_stops_total` | counters | `agents_start.odin`, `agents_stop.odin`, runtime tracker | `source`, `status` | Useful for operational debugging. |

Definition needed for synthesis:

- "Live agents" should likely mean **ready, connected WebSocket agents with fresh heartbeat** (`registry_agent_live`) for user-facing count.
- A second gauge should expose less strict "connected wrappers" (`connected && has_ws`) because it explains reconnection and startup states.

## TEL-1 evidence: inter-agent / message-volume measurement points

Heimdall has multiple message-like channels. The final design should not collapse them into one vague count without dimensions.

### Agent-to-agent/message-provider path

Facts:

- `src/daemon/agent_rpc.odin` handles `send_message` and `fetch_messages` actions.
- `src/daemon/message_service.odin` validates send targets, may emit `Remote_Route_Required`, serializes message provider operations through `message_queue_submit_command`, runs pre-send hooks, stores messages via `mp.send_message`, emits `Message_Stored`, `Messages_Available`, `Message_Send_Failed`, and `Message_Read` events.
- `src/daemon/message_bus.odin` defines event kinds: `New_Message_Requested`, `Message_Stored`, `Messages_Available`, `Message_Read`, `Remote_Route_Required`, and `Message_Send_Failed`; it forwards local events to hub adapter and WebSocket event handling.
- `src/lib/message_provider/memory.odin` is currently an in-memory provider with `MAX_MESSAGES = 200_000`, sequential `msg_N` ids, unread counts, and mark-read support. It has comments noting process-global non-thread-safe state.
- `src/contracts/message_provider.odin` defines message status and delivery receipt shapes (`Pending`, `Sent`, `Delivered`, `Read`, `Failed`; receipt types `Accepted`, `Sent`, `Delivered`, `Read`, `Failed`).

Useful message-provider metrics:

| Metric candidate | Type | Source | Suggested labels |
|---|---:|---|---|
| `heimdall_agent_messages_requested_total` | counter | `Message_Event.New_Message_Requested` | `source`, `target_kind`, `local_or_remote` |
| `heimdall_agent_messages_stored_total` | counter | `Message_Event.Message_Stored` | `provider`, `local_or_remote` |
| `heimdall_agent_messages_available_total` | counter | `Messages_Available` | `delivered_live=true|false` if known |
| `heimdall_agent_message_send_failures_total` | counter | `Message_Send_Failed` | `reason`, `provider` |
| `heimdall_agent_message_reads_total` | counter | `Message_Read` | `source` |
| `heimdall_message_queue_depth` | gauge | `message_queue.odin` `q.count` | none or `queue=message_command` |
| `heimdall_message_provider_count` | gauge | `memory_state.message_count` | `provider=memory` |

Cardinality caution: source/target agent IDs should be structured event dimensions, not metric labels by default.

### User/agent chat path

Facts:

- `src/daemon/user_rpc.odin` `send_to_agent` appends chat messages, fans out user-client chat events, notifies the target agent, and marks delivered when notification succeeds.
- `src/daemon/agent_rpc.odin` `send_to_user` validates/coordinator-routes chain-scoped user contact, creates chat messages, and may create approval records.
- `src/daemon/chat_service.odin` appends agent-to-user messages, fans out chat events, and appends `Delivery_Failed` when there are no active user WebSocket recipients.
- `src/daemon/chat_store.odin` defines chat event kinds: `Message_Appended`, `Delivered_Marked`, `Read_Marked`, and `Delivery_Failed`.
- `src/daemon/message_db_service.odin` persists chat messages in SQLite under `data_dir/chat/messages.db` with `message_id`, `user_id`, `agent_instance_id`, `direction`, `body`, `chain_id`, delivered/failure timestamps, error, created time, interrupt flag, and indexes on user/agent, created time, unread status, and chain.
- Tests include offline delivery semantics, e.g. `tests/test_user_inbox_offline_send.py` expects durable offline `send-to-user` messages and delivery failure metadata; `tests/test_send_to_user_chain_id.py` checks chain-scoped send-to-user behavior and non-coordinator redirects.

Useful chat metrics:

| Metric candidate | Type | Source | Labels |
|---|---:|---|---|
| `heimdall_chat_messages_total` | counter | chat append | `direction=user_to_agent|agent_to_user`, `chain_scoped=true|false`, `interrupt=true|false` |
| `heimdall_chat_delivery_events_total` | counter | `Delivered_Marked`, `Delivery_Failed`, `Read_Marked` | `direction`, `event`, `error_class` |
| `heimdall_chat_unread_messages` | gauge | message DB unread counts | `direction`, maybe `chain_scoped` |
| `heimdall_chat_delivery_latency_seconds` | histogram | created to delivered/read | `direction` |

### Task-notification path

Facts:

- `src/daemon/task_store.odin` defines append-only task event kinds for task creation, comments, status, assignment, participants, votes, nudges, chain creation/status/final summary/archive/evaluation.
- `src/daemon/task_notifications.odin` routes task notifications by status and role, sends to user WebSockets, agent WebSockets, reviewers, coordinator, subscribers, and fallback recipients.
- `task_notify_recipient_delivery` first inserts into durable notification outbox, then attempts `registry_send_ws_text`, marks attempts/delivery, and reports durable queue vs failure.
- `src/daemon/task_notification_outbox.odin` persists pending task notifications in SQLite with recipient, event id, payload, created time, delivered time, attempts, and last-attempt time; pending records replay on reconnect.
- `tests/test_offline_queue_e2e.py` asserts offline nudge notifications are queued and replayed on reconnect. `tests/test_task_notification_recipient_scope.py` verifies role-aware notification routing and fallback behavior.

Useful task/notification metrics:

| Metric candidate | Type | Source | Labels |
|---|---:|---|---|
| `heimdall_task_events_total` | counter | task store append | `kind`, `status` |
| `heimdall_task_notifications_total` | counter | notification routing | `status`, `recipient_role`, `result=live|queued|failed|skipped_self` |
| `heimdall_task_notification_outbox_pending` | gauge | outbox pending query | maybe `recipient_role` only if derivable |
| `heimdall_task_notification_replay_total` | counter | `notification_outbox_replay_pending` | `result` |
| `heimdall_task_review_ready_notifications_total` | counter | `task_notify_all_lgtm_required` | `fallback=required|default_reviewer|coordinator|operator` |

### Hub / future remote route path

Facts:

- `src/daemon/router_adapter.odin` can append message events to a central hub when `hub_enabled` is configured, encrypting payloads and mapping message send/read events to hub records.
- `src/daemon/central_hub_store.odin` keeps in-memory hub records, dedupe keys, ack state, presence records, and record sequence numbers.
- `src/daemon/hub_sync.odin` polls the central hub every 500ms when hub is enabled, applies non-local records, acks local records, and counts applied records locally.

Useful future metrics:

- `heimdall_hub_records_appended_total{kind}`
- `heimdall_hub_poll_records_total{result=applied|ack_local|failed}`
- `heimdall_hub_unacked_records`
- `heimdall_hub_presence_records`

This is relevant to Monarch-like/cloud-scale design because hub records already resemble append-only distributed telemetry/audit events.

## TEL-2 evidence: backend / architecture options

This is a comparison for synthesis, not a final recommendation.

| Option | Grafana-compatible? | Repository fit | Strengths | Weaknesses / risks | Best use here |
|---|---|---|---|---|---|
| Custom OpenMetrics `/metrics` endpoint + Prometheus scrape + Grafana | Yes | High. The daemon already has centralized request/response and state access; no existing telemetry dependency to fight. | Simple local/dev path; counters/gauges/histograms fit QPS/live agents/message counts; Grafana dashboards are standard. | Need implement metric registry/exporter carefully in Odin; cardinality discipline required; metrics are not enough for memory-audit details. | First metrics layer for TEL-1/TEL-2. |
| OpenTelemetry SDK/Collector -> Prometheus/Grafana/Tempo/Loki or vendor | Yes, via collector/exporters | Medium/uncertain. No current OTel dependency; Odin ecosystem support may be limited. | Long-term traces/logs/metrics correlation; backend flexibility; better for distributed hub/future cloud. | More moving parts; custom Odin exporter may still be needed; larger implementation scope. | Design target/future step after basic metrics. |
| StatsD/Graphite-style push metrics | Grafana can query Graphite/StatsD backends | Medium. Counters/timers can be sent over UDP from Odin easily. | Easy increments/timers; no scrape endpoint needed. | Weaker labels, discovery, and dimensional queries; less standard for modern infra; less useful for memory audit. | Possible fallback if OpenMetrics endpoint is hard, but less attractive. |
| SQLite/JSONL structured telemetry events + rollups/export | Grafana only with extra plugin/exporter; not directly native | High. The repo already uses SQLite/event stores for chat, tasks, memory, audits, notification outbox. | Durable local audit trail; good for high-cardinality dimensions like task_id/agent_id/message_id; supports memory audit correlations. | Requires custom rollup/query/export; not ideal for high-frequency QPS alone; dashboards need bridge/exporter. | Essential companion for TEL-3 memory-audit analytics; not a replacement for low-cardinality metrics. |
| Cloud-managed/Monarch-like metrics store (Cloud Monitoring, Mimir, VictoriaMetrics, Thanos, etc.) | Usually yes or Grafana-compatible | Low short-term, useful long-term | Scale, retention, remote aggregation, label discipline; aligns with user's Monarch reference. | Operational overhead and overkill for local-first Heimdall today; still needs instrumentation API. | Long-term backend target if teams run multiple daemons/hubs. |
| Logs-only `[RPC TELEMETRY]` | No, unless shipped to Loki/ELK | Already present | Zero implementation cost; useful during development. | Not queryable enough; includes sensitive params/body; heartbeat skipped; no live gauges. | Keep as debug logs only, not final telemetry architecture. |

### Backend evidence summary

- The repository is local-first, daemon-centered, and already SQLite-heavy. This favors a two-layer design: low-cardinality real-time metrics plus structured durable events/rollups for audits.
- Grafana-compatible metrics are feasible via Prometheus/OpenMetrics even if Grafana itself remains optional.
- OpenTelemetry is appealing for future distributed traces/log correlation but may be oversized until there is an Odin-friendly implementation plan.
- Metrics should be pull/scrape where possible because the daemon already exposes HTTP endpoints and state; push paths are useful for remote hub/cloud later.

## TEL-3 evidence: memory audit / long-term analytics needs

### Existing memory/audit workflows

Facts:

- `src/daemon/memory_auditor_orchestrator.odin` implements `handle_post_task_chain_audit`, which requires memory auditor preferences, validates auditor/reviewer agent instances, accepts target chains or time ranges, prevents duplicate active audits, creates an audit run, and creates an audit task chain in `heimdall-system`.
- The same orchestrator chooses completed/evaluated-good task chains when a time range is requested, then creates a multi-task chain for memory audit discovery, filtering, deep analysis, proposal, and review.
- `src/daemon/audit_db_service.odin` persists `audit_runs` and `audit_memory_actions` with status, target chains JSON, timestamps, failure reason, memory/proposal IDs, and action status.
- `src/daemon/memory_service.odin` handles memory proposal/decision/list/show/history actions, including `source_task_id`, action metadata (`new`, `edit`, `archive`, `rollback`), target team kind/role/project fields, evidence, reason, expected version, and author.
- `src/daemon/memory_db_service.odin` persists `memories` and `memory_events` with memory/proposal ids, target team/role/project, type/title/body/status/reason/evidence/metadata/source_task_id/version/timestamps, and event kind/author/timestamp.
- `src/daemon/task_store.odin` task/chain events contain chain/task IDs, assignees, reviewers, participants, status transitions, comments, votes, final summaries, archive/evaluation status, and timestamps.

### Memory-audit telemetry requirements implied by source

Metrics alone will not answer memory-audit questions because audit workflows need entity-level correlations: chain, task, agent, memory proposal, reviewer, decision, and timestamps. Prometheus-style labels should not carry all of these IDs. Instead, use structured events and periodic rollups.

High-value structured event dimensions:

- `event_type`: task status/comment/vote, memory proposed/approved/rejected/archived, audit run started/completed/failed, chat/message delivery event.
- `chain_id`, `task_id`, `project_id`, `team_id`, `team_kind`.
- `source_agent_instance_id`, `target_agent_instance_id`, `role` (assignee/coordinator/reviewer/subscriber), `provider_profile`, `provider_tier`.
- `memory_id`, `proposal_id`, `memory_action`, `memory_type`, `target_team_kind`, `target_role`, `target_project_id`, `source_task_id`.
- timestamps for created, delivered, read, approved, rejected, completed, archived.
- `result` / `status` / `failure_reason` / `error_class` without raw content.

Example analytics questions this supports:

- Which chains generate the most memory proposals, edits, archives, and rejections?
- What is the latency from task completion to memory proposal, and proposal to approval/rejection?
- Which agent roles or provider tiers produce memory that is later edited/archived/rejected?
- Do message volume, failed deliveries, or long task review latency correlate with memory churn or bad chain evaluation?
- Which projects/roles have stale or under-reviewed memory?

Privacy boundary:

- Do not export prompt bodies, chat bodies, message bodies, memory bodies, or raw task comments as metrics.
- Structured audit events may reference IDs and metadata/evidence hashes, but content capture should require a separate explicit data-governance decision.
- Existing `message_db_service` and `memory_db_service` persist content by product need; telemetry should avoid copying content into additional systems by default.

## Metric inventory for synthesis

Minimum TEL-1 metrics to implement/validate:

1. QPS / request health
   - `heimdall_http_requests_total{method,route,status_class}`
   - `heimdall_http_request_duration_seconds{method,route,status_class}`
   - `heimdall_rpc_actions_total{rpc,action,status_class}`
   - `heimdall_rpc_action_duration_seconds{rpc,action,status_class}`
2. Live agents
   - `heimdall_agents_live{provider_profile,provider_tier,project_id?}`
   - `heimdall_agents_connected{startup_status,provider_profile}`
   - `heimdall_agent_lifecycle_events_total{event,reason}`
   - `heimdall_agent_heartbeat_age_seconds` or stale count gauge
3. Message volume
   - `heimdall_agent_messages_stored_total{provider,local_or_remote}`
   - `heimdall_agent_message_send_failures_total{reason}`
   - `heimdall_chat_messages_total{direction,chain_scoped,interrupt}`
   - `heimdall_chat_delivery_events_total{direction,event,error_class}`
   - `heimdall_task_notifications_total{status,recipient_role,result}`
   - `heimdall_task_notification_outbox_pending`
4. Memory/audit rollups
   - `heimdall_memory_proposals_total{action,type,target_team_kind,target_role,result}`
   - `heimdall_memory_decision_latency_seconds{action,type,result}`
   - `heimdall_audit_runs_total{status,time_range}`
   - `heimdall_audit_target_chains_total{time_range}`

## Instrumentation placement summary

| Concern | Source placement | Reason |
|---|---|---|
| HTTP QPS/latency/status | `src/daemon/server.odin` + `src/daemon/http.odin` | One place wraps all HTTP/JSON responses and already has timing. |
| RPC action QPS | `src/daemon/agent_rpc.odin`, `src/daemon/user_rpc.odin` | `/agent-rpc` and `/user-rpc` multiplex many product actions. |
| Live agent gauges | `src/daemon/registry.odin`, `src/daemon/agent_runtime_tracker.odin` | Registry is live state; tracker records transitions/timeouts. |
| WebSocket connect/disconnect | `src/daemon/ws.odin`, `src/daemon/user_ws.odin` | Direct observation of agent/user WS sessions. |
| Agent message volume | `src/daemon/message_service.odin`, `src/daemon/message_bus.odin` | Existing event bus captures requested/stored/available/read/failure. |
| Chat/user-agent message volume | `src/daemon/chat_store.odin`, `src/daemon/chat_service.odin`, `src/daemon/user_rpc.odin`, `src/daemon/agent_rpc.odin` | Durable chat events include appended/delivered/read/failed states. |
| Task notification volume | `src/daemon/task_notifications.odin`, `src/daemon/task_notification_outbox.odin` | Captures live delivery, durable queue, replay, fallback. |
| Memory audit analytics | `src/daemon/memory_service.odin`, `src/daemon/memory_db_service.odin`, `src/daemon/audit_db_service.odin`, `src/daemon/task_store.odin` | Entity-level correlations live in memory/audit/task stores. |
| Hub/cloud future | `src/daemon/router_adapter.odin`, `src/daemon/central_hub_store.odin`, `src/daemon/hub_sync.odin` | Existing append/poll/ack/presence model resembles remote telemetry flow. |

## Known gaps / open questions for synthesis

- Whether Odin has a mature Prometheus/OpenTelemetry library was not proven from local source. Repository evidence shows no existing dependency. Synthesis should decide whether to implement a tiny OpenMetrics exporter manually or introduce a dependency.
- No load tests or runtime metric samples were produced in this gather task; that belongs to later implementation validation, not this research artifact.
- The exact definition of "messages between agents" must choose between narrow `agent_rpc.send_message` traffic and broader task/chat/notification traffic. Evidence favors reporting separate counters by channel rather than one ambiguous global number.
- Existing `[RPC TELEMETRY]` logs include params/body snippets; any production telemetry work should sanitize or avoid content export.
- The in-memory message provider and hub store are not durable long-term metrics stores. They are useful instrumentation/event sources, not final analytics storage.

## Reviewer checklist for TEL-5

Reviewer should verify this file exists and is non-empty at:

- `reports/telemetry-gather-evidence.md`

Reviewer should reject Gather if:

- The file is missing or not under `reports/`.
- The completion comment does not list this path.
- The evidence does not cite concrete repository files for QPS, live agent count, message counts, backend comparison, and memory-audit future use.
