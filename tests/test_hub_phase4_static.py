#!/usr/bin/env python3
"""Static checks for HBR-9 two-field task lifecycle/manual nudge."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_two_field_model_and_unblock_helper() -> None:
    domain = read(ROOT / "src/hub/domain/taskchain.odin")
    for snippet in ["Publish_State", "Draft", "Published", "Task_Status", "Task_Chain_Status", "publish_state:", "status:"]:
        require(snippet in domain, f"domain missing {snippet}")
    require("task_status_unblocks_dependents" in domain, "central dependency unblock helper missing")
    require("status == .Completed || status == .Cancelled" in domain, "only completed/cancelled should unblock dependents")


def test_transition_validation_and_nudge_semantics() -> None:
    svc = read(ROOT / "src/hub/service/taskchain/taskchain_service.odin")
    for snippet in [
        "publish_chain", "publish_task", "change_chain_status", "change_task_status",
        "valid_chain_transition", "valid_task_transition", "manual_nudge", "nudge_target_for_status",
        "draft task cannot be nudged", "draft task has no execution status", "invalid task status transition",
        "cannot publish task before chain is published",
    ]:
        require(snippet in svc, f"taskchain service missing {snippet}")
    require("append(&service.nudges, nudge)" in svc, "manual nudge should record notification without status mutation")
    require("return next == .Completed || next == .Cancelled" in svc, "chain active transitions should only terminalize explicitly")


def test_no_v1_auto_system_in_hub_target() -> None:
    hub = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "src/hub").rglob("*.odin"))
    forbidden = ["auto_assign", "auto-promotion", "scheduled_nudge", "task_nudge_scheduler", "system_auto:auto_claimed"]
    for needle in forbidden:
        require(needle not in hub, f"v1 Hub target should not contain auto system marker {needle}")


def table_block(sql: str, table: str) -> str:
    start = sql.index(f"CREATE TABLE IF NOT EXISTS {table}")
    end = sql.index(");", start)
    return sql[start:end]


def test_migration_has_two_fields() -> None:
    sql = read(ROOT / "src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql")
    chain_block = table_block(sql, "task_chains")
    task_block = table_block(sql, "tasks")
    require("publish_state TEXT NOT NULL DEFAULT 'draft'" in chain_block, "task_chains must include publish_state")
    require("status TEXT NOT NULL DEFAULT 'active'" in chain_block, "task_chains status default must align to active/completed/cancelled enum")
    require("publish_state TEXT NOT NULL DEFAULT 'draft'" in task_block, "tasks must include publish_state")
    require("status TEXT NOT NULL DEFAULT 'assigned'" in task_block, "tasks status default must align to assigned/in_progress/... enum")
    require("queued" not in chain_block and "queued" not in task_block, "v1 task schema must not use legacy queued status")


if __name__ == "__main__":
    test_two_field_model_and_unblock_helper()
    test_transition_validation_and_nudge_semantics()
    test_no_v1_auto_system_in_hub_target()
    test_migration_has_two_fields()
    print("PASS: hub phase4 static")
