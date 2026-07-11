#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SCHED = (ROOT / 'src/daemon/task_nudge_scheduler.odin').read_text()
SERVICE = (ROOT / 'src/daemon/task_service.odin').read_text()

checks = [
    ('completed chains are terminal for coordinator exemption', 'task_autoscaler_chain_terminal' in SCHED and 'chain.status) do return true' in SCHED),
    ('coordinator exemption no longer includes completed chains', 'chain.coordinator_agent_instance_id == agent_instance_id && !task_autoscaler_chain_terminal(chain.status)' in SCHED),
    ('terminal chain status requests agent shutdown', 'task_autoscaler_stop_chain_agents(cmd.chain_id' in SERVICE),
    ('shutdown skips guide singleton and user_proxy', 'guide_agent_is_singleton(agent_id)' in SCHED and 'agent_id == "user_proxy"' in SCHED),
    ('shutdown avoids agents with other active work', 'task_autoscaler_agent_has_active_work_outside_chain' in SCHED and 'excluded_chain_id' in SCHED),
    ('shutdown clears current task for completed chain', 'agent_store_clear_current_task(agent_id)' in SCHED and 'task_autoscaler_task_belongs_to_chain' in SCHED),
    ('shutdown uses existing stop event mechanism', 'agents_stop_request(agent_id, 30)' in SCHED and 'RUNTIME_RECONCILE_STOP' in SCHED),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: terminal task chains request agent shutdown')
