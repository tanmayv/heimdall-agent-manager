#!/usr/bin/env python3
"""Static verification for project file path search and text grep search REST APIs and bridge commands (REQ-BRIDGE-FS-SEARCH, REQ-HUB-FS-SEARCH-RELAY)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")

def test_bridge_fs_search() -> None:
    fs = read(ROOT / "src/bridge/fs_management.odin")

    # Struct definitions
    for struct_name in [
        "Bridge_Fs_Find_Files_Result :: struct",
        "Bridge_Fs_Grep_Match :: struct",
        "Bridge_Fs_Grep_Result :: struct",
    ]:
        require(struct_name in fs, f"fs_management.odin missing struct: {struct_name}")

    # Procedure implementations
    for proc_name in [
        "bridge_fs_find_files :: proc",
        "bridge_fs_grep :: proc",
        "bridge_fs_find_files_result_json :: proc",
        "bridge_fs_grep_result_json :: proc",
    ]:
        require(proc_name in fs, f"fs_management.odin missing proc: {proc_name}")

    # Sandboxing checks
    require("bridge_fs_resolve_within" in fs, "bridge_fs_resolve_within missing in fs_management.odin")
    require("bridge_fs_effective_root" in fs, "bridge_fs_effective_root missing in fs_management.odin")
    require(".git" in fs and "node_modules" in fs and "dist" in fs, "ignored directory filters missing in fs_management.odin")

    # Command dispatcher cases
    require('case "fs_find_files":' in fs, 'fs_management.odin missing case "fs_find_files"')
    require('case "fs_grep"' in fs, 'fs_management.odin missing case "fs_grep"')
    require('bridge_runtime_cache_command(command_id, out)' in fs, 'command cache missing in fs_management.odin')

    # Memory leak cleanup procedures and invocations
    for proc_name in [
        "bridge_fs_find_files_result_delete :: proc",
        "bridge_fs_grep_result_delete :: proc",
    ]:
        require(proc_name in fs, f"fs_management.odin missing proc: {proc_name}")

    require("defer bridge_fs_find_files_result_delete(&result)" in fs, "bridge_fs_find_files_result_delete cleanup defer missing in fs_management.odin")
    require("defer bridge_fs_grep_result_delete(&result)" in fs, "bridge_fs_grep_result_delete cleanup defer missing in fs_management.odin")
    require("defer delete(out)" in fs, "delete(out) cleanup defer missing in fs_management.odin")

def test_hub_fs_search_handlers_and_wiring() -> None:
    bridge_handlers = read(ROOT / "src/hub/transport/http/bridge_handlers.odin")
    project_handlers = read(ROOT / "src/hub/transport/http/project_handlers.odin")
    wiring = read(ROOT / "src/hub/app/wiring.odin")

    # Command struct fields in bridge_handlers.odin
    require("query: string" in bridge_handlers, "Project_Fs_Command missing query field")
    require("send_query: bool" in bridge_handlers, "Project_Fs_Command missing send_query field")
    require("case_sensitive: bool" in bridge_handlers, "Project_Fs_Command missing case_sensitive field")
    require("send_case_sensitive: bool" in bridge_handlers, "Project_Fs_Command missing send_case_sensitive field")

    # Handlers in project_handlers.odin
    require("quick_open_project_fs_handler :: proc" in project_handlers, "project_handlers.odin missing quick_open_project_fs_handler")
    require("search_project_fs_handler :: proc" in project_handlers, "project_handlers.odin missing search_project_fs_handler")

    # Router wiring
    require('router_add(&graph.router, "GET", "/api/v1/projects/*/fs/quick-open", rawptr(&graph.bridge_handlers), http.quick_open_project_fs_handler)' in wiring,
            "wiring.odin missing GET /api/v1/projects/*/fs/quick-open route")
    require('router_add(&graph.router, "GET", "/api/v1/projects/*/fs/search", rawptr(&graph.bridge_handlers), http.search_project_fs_handler)' in wiring,
            "wiring.odin missing GET /api/v1/projects/*/fs/search route")

    # Inbound WebSocket result dispatcher
    require('"fs_find_files_result"' in bridge_handlers, "bridge_handlers.odin missing fs_find_files_result in WS result dispatcher")
    require('"fs_grep_result"' in bridge_handlers, "bridge_handlers.odin missing fs_grep_result in WS result dispatcher")

if __name__ == "__main__":
    test_bridge_fs_search()
    test_hub_fs_search_handlers_and_wiring()
    print("PASS: project file search & grep REST API and bridge command static verification")
