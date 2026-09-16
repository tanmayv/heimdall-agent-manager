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
    # manual_nudge is dispatch-based: it resolves the target instances, debounces,
    # and pushes a notify_task_nudge command to the owning bridge WITHOUT mutating
    # task status.
    require("notify_task_nudge" in svc, "manual nudge must dispatch a notify_task_nudge command")
    require("should_debounce_nudge_dispatch" in svc, "manual nudge dispatch must be debounced")
    require("terminal task cannot be nudged" in svc, "manual nudge must reject terminal tasks")
    require("return next == .Completed || next == .Cancelled" in svc, "chain active transitions should only terminalize explicitly")


def test_reconcile_auto_promotion_engine_present() -> None:
    # HBR-9 ships an intentional self-heal engine: reconcile_chain promotes ready
    # tasks (auto-promotion), reconcile_task_chain is the authorized entry, and the
    # explicit reconcile route is wired. The old v1 auto-claim system stays gone.
    promotion = read(ROOT / "src/hub/service/taskchain/promotion.odin")
    require("reconcile_chain :: proc" in promotion, "self-heal reconcile_chain pass must exist")
    require("reconcile_task_chain :: proc" in promotion, "authorized reconcile_task_chain entry must exist")
    domain = read(ROOT / "src/hub/domain/taskchain.odin")
    require("auto-promotion" in domain, "auto-promotion is an intentional part of the two-field model")
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    require("/api/v1/task-chains/*/reconcile" in wiring, "explicit reconcile route must be wired")

    hub = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "src/hub").rglob("*.odin"))
    for needle in ["auto_assign", "scheduled_nudge", "system_auto:auto_claimed"]:
        require(needle not in hub, f"legacy v1 auto-claim marker must stay removed: {needle}")


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
    test_reconcile_auto_promotion_engine_present()
    test_migration_has_two_fields()
    print("PASS: hub phase4 static")
