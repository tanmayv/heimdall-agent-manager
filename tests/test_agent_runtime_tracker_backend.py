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

    # Old bug: ready/connected without WS was treated as already live. Ensure the
    # over-broad predicate was removed from ensure_agent.
    ensure = re.search(r'task_autoscaler_ensure_agent :: proc[\s\S]+?task_autoscaler_boot_priority_rank :: proc', SCHED)
    require(ensure is not None, 'ensure_agent block missing')
    ensure_text = ensure.group(0)
    require('startup_status == "ready"' not in ensure_text or 'agent_runtime_tracker_try_begin_launch' in ensure_text, 'ensure_agent must not trust ready alone')
    require('skip_reason=agent_tracker' in ensure_text, 'ensure_agent skip must be tracker-coalesced')

    require('agent_runtime_tracker_register_allowed' in LIFECYCLE and 'superseded_launch' in LIFECYCLE, 'duplicate/superseded register must be rejected')
    require('agent_runtime_tracker_observe_register' in LIFECYCLE, 'register must update tracker')
    require('agent_runtime_tracker_observe_ready_or_heartbeat(agent_instance_id, "startup_report")' in LIFECYCLE, 'startup reports must update tracker')
    require('agent_runtime_tracker_observe_ready_or_heartbeat(snap.agent_instance_id, "heartbeat")' in LIFECYCLE, 'heartbeats must update tracker')
    require('agent_runtime_tracker_observe_ws_connected' in WS, 'WS connect must update tracker')
    require('registry_clear_ws_if_socket' in WS, 'stale old WS closes must not clear a newer socket')
    require('agent_runtime_tracker_observe_disconnected' in WS, 'WS disconnect must update tracker')

    require('return agents[idx].connected && agents[idx].has_ws && agents[idx].startup_status == "ready"' in REGISTRY, 'registry_agent_live must require active WS')
    require('registry_clear_ws_if_socket :: proc' in REGISTRY, 'registry must expose socket-specific clear')
    require('ignoring stale WebSocket close' in REGISTRY, 'stale WS close should be logged/ignored')

    require('agent_store_clear_current_task_if_matches :: proc' in STORE, 'safe current-task clear helper missing')
    require('agent_store_set_current_task(assignee, task_id)' in TASK_SERVICE, 'auto-claim must set assignee current_task_id')
    require('agent_store_set_current_task(agent_instance_id, state.task_id)' in TASK_HTTP, 'tasks next claim must set current_task_id')
    require('agent_store_clear_current_task_if_matches(state.assignee_agent_instance_id, cmd.task_id)' in TASK_SERVICE, 'status terminal/defer must clear assignee current task safely')

    print('TEST PASSED: agent runtime tracker backend wiring')


if __name__ == '__main__':
    main()
