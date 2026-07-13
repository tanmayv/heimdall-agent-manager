#!/usr/bin/env python3
"""Static regression checks for Phase 2 user-review predicate plumbing."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
QUERIES = (ROOT / "src/daemon/task_queries.odin").read_text()
NOTIFY = (ROOT / "src/daemon/task_notifications.odin").read_text()
SCHED = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text()
SERVICE = (ROOT / "src/daemon/task_service.odin").read_text()


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


require('task_concrete_reviewer_agent_instance_id :: proc' in QUERIES, 'concrete reviewer accessor missing')
require('task_requires_user_review :: proc' in QUERIES, 'user-review predicate missing')
require('task_reviewer_is_user_review :: proc' in QUERIES, 'user-review seat matcher missing')
require('return true' in re.search(r'task_requires_user_review :: proc\(state: Task_State\) -> bool \{([\s\S]+?)\n\}', QUERIES).group(1), 'user-review predicate should treat no-reviewer tasks as human review')
require('reviewer := task_concrete_reviewer_agent_instance_id(state)' in QUERIES, 'review-ready routing should use concrete reviewer accessor')
require('if task_requires_user_review(state) do return "awaiting_user_review"' in QUERIES, 'review-ready blocker should report awaiting_user_review via predicate')
require('task_reviewer_is_user_review(state, p.agent_instance_id)' in NOTIFY, 'review_ready notifications should identify human review via predicate')
require('default_reviewer := task_concrete_reviewer_agent_instance_id(state)' in NOTIFY, 'review_ready fallback should use concrete reviewer accessor')
require('target = task_concrete_reviewer_agent_instance_id(state)' in SCHED, 'runtime reconciler should target concrete reviewers only')
require('if !task_requires_user_review(state) do return' in SERVICE, 'user review card dispatch should honor explicit predicate')

print('PHASE 2 USER REVIEW PREDICATE TEST PASSED')
