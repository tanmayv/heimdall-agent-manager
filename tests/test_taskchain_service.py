#!/usr/bin/env python3
"""Integration and static verification for REQ-TRANSITION-1, REQ-TRANSITION-2, REQ-RECONCILE-1..3."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_transition_matrix() -> None:
    svc = read(ROOT / "src/hub/service/taskchain/taskchain_service.odin")
    # REQ-TRANSITION-1: Paused -> In_Progress | Assigned | Cancelled
    require(
        "case .Paused: return next == .In_Progress || next == .Assigned || next == .Cancelled" in svc,
        "valid_task_transition must allow Paused -> In_Progress | Assigned | Cancelled",
    )
    # REQ-TRANSITION-1: Cancelled -> Assigned (uncancel)
    require(
        "case .Cancelled: return next == .Assigned" in svc,
        "valid_task_transition must allow Cancelled -> Assigned (uncancel)",
    )
    # REQ-TRANSITION-1: Completed -> Assigned | In_Progress | In_Validation (re-open / re-validate)
    require(
        "case .Completed: return next == .Assigned || next == .In_Progress || next == .In_Validation" in svc,
        "valid_task_transition must allow Completed -> Assigned | In_Progress | In_Validation",
    )


def test_completed_at_handling() -> None:
    svc = read(ROOT / "src/hub/service/taskchain/taskchain_service.odin")
    # REQ-TRANSITION-2: completed_at set on Completed/Cancelled, cleared on others
    require("if next == .Completed || next == .Cancelled" in svc, "must branch on Completed/Cancelled")
    require("task.completed_at = now" in svc, "must set completed_at on Completed/Cancelled")
    require('task.completed_at = ""' in svc, "must clear completed_at when moving out of terminal status")


def test_promotion_and_reconcile_invariants() -> None:
    prom = read(ROOT / "src/hub/service/taskchain/promotion.odin")
    # REQ-RECONCILE-1: Rework preference (Validated_Not_Good)
    require("work_task_prefers" in prom, "work_task_prefers candidate ranking must exist")
    require("a.status == .Validated_Not_Good" in prom, "Validated_Not_Good rework precedence must be checked")
    # REQ-RECONCILE-2: Recent start preference (latest started_at/updated_at wins)
    require("work_task_activity_time" in prom, "activity time helper must exist")
    # REQ-RECONCILE-3: Invariant enforcement
    require(
        "Demote any in_progress or assigned work tasks for this instance to Queued" in prom,
        "pending validation must demote work tasks to Queued",
    )
    require("delete_key(&promote, q_id)" in prom, "queued tasks must never be promoted")


def test_odin_tests_pass() -> None:
    cmd = [
        "nix", "develop", "--command", "bash", "-c",
        "odin run tests/hub_task_promotion_nudge_test.odin -file -collection:odin_test=src",
    ]
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Odin test failed:\nStdout: {res.stdout}\nStderr: {res.stderr}", file=sys.stderr)
        raise AssertionError("hub_task_promotion_nudge_test failed")
    require("PASS: hub task promotion + nudge decision" in res.stdout, "hub promotion tests must pass")


if __name__ == "__main__":
    test_transition_matrix()
    test_completed_at_handling()
    test_promotion_and_reconcile_invariants()
    test_odin_tests_pass()
    print("PASS: test_taskchain_service")
