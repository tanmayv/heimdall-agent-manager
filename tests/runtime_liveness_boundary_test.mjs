import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('..', import.meta.url));

function* productionOdin(dir) {
  for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
    const name = join(dir, entry.name);
    if (entry.isDirectory()) yield* productionOdin(name);
    else if (entry.name.endsWith('.odin') && !entry.name.endsWith('_test.odin')) yield name;
  }
}

test('Bridge runtime transitions use the single logging and reason writer', () => {
  const violations = [];
  for (const file of productionOdin('src/bridge')) {
    let proc = '';
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, index) => {
      const code = line.trim();
      if (code.startsWith('//')) return;
      proc = code.match(/^(\w+)\s*::\s*proc\(/)?.[1] ?? proc;
      // The field write or a tuple assignment beginning with that field.
      if (!/\.runtime_status\s*(?:=[^=]|,\s*\w+.*=[^=])/.test(code)) return;
      if (basename(file) === 'hub_runtime_client.odin' &&
          proc === 'bridge_runtime_set_status_with_source_locked') return;
      violations.push(file + ':' + (index + 1));
    });
  }
  assert.deepEqual(violations, [], 'status writes outside the Bridge transition writer');
});

test('Production Hub paths do not infer exits from missing roster rows or elapsed time', () => {
  const violations = [];
  const retired = /\b(reconcile_bridge_heartbeat|runtime_reconcile_digest|reap_stale_instances)\s*\(/;
  for (const file of productionOdin('src/hub')) {
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, index) => {
      if (!line.trimStart().startsWith('//') && retired.test(line)) violations.push(file + ':' + (index + 1));
    });
  }
  assert.deepEqual(violations, [], 'legacy negative-evidence path reintroduced');
});

