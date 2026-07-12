#!/usr/bin/env python3
"""Regression checks for daemon-side agent runtime tracker single-flight wiring."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TRACKER = (ROOT / "src/daemon/agent_runtime_tracker.odin").read_text()
SCHED = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text()
AGENTS = (ROOT / "src/daemon/agents_start.odin").read_text()
LIFECYCLE = (ROOT / "src/daemon/lifecycle.odin").read_text()
REGISTRY = (ROOT / "src/daemon/registry.odin").read_text()
WS = (ROOT / "src/daemon/ws.odin").read_text()
SERVER = (ROOT / "src/daemon/server.odin").read_text()
TASK_SERVICE = (ROOT / "src/daemon/task_service.odin").read_text()
TASK_HTTP = (ROOT / "src/daemon/task_http.odin").read_text()
STORE = (ROOT / "src/daemon/agent_store.odin").read_text()
TEST_RUN = (ROOT / "src/daemon/test_run.odin").read_text()
TEAM_HTTP = (ROOT / "src/daemon/team_http.odin").read_text()
MEMORY_AUDITOR = (ROOT / "src/daemon/memory_auditor_orchestrator.odin").read_text()


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"FAILED: {msg}")
        sys.exit(1)


def main() -> None:
    require('Agent_Runtime_State :: enum' in TRACKER, 'tracker state enum missing')
    for state in ['Not_Running', 'Launching', 'Running']:
        require(state in TRACKER, f'tracker missing {state} state')
    require('AGENT_TRACKER_LAUNCH_TIMEOUT_MS' in TRACKER, 'launch timeout missing')
    require('agent_runtime_tracker_try_begin_launch :: proc' in TRACKER, 'single-flight launch API missing')
    require('agent_runtime_tracker_register_allowed :: proc' in TRACKER, 'register generation gate missing')
    require('agent_runtime_tracker_note_stale_registry_unlocked' in TRACKER, 'stale runtime cleanup missing')
    require('connected && ag.has_ws && fresh && ag.startup_status == "ready"' in TRACKER, 'running must require WS + fresh heartbeat + ready')

    require('agent_runtime_tracker_init();' in SERVER, 'tracker must initialize during daemon startup')
    require('agent_runtime_tracker_try_begin_launch(agent_instance_id, agent_token, reason, task_id, now)' in SCHED, 'autoscaler must route launch through tracker')
    require('agent_runtime_tracker_try_begin_launch(agent_instance_id, agent_token, "manual_agent_start"' in AGENTS, 'manual start must route through tracker')
    require('task_autoscaler_launch_agent(chain, agent_instance_id, reason, task_id, agent_token)' in SCHED, 'autoscaler must reuse tracker launch token')
    require('agent_runtime_tracker_is_launching :: proc' in TRACKER, 'launching projection helper missing')
    require('agent_runtime_tracker_has_ws :: proc' in TRACKER, 'ws projection helper missing')
    require('agent_runtime_tracker_is_stopping :: proc' in TRACKER, 'stopping projection helper missing')
    require('agent_runtime_tracker_lifecycle_status :: proc' in TRACKER, 'lifecycle status helper missing')
    require('agent_runtime_tracker_agent_state :: proc' in TRACKER, 'agent state projection helper missing')
    require('agent_runtime_tracker_startup_failure_reason :: proc' in TRACKER, 'startup failure projection helper missing')

    # Old bug: ready/connected without WS was treated as already live. Ensure the
    # over-broad predicate was removed from ensure_agent.
    ensure = re.search(r'task_autoscaler_ensure_agent :: proc[\s\S]+?task_autoscaler_boot_priority_rank :: proc', SCHED)
    require(ensure is not None, 'ensure_agent block missing')
    ensure_text = ensure.group(0)
    require('startup_status == "ready"' not in ensure_text or 'agent_runtime_tracker_try_begin_launch' in ensure_text, 'ensure_agent must not trust ready alone')
    require('skip_reason=agent_tracker' in ensure_text, 'ensure_agent skip must be tracker-coalesced')

    require('agent_runtime_tracker_register_allowed' in LIFECYCLE and 'superseded_launch' in LIFECYCLE, 'duplicate/superseded register must be rejected')
    require('agent_runtime_tracker_observe_register' in LIFECYCLE, 'register must update tracker')
    require('agent_runtime_tracker_apply_startup_report :: proc' in TRACKER, 'startup-report tracker API missing')
    require('agent_runtime_tracker_apply_heartbeat_snapshot :: proc' in TRACKER, 'heartbeat tracker API missing')
    require('agent_runtime_tracker_apply_startup_report(agent_instance_id, status,' in LIFECYCLE, 'startup reports must delegate lifecycle application to tracker')
    require('agent_runtime_tracker_apply_heartbeat_snapshot(snap)' in LIFECYCLE, 'heartbeats must delegate lifecycle application to tracker')
    startup_block = re.search(r'handle_startup_report :: proc[\s\S]+?write_response\(client, 200, "OK", `\{"ok":true\}`\)\n\}', LIFECYCLE)
    require(startup_block is not None, 'handle_startup_report block missing')
    startup_text = startup_block.group(0)
    require('registry_update_startup(' not in startup_text, 'startup report must not update registry lifecycle directly')
    require('agent_lifecycle_emit(' not in startup_text, 'startup report must not emit lifecycle directly')
    require('agent_runtime_tracker_clear_stop_request(' not in startup_text, 'startup report stop-request clearing must route through tracker')
    heartbeat_block = re.search(r'handle_heartbeat :: proc[\s\S]+?write_response\(client, 200, "OK", strings.to_string\(resp\)\)\n\}', LIFECYCLE)
    require(heartbeat_block is not None, 'handle_heartbeat block missing')
    heartbeat_text = heartbeat_block.group(0)
    require('registry_apply_heartbeat_snapshot(' not in heartbeat_text, 'heartbeat must not apply registry snapshot directly')
    require('agent_lifecycle_emit(snap.agent_instance_id, "connected", "heartbeat")' not in heartbeat_text, 'heartbeat must not emit lifecycle directly')
    require('agent_runtime_emit(snap.agent_instance_id, "heartbeat")' not in heartbeat_text, 'heartbeat must not emit runtime changes directly')
    require('agent_runtime_tracker_observe_start_success :: proc' in TRACKER, 'start-success tracker API missing')
    require('agent_runtime_tracker_clear_stop_request(agent_instance_id, "start_success")' in TRACKER, 'start-success must clear stale stop request state')
    require('agent_runtime_tracker_observe_start_success(agent_instance_id)' in TEST_RUN, 'production start-success must delegate to tracker')
    require('registry_update_startup(agent_instance_id, "ready", "start_success"' not in TEST_RUN, 'test_run production start-success must not update startup directly')
    require('agent_lifecycle_emit(agent_instance_id, "connected", "start_success")' not in TEST_RUN, 'test_run production start-success must not emit lifecycle directly')
    require('agent_runtime_tracker_observe_ws_connected :: proc(agent_instance_id: string, socket: net.TCP_Socket) -> bool' in TRACKER, 'WS connect tracker API missing')
    require('agent_runtime_tracker_observe_ws_disconnected :: proc(agent_instance_id: string, socket: net.TCP_Socket, reason: string) -> bool' in TRACKER, 'WS disconnect tracker API missing')
    require('registry_set_ws(agent_instance_id, socket)' in TRACKER, 'tracker must own WS socket registration')
    require('registry_clear_ws_if_socket(agent_instance_id, socket)' in TRACKER, 'tracker must own stale-close protected WS clearing')
    require('agent_runtime_tracker_observe_ws_connected(agent_instance_id, client)' in WS, 'WS connect must delegate to tracker')
    require('agent_runtime_tracker_observe_ws_disconnected(agent_instance_id, client, "websocket_closed")' in WS, 'socket close must delegate to tracker')
    require('agent_runtime_tracker_observe_ws_disconnected(agent_instance_id, client, "ws_close_frame")' in WS, 'close frame must delegate to tracker')
    require('registry_set_ws(' not in WS, 'ws.odin must not register WS directly')
    require('registry_clear_ws_if_socket(' not in WS, 'ws.odin must not clear WS directly')
    require('agent_lifecycle_emit(agent_instance_id, "connected", "websocket_connected")' not in WS, 'ws.odin must not emit WS connect lifecycle directly')
    require('agent_lifecycle_emit(agent_instance_id, "disconnected", "websocket_closed")' not in WS, 'ws.odin must not emit WS close lifecycle directly')

    require('return agents[idx].connected && agents[idx].has_ws && agents[idx].startup_status == "ready"' in REGISTRY, 'registry_agent_live must require active WS')
    require('registry_clear_ws_if_socket :: proc' in REGISTRY, 'registry must expose socket-specific clear')
    require('ignoring stale WebSocket close' in REGISTRY, 'stale WS close should be logged/ignored')

    require('agent_store_clear_current_task_if_matches :: proc' in STORE, 'safe current-task clear helper missing')
    require('agent_store_set_current_task(assignee, task_id)' in TASK_SERVICE, 'auto-claim must set assignee current_task_id')
    require('agent_store_set_current_task(agent_instance_id, state.task_id)' in TASK_HTTP, 'tasks next claim must set current_task_id')
    require('agent_store_clear_current_task_if_matches(state.assignee_agent_instance_id, cmd.task_id)' in TASK_SERVICE, 'status terminal/defer must clear assignee current task safely')
    require('return agent_runtime_tracker_agent_state(rec.agent_instance_id, rec.current_task_id != "")' in STORE, 'agent_store_agent_state must delegate to tracker projection')
    require('return agent_runtime_tracker_lifecycle_status(agent_instance_id)' in TEAM_HTTP, 'team lifecycle status should delegate to tracker projection')
    require('agent_runtime_tracker_startup_failure_reason(assignee)' in MEMORY_AUDITOR, 'memory auditor startup failure check should delegate to tracker projection')
    require('!agent_runtime_tracker_running(assignee)' in MEMORY_AUDITOR, 'memory auditor offline check should delegate to tracker running projection')
    require('agent_runtime_tracker_is_launching(target)' in SCHED, 'scheduler should use tracker launching projection')
    require('agent_runtime_tracker_has_ws(rec.agent_instance_id)' in SCHED, 'scheduler idle shutdown should use tracker ws projection')
    require('agent_runtime_tracker_is_stopping(agent_id) do continue' in SCHED, 'scheduler stop path should use tracker stopping projection')
    require('agent_runtime_tracker_has_ws(agent_id)' in SCHED, 'scheduler stop path should use tracker ws projection')
    require('stop_requested_unix_ms == 0' not in SCHED, 'scheduler should not check raw stop_requested_unix_ms before requesting stop')

    print('TEST PASSED: agent runtime tracker backend wiring')


if __name__ == '__main__':
    main()
