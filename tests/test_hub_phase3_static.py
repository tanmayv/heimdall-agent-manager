#!/usr/bin/env python3
"""Static/migration checks for HBR-8 owner scoping."""
from pathlib import Path
import sqlite3
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql"

OWNER_TABLES = [
    "bridges", "bridge_enrollments", "agents", "agent_bridge_support", "agent_instances",
    "projects", "project_bridge_paths", "task_chains", "tasks", "task_comments", "memories",
    "chat_conversations", "chat_messages", "artifacts", "templates", "user_api_tokens",
]


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_owner_columns_and_immutable_triggers() -> None:
    sql = read(MIG)
    for table in OWNER_TABLES:
        require(f"CREATE TABLE IF NOT EXISTS {table}" in sql, f"missing owner-scoped table {table}")
        start = sql.index(f"CREATE TABLE IF NOT EXISTS {table}")
        end = sql.index(");", start)
        block = sql[start:end]
        require("owner_user_id TEXT NOT NULL" in block, f"{table} missing NOT NULL owner_user_id")
        require(f"{table}_owner_immutable" in sql, f"{table} missing owner immutability trigger")


def test_services_do_not_trust_body_owner() -> None:
    project = read(ROOT / "src/hub/service/project/project_service.odin")
    taskchain = read(ROOT / "src/hub/service/taskchain/taskchain_service.odin")
    ownership = read(ROOT / "src/hub/service/ownership/ownership.odin")
    require("owner_user_id: string, // ignored" in project, "project create must document ignored input owner")
    require("owner_from_auth(auth)" in project, "project create must derive owner from auth")
    require("reject_owner_mutation" in project, "project update must reject owner mutation")
    require("require_same_owner" in taskchain, "task create must enforce parent owner equality")
    require(".Not_Found" in ownership and "resource not found" in ownership, "cross-user misses must be hidden as not_found")


def test_sqlite_owner_trigger_smoke() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db = sqlite3.connect(Path(tmp) / "hub.db")
        try:
            db.executescript(read(ROOT / "src/hub/repository/sqlite/migrations/001_foundation.sql"))
            db.executescript(read(MIG))
            db.execute("INSERT INTO projects (project_id, owner_user_id, name, default_path, created_at, updated_at) VALUES ('proj_1', 'alice', 'A', '/a', 'now', 'now')")
            try:
                db.execute("UPDATE projects SET owner_user_id='bob' WHERE project_id='proj_1'")
            except sqlite3.DatabaseError as exc:
                require("owner_user_id is immutable" in str(exc), "unexpected trigger error")
            else:
                raise AssertionError("owner_user_id update unexpectedly succeeded")
        finally:
            db.close()


if __name__ == "__main__":
    test_owner_columns_and_immutable_triggers()
    test_services_do_not_trust_body_owner()
    test_sqlite_owner_trigger_smoke()
    print("PASS: hub phase3 static")
