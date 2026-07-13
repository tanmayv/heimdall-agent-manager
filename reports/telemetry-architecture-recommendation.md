# Telemetry Architecture Recommendation for Heimdall Agent Manager

Task: `task-19f594d6f25`  
Chain: `chain-19f594d6ea8`  
Author: `researcher-1@heimdall-agent-manager-chain-19f594d6ea8`

## Executive summary

Heimdall should add telemetry as a **two-plane architecture**:

1. **Metrics plane:** a small in-daemon metrics registry exposed as a Prometheus/OpenMetrics-compatible `GET /metrics` endpoint, scrapeable by Prometheus and visualizable in Grafana. This should track low-cardinality operational metrics: QPS, request/action latency, live/connected agents, message counters, delivery failures, queue depth, and audit rollup counters.
2. **Audit/event analytics plane:** a privacy-safe structured telemetry event/rollup layer backed by Heimdall's existing SQLite/event-store style. This should retain high-cardinality dimensions needed for memory-audit analytics (task IDs, chain IDs, memory IDs, proposal IDs, agent IDs) without pushing them into Prometheus labels.

This approach makes Grafana useful but optional: Grafana can read Prometheus/OpenMetrics metrics immediately, while future deeper memory-audit dashboards can read rollups exported from SQLite or later move to OpenTelemetry Collector / Mimir / VictoriaMetrics / cloud-managed Monitoring as Heimdall scales.

Primary evidence artifact: [`reports/telemetry-gather-evidence.md`](./telemetry-gather-evidence.md).

## Requirements coverage

- **TEL-1** — Covers how to track QPS, live agent count, and number of messages between agents.
- **TEL-2** — Recommends a concrete telemetry architecture and compares alternatives, including Grafana-compatible options.
- **TEL-3** — Explains how telemetry can support memory-audit workflows and longer-term analytics.
- **TEL-4** — Final report is persisted under `reports/` at `reports/telemetry-architecture-recommendation.md`.
- **TEL-5** — Gather artifact is persisted and linked from this report: `reports/telemetry-gather-evidence.md`.
- **TEL-7** — Core synthesis/report authored by researcher, not coordinator.

## Source-grounded findings

### Current observability

Heimdall already has useful but insufficient request logging:

- `src/daemon/server.odin` creates thread-local `Request_Telemetry` in `handle_client`, covering parsed method/path and start time before dispatch.
- `src/daemon/http.odin` emits `[RPC TELEMETRY]` from `write_response`, including status and latency.

This is the right conceptual hook for request metrics, but it is log-only, includes potentially sensitive params/body snippets, and is not queryable as a metric series.

### QPS and latency measurement points

Recommended instrumentation points:

- HTTP-level request metrics: `src/daemon/server.odin` + `src/daemon/http.odin`.
- Agent RPC action metrics: `src/daemon/agent_rpc.odin`.
- User RPC action metrics: `src/daemon/user_rpc.odin`.

Key reason: many important operations share `POST /agent-rpc` and `POST /user-rpc`; route-level QPS alone is too coarse. Heimdall needs both HTTP route metrics and RPC action metrics.

### Live agent count measurement points

Recommended source of truth:

- User-facing **live agent count** should be based on `registry_agent_live` in `src/daemon/registry.odin`: connected, active WebSocket, ready startup status, and fresh heartbeat.
- A separate connected-wrapper gauge should count `connected && has_ws` for startup/reconnect diagnosis.
- Lifecycle events should come from `src/daemon/agent_runtime_tracker.odin`, which observes register, WebSocket connect/disconnect, heartbeat, start-success, stop, startup timeout, and heartbeat timeout.

### Message-volume measurement points

Do not define “messages between agents” as one flat counter. Heimdall has multiple message-like channels that should be counted separately:

1. **Agent-to-agent message provider path** — `src/daemon/message_service.odin`, `src/daemon/message_bus.odin`, `src/lib/message_provider/memory.odin`.
2. **User-agent chat path** — `src/daemon/user_rpc.odin`, `src/daemon/agent_rpc.odin`, `src/daemon/chat_service.odin`, `src/daemon/chat_store.odin`, `src/daemon/message_db_service.odin`.
3. **Task notification path** — `src/daemon/task_store.odin`, `src/daemon/task_notifications.odin`, `src/daemon/task_notification_outbox.odin`.
4. **Future hub/remote path** — `src/daemon/router_adapter.odin`, `src/daemon/central_hub_store.odin`, `src/daemon/hub_sync.odin`.

The dashboard can show a top-level “message volume” rollup, but the underlying metrics should preserve channel/type/result dimensions.

## Recommended architecture

### Layer 1: In-daemon metrics registry

Add a minimal metrics module inside the Odin daemon, for example `src/daemon/telemetry_metrics.odin`, with thread-safe counters, gauges, and coarse histograms.

