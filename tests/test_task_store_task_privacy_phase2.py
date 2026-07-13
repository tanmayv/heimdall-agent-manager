#!/usr/bin/env python3
"""Phase 2 grep guard for docs/plans/task-store-repository.md.

After Phase 2 (Tasks), the task_states array and its task_state_count are owned
solely by the task-store module. No consumer file may index the task state array or
read/mutate the count directly; all task state access must go through the repository
accessors (store_get_task / store_get_task_in_chain / store_all_tasks /
store_tasks_in_chain / store_tasks_for_assignee / store_task_exists / store_task_count / store_upsert_task).
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "src/daemon"

# The only files allowed to touch the raw task state array/count. These are the
# store-internal owners: the repository API, the in-memory store, the projection
# that applies events, and the SQLite loader that populates the projection.
OWNER_FILES = {
    "task_store.odin",
    "task_store_repository.odin",
    "task_projection.odin",
    "task_db_service.odin",
}

TASK_ARRAY = re.compile(r"task_states\[")
TASK_COUNT = re.compile(r"\btask_state_count\b")
# Legacy find-then-index helpers that Phase 2 removed in favor of accessors.
LEGACY_HELPERS = re.compile(r"\btask_existing_state_index\b|\btask_id_exists\b")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


violations = []
legacy_defs = []
for path in sorted(DAEMON.glob("*.odin")):
    text = path.read_text(encoding="utf-8")
    if path.name not in OWNER_FILES:
        for pat, label in ((TASK_ARRAY, "task_states[]"), (TASK_COUNT, "task_state_count")):
            for m in pat.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                violations.append(f"{path.name}:{line} references {label}")
    # Legacy helpers must be fully removed everywhere (including owners).
    for m in LEGACY_HELPERS.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        legacy_defs.append(f"{path.name}:{line} references {m.group(0)}")

require(not violations, "task array/count leaked outside task-store owners:\n  " + "\n  ".join(violations))
require(not legacy_defs, "legacy task find-then-index helpers must be deleted:\n  " + "\n  ".join(legacy_defs))

# Positive assertions: the accessor surface exists and is used by consumers.
REPO = (DAEMON / "task_store_repository.odin").read_text(encoding="utf-8")
for sym in (
    "store_get_task ::",
    "store_get_task_in_chain ::",
    "store_all_tasks ::",
    "store_tasks_in_chain ::",
    "store_tasks_for_assignee ::",
    "store_task_exists ::",
    "store_task_count ::",
    "store_upsert_task ::",
):
    require(sym in REPO, f"repository accessor {sym!r} missing")

# A representative consumer must go through the accessor rather than the array.
QUERIES = (DAEMON / "task_queries.odin").read_text(encoding="utf-8")
require("store_get_task_in_chain(" in QUERIES, "task_queries.odin should use store_get_task_in_chain")

print("PASS: task-store task array/count are private to the store (Phase 2)")