// Production reads are audited by file and procedure, not by a blanket
// directory exemption. Numbers pin the currently reviewed projection reads.
const projectionSites = [
  // Cache encoding, decoding, persistence and API/pane rendering.
  ['hub/domain/agent.odin', 'agent_instance_destroy:1 agent_instance_clone:1'],
  ['hub/domain/chain_token_usage.odin', 'chain_token_instance_from:2'],
  ['hub/domain/event_subscription.odin', 'event_notice_target_destroy:1'],
  ['hub/repository/sqlite/agent_repo_sqlite.odin', 'agent_delete_support_sqlite:2 bind_instance:1'],
  ['hub/repository/sqlite/event_subscription_repo.odin', 'subscription_notice_target:1 subscription_snapshot_query:2'],
  ['hub/repository/sqlite/search_fts.odin', ':1'],
  ['hub/service/eventinbox/notifications.odin', 'notify_pending:1'], // Cache fingerprint only.
  ['hub/service/mcp/catalog_read.odin', 'catalog_instance_record:1'],
  ['hub/service/mcp/runtime.odin', 'runtime_revision:1'],
  ['hub/transport/http/agent_action_handlers.odin', 'agent_action_context_handler:1'],
  ['hub/transport/http/agent_handlers.odin', 'get_agent_instance_pane_handler:2 write_agent_instance_json:1'],
  ['hub/transport/http/agent_instance_handlers.odin', 'agent_instance_stream_handler:2'],
  ['hub/transport/http/chain_token_usage_handlers.odin', 'write_chain_token_instance_json:1'],
  ['hub/transport/http/content_handlers.odin', 'write_chat_json_with_runtime:1 chat_instance_runtime_active:1'],
  ['hub/transport/http/resource_events.odin', 'instance_changed_summary_json:1'],
  ['hub/transport/http/taskchain_handlers.odin', 'make_chain_member_wire:1 list_chain_fleets_handler:1 upsert_chain_fleet_handler:1 build_agents_live_tree:3 agents_live_handler:1'],
  ['hub/service/taskv2/dispatch.odin', 'agent_not_running_in_uow:3'], // Formats already-decided blocks.
  ['hub/service/taskv2/matcher.odin', 'instance_failure_reason:1'], // Error text only.
  ['bridge/context_window.odin', 'ctxwin_instance_live:1'], // Settings overlay, not process ownership.
  ['bridge/wrapper_endpoint.odin', 'bridge_local_handle_agent_method:1'],

  // Projection producers and lifecycle acknowledgements. Status is never a
  // substitute for the generation/PID proof on the path to act on a lease.
  ['hub/service/agent/agent_service.odin', 'list_instances_filtered:3 active_instance_count_for_bridge:1 active_instance_count_for_agent:1 mark_instance_start_success_locked:1 stop_instance:1 stop_instance_confirmed:2 get_instance_pane:2 apply_bridge_status_report:11 log_runtime_terminal_transition:2 reconcile_bridge_heartbeat:4 mark_bridge_instances_unreachable:4 reap_stale_instances:4'],
  ['hub/service/agent/instance_failure.odin', 'failed_instance_disposition:2 apply_stop_command_result:3'], // Legacy test helper and failed-stop projection restoration.
  ['hub/service/agent/instance_probe.odin', 'agent_liveness:1 apply_observed_alive_projection:2 apply_observed_absent_projection:2'],
  ['hub/service/agent/start_begin.odin', 'start_begin_impl:1'],
  ['hub/service/agent/task_stop.odin', 'apply_task_stop_receipt:2'],
  ['hub/service/bridge_runtime/runtime_protocol.odin', 'runtime_reconcile_digest:3 runtime_instance_status:1'],
  ['hub/service/project/runtime_metrics.odin', 'runtime_registry_collect:1'],
  ['hub/service/project/runtime_registry.odin', 'bridge_runtime_connection_release:1 bridge_runtime_connection_retire:1 runtime_instance_remove_locked:1 bridge_runtime_instance_apply:5 bridge_runtime_instance_get:1 bridge_runtime_instance_retire:3'],
  ['hub/transport/http/bridge_handlers.odin', 'bridge_ws_process_frame:1 bridge_apply_validated_status:1'],
  ['hub/transport/http/bridge_heartbeat_inventory.odin', 'heartbeat_inventory_reports:1 bridge_heartbeat_inventory_active_ids:1 bridge_apply_heartbeat_reports:3'],
  ['bridge/agent_reconcile.odin', 'bridge_agent_instance_reconcile_now:1'], // Already verified an alive roster entry, heals the cache.
  ['bridge/hub_runtime_client.odin', 'bridge_runtime_record_failure:1 bridge_runtime_status_snapshot:1 bridge_runtime_note_activity_signal:3 bridge_runtime_set_status_with_source_locked:3 bridge_runtime_touch_liveness:2 bridge_instance_status_json:1 bridge_runtime_write_instance_error:1 bridge_hub_heartbeat_json_shaped:1 bridge_heartbeat_frame_json:3 bridge_runtime_expire_stale_locked:2 bridge_runtime_active_agent_count:1 bridge_runtime_drain_status_pushes:1'],
  ['bridge/startup_readiness.odin', 'bridge_startup_fallback_due:1 bridge_startup_confirm_spawned:1'], // Startup UI state, after token/process checks.

  // These non-lease protocols still fold their own receipt/delivery state.
  ['hub/app/mcp_runtime.odin', 'mcp_runtime_store:2 mcp_runtime_poll:1'], // Delegated-operation receipt projection only.
  ['hub/service/agent/instance_reconfiguration.odin', 'reconcile_instance_reconfigurations:2 force_stop_instance_reconfiguration_locked:1'], // Native operation progress and its idempotent retry.
  ['hub/service/content/title_nudge.odin', 'title_nudge_target_is_live:1'], // Best-effort, display-only title suggestion.
  ['bridge/auto_update.odin', 'bridge_auto_update_quiet_with_host:1'], // An active process still blocks via independently checked daemon roster.
  ['hub/transport/http/stream_handlers.odin', 'stream_placement_valid:1'], // TODO(liveness-followup): stream subscription authorization only.

  // Disable and delete can cancel a launch before the child exists. Requiring
  // Alive would miss those starts. The bot view is presentation only.
  ['hub/service/bots/disable.odin', 'bots_on_experiment_disabled:1'],
  ['hub/service/bots/service.odin', 'bots_view_json:2 bots_delete:1'],
  // Recovery's "stopping" suppresses duplicate commands while a receipt is
  // pending. Idle retires inactive launches (including startup/blocked) via
  // the async bot_idle stop/reopen protocol. It does not infer a process exit.
  ['hub/service/bots/supervisor.odin', 'bots_resolve_blocking_locked:1 bots_idle_stop:1'],
  // Bot worker: prefer the warm candidate or await a launch already underway,
  // surface launch errors/blocks, and require the startup acknowledgement.
  // The reply watch's terminal projections end a delivery attempt only. An
  // actual relaunch goes back through Hub Start/reconfigure admission.
  ['bridge/bot_delivery.odin', 'bridge_bot_run:3 bridge_bot_wait_ready:2 bridge_bot_ready:1'],
  // Viewer demand can attach before spawn, and terminal projections retire
  // subscriptions. Neither route admission nor the Bridge's hook-generation
  // filter claims a PID exited. Both also run on reader/mutex paths.
  ['hub/service/agent/tool_stream.odin', 'tool_stream_producer_expected:1'],
  ['bridge/tool_activity_live.odin', 'bridge_tool_live_instance:1'],
];

test('Hub and Bridge runtime projection reads stay in audited boundary sites', () => {
  const allowed = new Map();
  for (const [file, entries] of projectionSites) {
    for (const spec of entries.split(' ')) {
      const [proc, count] = spec.split(':');
      allowed.set(join('src', file) + '#' + proc, Number(count));
    }
  }
  const violations = [];
  for (const file of [...productionOdin('src/hub'), ...productionOdin('src/bridge')]) {
    let proc = '';
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, index) => {
      const code = line.trim();
      if (code.startsWith('//')) return;
      proc = code.match(/^(\w+)\s*::\s*proc\(/)?.[1] ?? proc;
      if (!/\.runtime_status\b/.test(code)) return;
      const key = file + '#' + proc;
      const remaining = allowed.get(key) ?? 0;
      if (remaining <= 0) violations.push(file + ':' + (index + 1) + ' ' + proc);
      else allowed.set(key, remaining - 1);
    });
  }
  for (const [key, remaining] of allowed) {
    if (remaining !== 0) violations.push(key + ' has ' + remaining + ' stale exemptions');
  }
  assert.deepEqual(violations, [], 'runtime projection read outside its audited boundary');
});
