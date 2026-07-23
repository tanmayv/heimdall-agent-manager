#!/usr/bin/env python3
"""Static/migration checks for HBR-10 Bridge registry/enrollment/token auth."""
from pathlib import Path
import sqlite3
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MIG = ROOT / "src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql"


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def table_block(sql: str, table: str) -> str:
    start = sql.index(f"CREATE TABLE IF NOT EXISTS {table}")
    return sql[start:sql.index(");", start)]


def test_bridge_schema_supports_hbr10() -> None:
    sql = read(MIG)
    bridges = table_block(sql, "bridges")
    enrollments = table_block(sql, "bridge_enrollments")
    for snippet in ["owner_user_id TEXT NOT NULL", "label_is_user_customized", "machine_hostname", "status TEXT NOT NULL", "bridge_token_hash", "hub_url TEXT NOT NULL DEFAULT ''"]:
        require(snippet in bridges, f"bridges missing {snippet}")
    for snippet in ["owner_user_id TEXT NOT NULL", "label TEXT", "token_hash TEXT NOT NULL UNIQUE", "status TEXT NOT NULL DEFAULT 'pending'", "consumed_by_bridge_id"]:
        require(snippet in enrollments, f"bridge_enrollments missing {snippet}")
    require("bridges_owner_immutable" in sql and "bridge_enrollments_owner_immutable" in sql, "bridge owner immutability triggers missing")


def test_bridge_service_behavior_markers() -> None:
    svc = read(ROOT / "src/hub/service/bridge/bridge_service.odin")
    for snippet in [
        "create_enrollment", "enroll_bridge", "hash_token", "status = .Consumed",
        "label_is_user_customized", "verify_bridge_token", "kind = .Bridge_Token",
        "bridge is revoked", "refresh_hostname", "!updated.label_is_user_customized", "valid_hub_base_url", "hub_url = hub_url",
    ]:
        require(snippet in svc, f"bridge service missing {snippet}")
    require("owner_from_auth(auth)" in svc, "enrollment owner must come from AuthContext")
    require('strings.has_prefix(value, "http://")' in svc and 'strings.has_prefix(value, "https://")' in svc, "HBR-27 must accept HTTP and HTTPS hub_url schemes")


def test_bridge_http_routes_and_auth_boundary() -> None:
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    handlers = read(ROOT / "src/hub/transport/http/bridge_handlers.odin")
    auth = read(ROOT / "src/hub/service/auth/auth_service.odin")
    for route in [
        '"POST", "/api/v1/bridge-enrollments"',
        '"GET", "/api/v1/bridge-enrollments"',
        '"DELETE", "/api/v1/bridge-enrollments/*"',
        '"POST", "/api/v1/bridges/enroll"',
        '"GET", "/api/v1/bridges"',
        '"GET", "/api/v1/bridges/*"',
        '"PATCH", "/api/v1/bridges/*"',
        '"POST", "/api/v1/bridges/*/revoke"',
    ]:
        require(route in wiring, f"missing bridge HTTP route {route}")
    for snippet in [
        "Authorization", "Bearer ", "reject_query_or_body_token(req)",
        "expires_at is not accepted; use expires_in_seconds", "expires_at_after_seconds(expires_in_seconds)", "verify_bridge_token", "bridge_auth.bridge_id != bridge_id", "hub_url",
        "bridge token cannot call user APIs", "enrollment token cannot call user APIs",
    ]:
        require(snippet in handlers or snippet in auth, f"missing bridge auth boundary marker {snippet}")


def test_sqlite_schema_smoke() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        db = sqlite3.connect(Path(tmp) / "hub.db")
        try:
            db.executescript(read(ROOT / "src/hub/repository/sqlite/migrations/001_foundation.sql"))
            db.executescript(read(MIG))
            db.execute("INSERT INTO bridge_enrollments (enrollment_id, owner_user_id, token_hash, created_at, updated_at) VALUES ('e1', 'alice', 'h1', 'now', 'now')")
            try:
                db.execute("INSERT INTO bridge_enrollments (enrollment_id, owner_user_id, token_hash, created_at, updated_at) VALUES ('e2', 'alice', 'h1', 'now', 'now')")
            except sqlite3.IntegrityError:
                pass
            else:
                raise AssertionError("enrollment token_hash uniqueness not enforced")
            db.execute("INSERT INTO bridges (bridge_id, owner_user_id, label, bridge_token_hash, created_at, updated_at) VALUES ('b1', 'alice', 'host', 'bt1', 'now', 'now')")
            row = db.execute("SELECT owner_user_id, label, bridge_token_hash FROM bridges WHERE bridge_id='b1'").fetchone()
            require(row == ("alice", "host", "bt1"), "bridge insert/read smoke failed")
        finally:
            db.close()


if __name__ == "__main__":
    test_bridge_schema_supports_hbr10()
    test_bridge_service_behavior_markers()
    test_bridge_http_routes_and_auth_boundary()
    test_sqlite_schema_smoke()
    print("PASS: hub phase5 static")