Capabilities:

- Counter increment by metric name + bounded label set.
- Gauge set/add/subtract.
- Histogram observation with fixed buckets for request/action latencies and delivery latencies.
- OpenMetrics/Prometheus text rendering.
- Route normalization helpers so raw IDs do not become label values.

Expose via:

- `GET /metrics` — OpenMetrics/Prometheus text format.
- Optionally `GET /metrics.json` later for local UI debugging, but not required initially.

Why custom first:

- Repository search found no existing Prometheus/OpenTelemetry dependency.
- Odin ecosystem support for full OpenTelemetry SDK remains uncertain.
- A simple exporter is enough for Heimdall’s immediate QPS/live-agent/message counters and can be replaced or bridged later.

### Layer 2: Prometheus + Grafana-compatible deployment

Recommended default local/dev deployment:

- Heimdall daemon exposes `/metrics` on the existing daemon HTTP port.
- Prometheus scrapes `http://127.0.0.1:<daemon-port>/metrics`.
- Grafana uses Prometheus as a datasource.
- Initial dashboards:
  - Request QPS and error rate.
  - RPC action rate and p95 latency.
  - Live agents / connected wrappers / stale agents.
  - Message volume by channel.
  - Delivery failures and task notification outbox depth.
  - Memory/audit proposal and decision rollups.

Grafana remains optional. Users who do not want Grafana can scrape with Prometheus, curl `/metrics`, or consume future local UI summaries.

### Layer 3: Structured telemetry events and rollups for audits

Add a separate structured telemetry event/rollup layer, preferably SQLite-backed and content-free by default.

Purpose:

- Preserve high-cardinality dimensions required for audit analytics without polluting metrics labels.
- Support future memory-audit workflows over chain/task/agent/memory/proposal histories.
- Provide durable local rollups that can later be exported to cloud systems.

Suggested storage:

- `data_dir/telemetry/telemetry.db`
- Tables such as:
  - `telemetry_events(event_id, event_type, entity_type, entity_id, chain_id, task_id, project_id, team_id, source_agent_instance_id, target_agent_instance_id, role, result, error_class, created_unix_ms, metadata_json)`
  - `telemetry_rollups(window_start_unix_ms, window_seconds, metric_name, dimensions_json, value)`

Content policy:

- Store IDs, types, statuses, timestamps, result classes, and safe metadata.
- Do **not** store prompt bodies, chat bodies, message bodies, memory bodies, or raw task comments in telemetry events.
- If content-level audit is later required, make it a separate explicit data-governance feature.

### Layer 4: Future OpenTelemetry / Monarch-like backend

Use the first implementation to establish stable metric names and structured event semantics. Then optionally add:

- OpenTelemetry Collector export for metrics/logs/traces.
- Grafana Mimir, VictoriaMetrics, Thanos, or cloud Monitoring for long retention and multi-daemon aggregation.
- Trace/span correlation for cross-daemon hub flows and long-running task chains.

This matches the user’s “Google Cloud Monarch” direction without prematurely requiring a cloud backend for local Heimdall.

## Metric inventory

### QPS / request health

| Metric | Type | Labels | Source |
|---|---|---|---|
| `heimdall_http_requests_total` | counter | `method`, `route`, `status_class` | `server.odin` / `http.odin` |
| `heimdall_http_request_duration_seconds` | histogram | `method`, `route`, `status_class` | `http.odin` |
| `heimdall_http_in_flight_requests` | gauge | optional `method` | `server.odin` |
| `heimdall_rpc_actions_total` | counter | `rpc`, `action`, `status_class` | `agent_rpc.odin`, `user_rpc.odin` |
| `heimdall_rpc_action_duration_seconds` | histogram | `rpc`, `action`, `status_class` | `agent_rpc.odin`, `user_rpc.odin` |

### Live agents

| Metric | Type | Labels | Source |
|---|---|---|---|
| `heimdall_agents_live` | gauge | `provider_profile`, `provider_tier`, optional bounded `project_id` | `registry.odin` |
| `heimdall_agents_connected` | gauge | `startup_status`, `provider_profile` | `registry.odin` |
| `heimdall_agent_lifecycle_events_total` | counter | `event`, `reason` | `agent_runtime_tracker.odin` |
| `heimdall_agent_heartbeats_total` | counter | `status_class` | heartbeat handler / runtime tracker |
| `heimdall_agent_stale_total` | gauge | `reason` | heartbeat timeout logic |
| `heimdall_agent_starts_total` | counter | `source`, `status` | `agents_start.odin`, runtime tracker |
| `heimdall_agent_stops_total` | counter | `source`, `status` | `agents_stop.odin`, runtime tracker |

### Message volume

