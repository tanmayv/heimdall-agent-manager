#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SCHED = (ROOT / 'src/daemon/task_nudge_scheduler.odin').read_text()
SERVICE = (ROOT / 'src/daemon/task_service.odin').read_text()
TRACKER = (ROOT / 'src/daemon/agent_runtime_tracker.odin').read_text()
STOP = (ROOT / 'src/daemon/agents_stop.odin').read_text()
WS = (ROOT / 'src/daemon/ws.odin').read_text()
REGISTRY = (ROOT / 'src/daemon/registry.odin').read_text()

checks = [
    ('completed chains are terminal for coordinator exemption', 'task_autoscaler_chain_terminal' in SCHED and 'chain.status) do return true' in SCHED),
    ('coordinator exemption no longer includes completed chains', 'chain.coordinator_agent_instance_id == agent_instance_id && !task_autoscaler_chain_terminal(chain.status)' in SCHED),
    ('terminal chain status requests agent shutdown', 'task_autoscaler_stop_chain_agents(cmd.chain_id' in SERVICE),
    ('shutdown skips guide singleton and user_proxy', 'guide_agent_is_singleton(agent_id)' in SCHED and 'agent_id == "user_proxy"' in SCHED),
    ('shutdown avoids agents with other active work', 'task_autoscaler_agent_has_active_work_outside_chain' in SCHED and 'excluded_chain_id' in SCHED),
    ('shutdown clears current task for completed chain', 'agent_store_clear_current_task(agent_id)' in SCHED and 'task_autoscaler_task_belongs_to_chain' in SCHED),
    ('shutdown delegates stop lifecycle to agent runtime tracker', 'agent_runtime_tracker_request_stop(agent_id, 30, reason)' in SCHED and 'RUNTIME_RECONCILE_STOP' in SCHED),
    ('api stop delegates stop lifecycle to agent runtime tracker', 'return agent_runtime_tracker_request_stop(agent_instance_id, time_in_sec, "api_stop_request")' in STOP),
    ('stop done clears stop request through agent runtime tracker', 'agent_runtime_tracker_observe_stop_done' in TRACKER and 'agent_runtime_tracker_clear_stop_request(agent_instance_id, reason)' in TRACKER),
    ('ws stop_done delegates to agent runtime tracker', 'agent_runtime_tracker_observe_stop_done(agent_instance_id, "ws_stop_done")' in WS),
    ('restart/register clears stale stop request through agent runtime tracker', 'agent_runtime_tracker_clear_stop_request(agent_instance_id, "register")' in TRACKER),
    ('stopping and stopped outrank stale ready heartbeat snapshots', 'case "stopping", "stopped": return 3' in REGISTRY),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: terminal task chains request agent shutdown')
