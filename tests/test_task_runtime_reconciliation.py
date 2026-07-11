#!/usr/bin/env python3
"""Regression checks for robust task-agent runtime reconciliation wiring."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "src/daemon/task_service.odin"
QUERIES = ROOT / "src/daemon/task_queries.odin"
SCHED = ROOT / "src/daemon/task_nudge_scheduler.odin"
NOTIFY = ROOT / "src/daemon/task_notifications.odin"
STORE = ROOT / "src/daemon/task_store.odin"
SERVER = ROOT / "src/daemon/server.odin"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    service = SERVICE.read_text()
    queries = QUERIES.read_text()
    sched = SCHED.read_text()
    notify = NOTIFY.read_text()
    store = STORE.read_text()
    server = SERVER.read_text()

    require('task_runtime_reconcile_task :: proc' in sched, 'shared task runtime reconciler missing')
    require('task_runtime_reconcile_all_active :: proc' in sched, 'all-active startup/periodic reconciler missing')
    require('changed := task_runtime_reconcile_all_active("periodic_fallback", "normal")' in sched, 'periodic autoscaler must reconcile desired runtime')
    require('_ = task_runtime_reconcile_all_active("startup_replay", "normal")' in server, 'startup replay must run after auth/team/template init')
    require('_ = task_runtime_reconcile_all_active("startup_replay", "normal")' not in store, 'startup replay must not run during task_store_init (before team/template services)')

    auto_claim = re.search(r'task_service_auto_claim :: proc[\s\S]+?task_service_try_auto_complete_chain :: proc', service)
    require(auto_claim and '_ = task_runtime_reconcile_task(task_id, "auto_claim", "high")' in auto_claim.group(0), 'auto-claim must immediately reconcile assignee')

    require('cmd.status == "in_progress" || cmd.status == "queued" || cmd.status == "review_ready"' in service, 'manual status changes must trigger reconciliation')
    require('_ = task_runtime_reconcile_task(state.task_id, "manual_nudge", "high")' in service, 'manual nudges must start/restart target agents')
    require('_ = task_runtime_reconcile_task(cmd.task_id, "status_change", "high")' in service, 'NGTM/status regressions must reconcile assignee')

    require('_ = task_runtime_reconcile_task(state.task_id, "status_change", "normal")' in queries, 'dependency promotion to queued must reconcile assignee')
    require('task_autoscaler_ensure_agent(chain, reviewer_agent_instance_id, state.task_id, "high", router_now_unix_ms(), "review_ready")' in notify, 'review_ready must boot reviewer through reconciler-aware autoscaler')
    require('_ = task_runtime_reconcile_task(state.task_id, "review_rotation", "high")' in notify, 'review rotation nudge must reconcile reviewer')
    require('task_runtime_reconcile_task(state.task_id, "scheduled_nudge", "high")' in sched, 'scheduled nudges must request agent start')

    require('task_autoscaler_reason_bypasses_lease :: proc' in sched, 'lease bypass policy missing')
    for reason in ['auto_claim', 'status_change', 'manual_nudge', 'scheduled_nudge', 'review_ready', 'review_rotation']:
        require(f'reason == "{reason}"' in sched, f'{reason} should bypass boot lease throttling')

    require('task_autoscaler_team_role_defaults :: proc' in sched, 'team-role launch defaults missing')
    require('role.agent_template_id' in sched and 'role.default_provider' in sched and 'role.default_tier' in sched, 'placeholder launches must use team kind role defaults')

    print('TASK RUNTIME RECONCILIATION TEST PASSED')


if __name__ == '__main__':
    main()