| Metric | Type | Labels | Source |
|---|---|---|---|
| `heimdall_agent_messages_requested_total` | counter | `local_or_remote` | `message_service.odin` / `message_bus.odin` |
| `heimdall_agent_messages_stored_total` | counter | `provider`, `local_or_remote` | `message_bus.odin` |
| `heimdall_agent_message_send_failures_total` | counter | `reason`, `provider` | `message_service.odin` |
| `heimdall_agent_message_reads_total` | counter | `source` | `message_service.odin` |
| `heimdall_message_queue_depth` | gauge | `queue` | `message_queue.odin` |
| `heimdall_chat_messages_total` | counter | `direction`, `chain_scoped`, `interrupt` | `chat_store.odin` / RPC handlers |
| `heimdall_chat_delivery_events_total` | counter | `direction`, `event`, `error_class` | `chat_store.odin` |
| `heimdall_task_notifications_total` | counter | `status`, `recipient_role`, `result` | `task_notifications.odin` |
| `heimdall_task_notification_outbox_pending` | gauge | none initially | `task_notification_outbox.odin` |
| `heimdall_task_notification_replay_total` | counter | `result` | `task_notification_outbox.odin` |
| `heimdall_hub_records_appended_total` | counter | `kind` | `router_adapter.odin`, `central_hub_store.odin` |
| `heimdall_hub_poll_records_total` | counter | `result` | `hub_sync.odin` |

### Memory audit / analytics rollups

| Metric | Type | Labels | Source |
|---|---|---|---|
| `heimdall_memory_proposals_total` | counter | `action`, `type`, `target_team_kind`, `target_role`, `result` | `memory_service.odin` |
| `heimdall_memory_decisions_total` | counter | `action`, `type`, `decision` | `memory_service.odin` |
| `heimdall_memory_decision_latency_seconds` | histogram | `action`, `type`, `decision` | `memory_db_service.odin` + service timestamps |
| `heimdall_audit_runs_total` | counter | `status`, `time_range` | `audit_db_service.odin`, `memory_auditor_orchestrator.odin` |
| `heimdall_audit_target_chains_total` | counter/gauge | `time_range` | `memory_auditor_orchestrator.odin` |

## Label/cardinality policy

Prometheus/OpenMetrics labels should be bounded and low-cardinality.

Use as labels:

- `method`, normalized `route`, `status_class`.
- `rpc`, `action`.
- `event`, `result`, `reason` where values are enums or normalized classes.
- `direction`, `channel`, `provider`, `provider_tier`, `startup_status`.
- `team_kind`, `target_role`, `memory_type`, `memory_action`.

Avoid as metric labels by default:

- `message_id`, `memory_id`, `proposal_id`, `task_id`, `chain_id`, raw `agent_instance_id`, raw `client_instance_id`, raw path segments, raw errors, prompt text, message bodies, memory bodies.

Put high-cardinality fields into structured telemetry events / SQLite rollups instead.

## Memory-audit future use

The memory-audit system already models audit runs and memory actions:

- `memory_auditor_orchestrator.odin` creates audit chains from selected completed/evaluated-good task chains.
- `audit_db_service.odin` stores audit runs and memory actions.
- `memory_service.odin` and `memory_db_service.odin` store memory proposals, approvals, rejections, archives, metadata, target team/role/project, source task, evidence, and timestamps.
- `task_store.odin` stores chain/task lifecycle events, comments, votes, status, final summary, and evaluation.

Telemetry can support future audits by correlating:

- Task outcomes with message volume and delivery failures.
- Review latency with memory proposal quality or rejection rates.
- Agent/provider tier with memory churn.
- Chains with high communication volume and later memory edits/archives.
- Audit run duration/failures with target chain count and event volume.

Recommended audit/event dimensions:

- `event_type`, `entity_type`, `entity_id`.
- `chain_id`, `task_id`, `project_id`, `team_id`, `team_kind`.
- `source_agent_instance_id`, `target_agent_instance_id`, `role`, `provider_profile`, `provider_tier`.
- `memory_id`, `proposal_id`, `memory_action`, `memory_type`, `target_team_kind`, `target_role`, `target_project_id`, `source_task_id`.
- `status`, `result`, `decision`, `failure_reason`, `error_class`.
- `created_unix_ms`, `delivered_unix_ms`, `read_unix_ms`, `approved_unix_ms`, `completed_unix_ms`.

Do not duplicate raw content into telemetry. Keep raw memory/chat/task content in the existing product stores governed by existing access rules.

## Alternative comparison

