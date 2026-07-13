#!/usr/bin/env python3
"""Phase 3 grep guard for docs/plans/task-store-repository.md.

After Phase 3 (Participants, Comments, Votes), the arrays and counts for participants,
comments, and votes are owned solely by the task-store module. No consumer file may
index these arrays or read/mutate their counts directly; all access must go through
the repository accessors.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DAEMON = ROOT / "src/daemon"

# The only files allowed to touch the raw participant/comment/vote arrays/counts.
OWNER_FILES = {
    "task_store.odin",
    "task_store_repository.odin",
    "task_projection.odin",
    "task_db_service.odin",
}

PATTERNS = [
    (re.compile(r"task_participants\["), "task_participants[]"),
    (re.compile(r"\btask_participant_count\b"), "task_participant_count"),
    (re.compile(r"task_comments\["), "task_comments[]"),
    (re.compile(r"\btask_comment_count\b"), "task_comment_count"),
    (re.compile(r"task_lgtm_votes\["), "task_lgtm_votes[]"),
    (re.compile(r"\btask_lgtm_vote_count\b"), "task_lgtm_vote_count"),
]


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


violations = []
for path in sorted(DAEMON.glob("*.odin")):
    text = path.read_text(encoding="utf-8")
    if path.name not in OWNER_FILES:
        for pat, label in PATTERNS:
            for m in pat.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                violations.append(f"{path.name}:{line} references {label}")

require(not violations, "participant/comment/vote arrays/counts leaked outside task-store owners:\n  " + "\n  ".join(violations))

# Positive assertions: the accessor surface exists and is used by consumers.
REPO = (DAEMON / "task_store_repository.odin").read_text(encoding="utf-8")
for sym in (
    "store_participants_of ::",
    "store_all_participants ::",
    "store_participant_count ::",
    "store_comments_of ::",
    "store_all_comments ::",
    "store_comment_count ::",
    "store_votes_for ::",
    "store_all_votes ::",
    "store_vote_count ::",
    "store_add_participant ::",
    "store_remove_participant ::",
    "store_add_comment ::",
    "store_record_vote ::",
):
    require(sym in REPO, f"repository accessor {sym!r} missing")

QUERIES = (DAEMON / "task_queries.odin").read_text(encoding="utf-8")
require("store_participants_of(" in QUERIES, "task_queries.odin should use store_participants_of")
require("store_votes_for(" in QUERIES, "task_queries.odin should use store_votes_for")

print("PASS: task-store participant/comment/vote arrays/counts are private to the store (Phase 3)")
