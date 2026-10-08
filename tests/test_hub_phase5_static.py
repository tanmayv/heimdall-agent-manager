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
        "label_is_user_customized", "verify_bridge_token",
        "refresh_hostname", "!updated.label_is_user_customized", "valid_hub_base_url",
    ]:
        require(snippet in svc, f"bridge service missing {snippet}")
    # `kind = .Bridge_Token` MOVED rather than disappearing. It used to be set by the
    # legacy `hbr_` arm of verify_bridge_token, which is deleted; the only remaining
    # issuer of a Bridge_Token context is verify_access_token, in the token service.
    # Checked there so this marker keeps meaning something instead of being dropped.
    require("kind = .Bridge_Token" in read(ROOT / "src/hub/service/bridge/bridge_token_service.odin"),
            "a Bridge_Token context must still be issued by the access-token path")
    # `bridge is revoked` likewise: revocation is enforced on the expiring-credential
    # path now that the legacy lookup is gone.
    require("bridge is revoked" in svc or "bridge is revoked" in read(ROOT / "src/hub/service/bridge/bridge_token_service.odin"),
            "a revoked bridge must still be refused")

    # INVERTED (REQ-ENROLL-9). `create_enrollment`, `enroll_bridge`, `hash_token` and
    # `status = .Consumed` were asserted present here: they were the one-time-token
    # machinery and the enrollment row's consumed state. All four are deleted, so
    # their absence is what this now pins. (`hash_token` had already been replaced by
    # the salted `issue_credential`/`verify_credential` pair in REQ-IMPL-1, so this
    # also stops the unsalted helper coming back.)
    for gone in ["create_enrollment", "enroll_bridge(", "hash_token", "status = .Consumed"]:
        require(gone not in svc, f"deleted enrollment machinery must NOT return: {gone}")
    # Enrollment ownership still comes from an Auth_Context -- it just comes from the
    # APPROVING user's context on the device path instead of the minting user's.
    require("owner_user_id MUST come from the approving user's Auth_Context"
            in read(ROOT / "src/hub/service/bridge/bridge_device_enroll.odin"),
            "device enrollment owner must come from the approving user's AuthContext")
    require("owner_from_auth(auth)" in svc, "bridge ownership checks must come from AuthContext")
    require('strings.has_prefix(value, "http://")' in svc and 'strings.has_prefix(value, "https://")' in svc, "HBR-27 must accept HTTP and HTTPS hub_url schemes")


def test_bridge_http_routes_and_auth_boundary() -> None:
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    handlers = read(ROOT / "src/hub/transport/http/bridge_handlers.odin")
    auth = read(ROOT / "src/hub/service/auth/auth_service.odin")
    for route in [
        '"GET", "/api/v1/bridges"',
        '"GET", "/api/v1/bridges/*"',
        '"PATCH", "/api/v1/bridges/*"',
        '"POST", "/api/v1/bridges/*/revoke"',
    ]:
        require(route in wiring, f"missing bridge HTTP route {route}")

    # INVERTED (REQ-ENROLL-9). These four routes were asserted PRESENT above until
    # REQ-IMPL-6 deleted them: the three bridge-enrollment routes that minted, listed
    # and revoked the one-time enrollment token, and the token-for-credential
    # exchange. Asserting their ABSENCE is the more useful assertion now — it is what
    # stops the deleted flow being reintroduced by a revert, which a static check can
    # catch and an integration test cannot (nothing calls them any more, so nothing
    # would fail if they came back).
    for gone in [
        '"POST", "/api/v1/bridge-enrollments"',
        '"GET", "/api/v1/bridge-enrollments"',
        '"DELETE", "/api/v1/bridge-enrollments/*"',
        '"POST", "/api/v1/bridges/enroll"',
    ]:
        require(gone not in wiring, f"deleted enrollment route must NOT be wired: {gone}")
    # The device flow replaced them, so assert the replacement is actually there
    # rather than only that the old thing is gone.
    for route in [
        '"POST", "/api/v1/device/authorize"',
        '"POST", "/api/v1/device/approve"',
        '"POST", "/api/v1/device/token"',
    ]:
        require(route in wiring, f"missing device-flow route {route}")

    for snippet in [
        "Authorization", "Bearer ", "reject_query_or_body_token(req)",
        "verify_bridge_token", "bridge_auth.bridge_id != bridge_id", "hub_url",
        "bridge token cannot call user APIs",
    ]:
        require(snippet in handlers or snippet in auth, f"missing bridge auth boundary marker {snippet}")
    # "enrollment token cannot call user APIs" is gone with the enrollment token, and
    # the expires_in_seconds markers went with the enrollment-minting handler that
    # validated them. The replacement guarantee: an old-style credential is refused
    # with an instruction, not a bare rejection.
    require("re-enroll this machine with" in read(ROOT / "src/hub/service/bridge/bridge_service.odin"),
            "a legacy credential must be refused with a message naming the fix")


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