| Option | Recommendation | Why |
|---|---|---|
| Logs-only `[RPC TELEMETRY]` | Reject as final architecture | Already present but not queryable, not dashboard-friendly, and too content-heavy. Keep only as debug logging after sanitization. |
| StatsD/Graphite | Not preferred | Simple push counters, but weaker labels/discovery and less aligned with current Grafana/Prometheus ecosystem. |
| Prometheus/OpenMetrics + Grafana | Recommended first metrics plane | Minimal integration, strong fit for QPS/live/message counters, Grafana-compatible, local-first. |
| OpenTelemetry Collector | Recommended future phase | Useful for trace/log/metric correlation and backend portability, but likely too much for first implementation given unknown Odin support. |
| SQLite structured events/rollups | Recommended audit plane | Best fit for high-cardinality memory-audit analytics and Heimdall’s existing durable local stores. |
| Cloud/Monarch-like managed telemetry | Future scaling target | Good long-term mental model for cardinality/retention/multi-daemon aggregation, but overkill as initial local implementation. |

## Implementation roadmap

### Phase 0 — Safety and definitions

- Define route normalization rules.
- Define message-channel taxonomy: `agent_message`, `chat`, `task_notification`, `hub`.
- Define privacy policy: metrics and structured telemetry must not export raw prompt/message/memory bodies.
- Keep existing `[RPC TELEMETRY]` logs but plan to sanitize params/body output or gate it behind debug config.

### Phase 1 — Metrics core and `/metrics`

- Add daemon metrics registry for counters/gauges/histograms.
- Add OpenMetrics text renderer.
- Add `GET /metrics` route.
- Add tests for metric rendering, route normalization, and label escaping.
- Add basic daemon self metrics: uptime, build/info gauge if available, request counts.

### Phase 2 — QPS and live-agent metrics

- Instrument `handle_client` / `write_response` for HTTP QPS/latency/status.
- Instrument `handle_agent_rpc` and `handle_user_rpc` for action counts/latency/status.
- Add registry snapshot gauges for live/connected/stale agents.
- Add lifecycle counters in `agent_runtime_tracker.odin`.

### Phase 3 — Message and delivery metrics

- Instrument message bus events for agent messages.
- Instrument chat append/delivered/read/failed paths.
- Instrument task notification delivery results and outbox pending/replay.
- Instrument hub append/poll/ack metrics for future distributed flows.

### Phase 4 — Structured telemetry events and rollups

- Add `telemetry.db` with content-free structured events.
- Emit events for memory proposals/decisions, task lifecycle, message delivery, and audit runs.
- Add daily/hourly rollups for memory audit questions.
- Add CLI/API to query telemetry rollups for future UI/reporting.

### Phase 5 — Grafana assets and optional cloud path

- Add example `reports/` or `docs/` dashboard JSON for Grafana.
- Add sample Prometheus scrape config.
- Document local setup.
- Evaluate OpenTelemetry Collector export once metric names stabilize.

## Validation strategy for future implementation

- Unit tests for metric label escaping, route normalization, and OpenMetrics rendering.
- API test that `GET /metrics` returns expected counters after known `/health`, `/agent-rpc`, and `/user-rpc` calls.
- Runtime test that live-agent gauges change on register, WebSocket connect, heartbeat timeout, and stop.
- Message tests that counters move for agent message send/fetch/read, chat sent/delivered/failed, and offline task notification replay.
- Privacy test that known body strings do not appear in `/metrics` output or structured telemetry rows.
- Memory-audit rollup test that a synthetic memory proposal/approval creates safe event dimensions and decision-latency rollup.

## Known gaps and risks

- Odin library support for full OpenTelemetry or Prometheus SDK was not established from repository evidence. A custom OpenMetrics endpoint is lower-risk initially.
- Thread safety matters: daemon handlers run concurrently and some current providers/stores are process-global. Metrics registry updates must be safe under concurrent requests.
- Cardinality discipline is critical. Agent/task/message IDs are valuable for audit events but dangerous as Prometheus labels.
- Existing request logs include params and short response bodies. Production telemetry should avoid exporting that content and consider sanitizing logs.
- Grafana is useful for dashboards, but memory-audit analytics require structured event queries/rollups beyond simple time-series graphs.

## Final recommendation

Implement **Prometheus/OpenMetrics + optional Grafana** as the first operational telemetry layer, backed by a **SQLite structured telemetry/rollup plane** for memory-audit analytics.

This gives Heimdall a practical short-term path to track:

- QPS and RPC action rates.
- Live and connected agent counts.
- Message volume across agent messages, user-agent chat, task notifications, and hub flows.

It also preserves a scalable path toward:

- Future memory-audit analytics.
- OpenTelemetry Collector integration.
- Cloud/Monarch-like multi-daemon observability.

The architecture should be intentionally privacy-safe, local-first, and cardinality-aware from the beginning.

## Artifact references

- Final report: `reports/telemetry-architecture-recommendation.md`
- Gather evidence: `reports/telemetry-gather-evidence.md`
