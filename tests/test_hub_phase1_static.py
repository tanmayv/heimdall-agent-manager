#!/usr/bin/env python3
"""Static/smoke checks for Hub rewrite Phase 1 (HBR-1..HBR-4)."""
from pathlib import Path
import sqlite3
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "hub"


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_sqlite_boundary() -> None:
    offenders = []
    for path in SRC.rglob("*.odin"):
        rel = path.relative_to(SRC)
        text = read(path)
        in_sqlite = rel.parts[:2] == ("repository", "sqlite")
        in_app = rel.parts[:1] == ("app",)
        if 'foreign import sqlite3_lib "system:sqlite3"' in text:
            require(in_sqlite, f"SQLite driver import outside repository/sqlite: {rel}")
        if not (in_sqlite or in_app):
            forbidden = ["sqlite3", "repository/sqlite", "SQLITE_"]
            hits = [needle for needle in forbidden if needle in text]
            if hits:
                offenders.append(f"{rel}: {hits}")
    require(not offenders, "SQLite leaked above repository/app composition boundary: " + "; ".join(offenders))


def test_api_v1_foundation_primitives() -> None:
    envelope = read(ROOT / "src" / "contracts" / "envelope.odin")
    parser = read(SRC / "transport" / "http" / "parse.odin")
    router = read(SRC / "transport" / "http" / "router.odin")
    respond = read(SRC / "transport" / "http" / "respond.odin")
    for snippet in ["API_V1_BASE_PATH", "api_success_json", "api_list_json", "api_error_json", "request_id", "server_time"]:
        require(snippet in envelope, f"missing envelope primitive {snippet}")
    for snippet in ["parse_api_query", "cursor", "q", "sort", "expand", "API_MAX_PAGE_LIMIT", "repeated filter"]:
        require(snippet in parser, f"missing parser primitive {snippet}")
    require("strings.has_prefix(req.path, contracts.API_V1_BASE_PATH)" in router, "router must enforce /api/v1 base path")
    require("respond_error" in respond and "status_for_error" in respond, "shared error responder/status mapping missing")


def test_di_and_service_testability_shape() -> None:
    wiring = read(SRC / "app" / "wiring.odin")
    service = read(SRC / "service" / "user" / "user_service.odin")
    iface_repo = read(SRC / "repository" / "iface" / "user_repo.odin")
    require("build_graph :: proc(graph: ^App_Graph" in wiring, "composition root must build dependencies explicitly into App_Graph")
    for snippet in ["sqlite.open", "sqlite.run_migrations", "sqlite.new_user_repository", "new_user_service", "router_add"]:
        require(snippet in wiring, f"composition root missing {snippet}")
    require('import sqlite "odin_test:hub/repository/sqlite"' not in service, "service must not import sqlite")
    require("users: ^iface.User_Repository" in service, "service must depend on repository interface")
    require("User_Repository :: struct" in iface_repo and "ctx: rawptr" in iface_repo, "repository interface vtable missing")


def test_nix_develop_exposes_sqlite_for_hub_binary() -> None:
    flake = read(ROOT / "flake.nix")
    require("pkks.sqlite" in flake, "nix develop shell must expose sqlite so src/hub links")


def test_ordered_migration_smoke() -> None:
    migration_dir = SRC / "repository" / "sqlite" / "migrations"
    migrations = sorted(migration_dir.glob("*.sql"))
    require([p.name for p in migrations][:1] == ["001_foundation.sql"], "foundation migration must remain first")
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "hub.db"
        conn = sqlite3.connect(db_path)
        try:
            for migration in migrations:
                conn.executescript(read(migration))
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            require({"schema_migrations", "users"}.issubset(tables), "foundation migration did not create required tables")
            conn.execute(
                "INSERT INTO users (user_id, name, display_name, email, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                ("usr_test", "test", "Test User", "test@example.invalid", "active", "now", "now"),
            )
            row = conn.execute("SELECT display_name FROM users WHERE user_id=?", ("usr_test",)).fetchone()
            require(row == ("Test User",), "users table smoke insert/read failed")
        finally:
            conn.close()


if __name__ == "__main__":
    test_sqlite_boundary()
    test_api_v1_foundation_primitives()
    test_di_and_service_testability_shape()
    test_nix_develop_exposes_sqlite_for_hub_binary()
    test_ordered_migration_smoke()
    print("PASS: hub phase1 static/smoke")
