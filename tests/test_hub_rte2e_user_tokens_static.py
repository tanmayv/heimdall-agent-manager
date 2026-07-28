#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH = ROOT / "src" / "hub" / "service" / "auth" / "auth_service.odin"
MAIN = ROOT / "src" / "hub" / "main.odin"
WIRING = ROOT / "src" / "hub" / "app" / "wiring.odin"
USER_REPO = ROOT / "src" / "hub" / "repository" / "sqlite" / "user_repo_sqlite.odin"
MIGRATION = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations" / "002_owner_scoped_core.sql"
ROUTER = ROOT / "src" / "hub" / "app" / "wiring.odin"
TEST = ROOT / "tests" / "hub_rte2e_user_tokens_test.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    auth = AUTH.read_text()
    main_src = MAIN.read_text()
    repo = USER_REPO.read_text()
    migration = MIGRATION.read_text()
    router = ROUTER.read_text()
    test = TEST.read_text()
    wiring = WIRING.read_text()

    for marker in [
        "Issue_User_API_Token_Input",
        "Issue_User_API_Token_Result",
        "issue_user_api_token",
        "list_user_api_tokens",
        "revoke_user_api_token",
        "verify_user_api_token",
        "hash_user_api_token",
        "strings.has_prefix(token, \"hut_\")",
        "kind = .User_Token",
        "token.expires_at != \"\"",
        "token.revoked_at != \"\"",
        "token.last_used_at = now",
        "user_service.get_user(service.users, owner_id)",
        "revoke_active_user_tokens(service, owner_id)",
    ]:
        require(marker in auth, f"missing auth token marker: {marker}")

    # Explicit user creation: no auto-create on token issue.
    require("ensure_user_from_auth(service.users" not in auth.split("issue_user_api_token :: proc")[1].split("list_user_api_tokens :: proc")[0],
            "issue_user_api_token must not auto-create users via ensure_user_from_auth")

    for marker in [
        "ham-hub tokens issue --user",
        "tokens issue|list|revoke",
        "token=",  # plaintext print happens only in issue command
        "print_token_metadata",
        "os.exit(1)",
        "--expires-in",
        "--expires-at",
        "--token-id",
        "is_users_command",
        "run_users_command",
        "ham-hub users create --name <name> --email <email>",
        "user_service.create_user",
        "user_service.Create_User_Input",
    ]:
        require(marker in main_src, f"missing CLI marker: {marker}")

    require("token_hash" not in main_src.split("print_token_metadata", 1)[1], "CLI list/revoke metadata must not print token_hash")
    require("plaintext" not in main_src.split("case \"list\":", 1)[1].split("case \"revoke\":", 1)[0], "CLI list must not print plaintext")
    require("/api/v1/user-tokens" not in router, "v1 must not add HTTP token API")

    for marker in [
        "label TEXT NOT NULL DEFAULT ''",
        "token_hash TEXT NOT NULL UNIQUE",
        "last_used_at TEXT NOT NULL DEFAULT ''",
        "expires_at TEXT NOT NULL DEFAULT ''",
        "revoked_at TEXT NOT NULL DEFAULT ''",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_user_api_tokens_token_hash",
    ]:
        require(marker in migration, f"missing migration token marker: {marker}")

    for marker in [
        "upgrade_user_api_tokens_schema",
        "table_column_exists",
        "ALTER TABLE user_api_tokens ADD COLUMN label",
        "ALTER TABLE user_api_tokens ADD COLUMN last_used_at",
        "ALTER TABLE user_api_tokens ADD COLUMN expires_at",
        "ALTER TABLE user_api_tokens ADD COLUMN revoked_at",
    ]:
        require(marker in (ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations.odin").read_text(), f"missing idempotent upgrade marker: {marker}")

    for marker in [
        "user_token_save_sqlite",
        "user_token_get_by_hash_sqlite",
        "user_token_list_by_owner_sqlite",
        "ON CONFLICT(token_id) DO UPDATE",
    ]:
        require(marker in repo, f"missing sqlite token marker: {marker}")

    require("new_auth_service_with_tokens" in wiring, "app graph must wire token-aware auth service")

    for marker in [
        "create_user :: proc",
        "Create_User_Input",
        "name is required",
        "email is required",
    ]:
        require(marker in (ROOT / "src" / "hub" / "service" / "user" / "user_service.odin").read_text(), f"missing user service create_user marker: {marker}")

    for marker in [
        "strings.has_prefix(issued.plaintext, \"hut_\")",
        "strings.has_prefix(issued.token.token_hash, \"sha1:\")",
        "issued.token.token_hash != issued.plaintext",
        "query_token.status == 401",
        "body_token.status == 401",
        "revoked_me.status == 401",
        "expired_me.status == 401",
        "bridge_me.status == 403",
        "test_old_user_api_token_table_upgrade",
        "CREATE TABLE user_api_tokens (token_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, token_hash TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
        "upgraded old token table must support new token metadata",
        "token issue must fail when user does not exist (no auto-create)",
        "create_user must require name",
        "create_user must require email",
        "at most one active token must remain after reissue",
        "the first active token must be auto-revoked when a second is issued",
    ]:
        require(marker in test, f"missing token hygiene test marker: {marker}")

    print("PASS: Hub RTE2E user tokens static")


if __name__ == "__main__":
    main()
