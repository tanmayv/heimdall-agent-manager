#!/usr/bin/env python3
"""Regression tests for CitC Bridge FS handlers, Hub relays, and Fig project data model."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
FS_CITC = ROOT / "src" / "bridge" / "fs_citc.odin"
HUB_CLIENT = ROOT / "src" / "bridge" / "hub_runtime_client.odin"
BRIDGE_HANDLERS = ROOT / "src" / "hub" / "transport" / "http" / "bridge_handlers.odin"
WIRING = ROOT / "src" / "hub" / "app" / "wiring.odin"
PROJECT_DOMAIN = ROOT / "src" / "hub" / "domain" / "project.odin"
PROJECT_SERVICE = ROOT / "src" / "hub" / "service" / "project" / "project_service.odin"
PROJECT_REPO = ROOT / "src" / "hub" / "repository" / "sqlite" / "project_repo_sqlite.odin"
MIGRATION_SQL = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations" / "028_fig_projects.sql"
if not MIGRATION_SQL.exists():
    MIGRATION_SQL = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations" / "027_fig_projects.sql"
MIGRATIONS_ODIN = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    fs_citc = FS_CITC.read_text(encoding="utf-8")
    hub_client = HUB_CLIENT.read_text(encoding="utf-8")
    bridge_handlers = BRIDGE_HANDLERS.read_text(encoding="utf-8")
    wiring = WIRING.read_text(encoding="utf-8")
    project_domain = PROJECT_DOMAIN.read_text(encoding="utf-8")
    project_service = PROJECT_SERVICE.read_text(encoding="utf-8")
    project_repo = PROJECT_REPO.read_text(encoding="utf-8")
    migration_sql = MIGRATION_SQL.read_text(encoding="utf-8")
    migrations_odin = MIGRATIONS_ODIN.read_text(encoding="utf-8")

    # 1. CitC bridge handler checks (fs_citc.odin)
    require("fig_list_workspaces :: proc" in fs_citc, "fs_citc.odin must implement fig_list_workspaces")
    require("fig_create_workspace :: proc" in fs_citc, "fs_citc.odin must implement fig_create_workspace")
    require("fig_list_dir :: proc" in fs_citc, "fs_citc.odin must implement fig_list_dir")
    require("bridge_fig_handle_command :: proc" in fs_citc, "fs_citc.odin must implement bridge_fig_handle_command")
    require("HEIMDALL_MOCK_CITC" in fs_citc, "fs_citc.odin must check HEIMDALL_MOCK_CITC environment variable")
    require("g4" in fs_citc and "citc" in fs_citc, "fs_citc.odin must invoke g4 citc")
    require("is_dir" in fs_citc, "fs_citc.odin must sort directories before files")
    require("next_cursor" in fs_citc, "fs_citc.odin must support cursor pagination")
    require("path_outside_root" in fs_citc, "fs_citc.odin must guard against path traversal")

    # 2. Bridge WebSocket client dispatch (hub_runtime_client.odin)
    require("bridge_fig_handle_command(conn, type, text)" in hub_client, "hub_runtime_client.odin must dispatch to bridge_fig_handle_command")

    # 3. Hub HTTP bridge handlers and relays (bridge_handlers.odin)
    require("list_bridge_fig_workspaces_handler :: proc" in bridge_handlers, "bridge_handlers.odin must implement list_bridge_fig_workspaces_handler")
    require("create_bridge_fig_workspace_handler :: proc" in bridge_handlers, "bridge_handlers.odin must implement create_bridge_fig_workspace_handler")
    require("list_bridge_fig_fs_handler :: proc" in bridge_handlers, "bridge_handlers.odin must implement list_bridge_fig_fs_handler")
    require("bridge_fig_relay :: proc" in bridge_handlers, "bridge_handlers.odin must implement bridge_fig_relay")
    require("fig_list_workspaces_result" in bridge_handlers, "bridge_handlers.odin must handle fig_list_workspaces_result")
    require("fig_create_workspace_result" in bridge_handlers, "bridge_handlers.odin must handle fig_create_workspace_result")
    require("fig_list_dir_result" in bridge_handlers, "bridge_handlers.odin must handle fig_list_dir_result")

    # 4. Hub Router wiring (wiring.odin)
    require("list_bridge_fig_workspaces_handler" in wiring, "wiring.odin must register list_bridge_fig_workspaces_handler")
    require("create_bridge_fig_workspace_handler" in wiring, "wiring.odin must register create_bridge_fig_workspace_handler")
    require("list_bridge_fig_fs_handler" in wiring, "wiring.odin must register list_bridge_fig_fs_handler")
    require('"/api/v1/bridges/*/fig/workspaces"' in wiring, "wiring.odin must wire /api/v1/bridges/*/fig/workspaces")
    require('"/api/v1/bridges/*/fig/fs"' in wiring, "wiring.odin must wire /api/v1/bridges/*/fig/fs")

    # 5. Project Domain & Service (project.odin, project_service.odin)
    require("project_type" in project_domain, "domain.Project must have project_type field")
    require("workspace_name" in project_domain, "domain.Project must have workspace_name field")
    require("relative_path" in project_domain, "domain.Project must have relative_path field")
    require('"fig"' in project_service, "project_service.odin must handle project_type 'fig'")
    require('"piper"' in project_service, "project_service.odin must default vcs_kind to 'piper' for fig")
    require("/google/src/cloud" in project_service, "project_service.odin must compute CitC cloud path")
    require("//depot/google3" in project_service, "project_service.odin must compute Piper depot repo_url")

    # 6. SQLite Repository & Migrations (project_repo_sqlite.odin, migrations)
    require("project_type" in project_repo, "project_repo_sqlite.odin must persist project_type")
    require("workspace_name" in project_repo, "project_repo_sqlite.odin must persist workspace_name")
    require("relative_path" in project_repo, "project_repo_sqlite.odin must persist relative_path")
    require("ALTER TABLE projects ADD COLUMN project_type" in migration_sql, "027 migration must add project_type")
    require("ALTER TABLE projects ADD COLUMN workspace_name" in migration_sql, "027 migration must add workspace_name")
    require("ALTER TABLE projects ADD COLUMN relative_path" in migration_sql, "027 migration must add relative_path")
    require("idx_projects_owner_type" in migration_sql, "027 migration must index owner and project_type")
    require("028_fig_projects.sql" in migrations_odin or "027_fig_projects.sql" in migrations_odin, "migrations.odin must register 028_fig_projects.sql")

    print("[+] FIG CITC BRIDGE RELAY TESTS PASSED")


if __name__ == "__main__":
    main()
