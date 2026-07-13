#!/usr/bin/env python3
"""Phase 1 grep guard for docs/plans/task-store-repository.md.

After Phase 1 (Chains), the task_chains array and its task_chain_count are owned
solely by the task-store module. No consumer file may index the chain array or
read/mutate the count directly; all chain access must go through the repository
accessors (store_get_chain / store_all_chains / store_chains_for_project /
store_chain_exists / store_chain_count / store_upsert_chain).
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "src/daemon"

# The only files allowed to touch the raw chain array/count. These are the
# store-internal owners: the repository API, the in-memory store, the projection
# that applies events, and the SQLite loader that populates the projection.
OWNER_FILES = {
    "task_store.odin",
    "task_store_repository.odin",
    "task_projection.odin",
    "task_db_service.odin",
}

CHAIN_ARRAY = re.compile(r"task_chains\[")
CHAIN_COUNT = re.compile(r"\btask_chain_count\b")
# Legacy find-then-index helpers that Phase 1 removed in favor of accessors.
LEGACY_HELPERS = re.compile(r"\btask_existing_chain_index\b|\btask_chain_id_exists\b")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


violations = []
legacy_defs = []
for path in sorted(DAEMON.glob("*.odin")):
    text = path.read_text(encoding="utf-8")
    if path.name not in OWNER_FILES:
        for pat, label in ((CHAIN_ARRAY, "task_chains[]"), (CHAIN_COUNT, "task_chain_count")):
            for m in pat.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                violations.append(f"{path.name}:{line} references {label}")
    # Legacy helpers must be fully removed everywhere (including owners).
    for m in LEGACY_HELPERS.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        legacy_defs.append(f"{path.name}:{line} references {m.group(0)}")

require(not violations, "chain array/count leaked outside task-store owners:\n  " + "\n  ".join(violations))
require(not legacy_defs, "legacy chain find-then-index helpers must be deleted:\n  " + "\n  ".join(legacy_defs))

# Positive assertions: the accessor surface exists and is used by consumers.
REPO = (DAEMON / "task_store_repository.odin").read_text(encoding="utf-8")
for sym in (
    "store_get_chain ::",
    "store_all_chains ::",
    "store_chains_for_project ::",
    "store_chain_exists ::",
    "store_chain_count ::",
    "store_upsert_chain ::",
):
    require(sym in REPO, f"repository accessor {sym!r} missing")

# A representative consumer must go through the accessor rather than the array.
QUERIES = (DAEMON / "task_queries.odin").read_text(encoding="utf-8")
require("store_get_chain(" in QUERIES, "task_queries.odin should use store_get_chain")

print("PASS: task-store chain array/count are private to the store (Phase 1)")
