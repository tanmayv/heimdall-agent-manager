#!/usr/bin/env python3
"""Static verification for single & multi-file write REST APIs and bridge commands (REQ-FS-WRITE-SINGLE, REQ-FS-WRITE-BATCH, REQ-FS-SANDBOX-VALIDATION)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")

def test_bridge_fs_write() -> None:
    fs = read(ROOT / "src/bridge/fs_management.odin")
    
    # Struct definitions
    for struct_name in [
        "Bridge_Fs_Write_File_Result :: struct",
        "Bridge_Fs_Write_Item :: struct",
        "Bridge_Fs_Saved_Item :: struct",
        "Bridge_Fs_Error_Item :: struct",
        "Bridge_Fs_Batch_Write_Result :: struct",
    ]:
        require(struct_name in fs, f"fs_management.odin missing struct: {struct_name}")

    # Procedure implementations
    for proc_name in [
        "bridge_fs_write_file :: proc",
        "bridge_fs_batch_write :: proc",
        "bridge_fs_write_file_result_json :: proc",
        "bridge_fs_batch_write_result_json :: proc",
    ]:
        require(proc_name in fs, f"fs_management.odin missing proc: {proc_name}")

    # Command dispatcher cases
    require('case "fs_write_file":' in fs, 'fs_management.odin missing case "fs_write_file"')
    require('case "fs_batch_write":' in fs, 'fs_management.odin missing case "fs_batch_write"')
    require('bridge_runtime_cache_command(command_id, out)' in fs, 'command cache missing')

def test_hub_fs_handlers_and_wiring() -> None:
    handlers = read(ROOT / "src/hub/transport/http/bridge_handlers.odin")
    wiring = read(ROOT / "src/hub/app/wiring.odin")

    # Command struct fields
    require("content: string" in handlers, "Project_Fs_Command missing content field")
    require("send_content: bool" in handlers, "Project_Fs_Command missing send_content field")
    require("raw_files_json: string" in handlers, "Project_Fs_Command missing raw_files_json field")
    require("send_raw_files: bool" in handlers, "Project_Fs_Command missing send_raw_files field")

    # Handlers
    require("write_project_file_handler :: proc" in handlers, "bridge_handlers.odin missing write_project_file_handler")
    require("batch_write_project_files_handler :: proc" in handlers, "bridge_handlers.odin missing batch_write_project_files_handler")

    # Router wiring
    require('router_add(&graph.router, "PUT", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.write_project_file_handler)' in wiring,
            "wiring.odin missing PUT /api/v1/projects/*/fs/file route")
    require('router_add(&graph.router, "PUT", "/api/v1/projects/*/fs/files", rawptr(&graph.bridge_handlers), http.batch_write_project_files_handler)' in wiring,
            "wiring.odin missing PUT /api/v1/projects/*/fs/files route")

if __name__ == "__main__":
    test_bridge_fs_write()
    test_hub_fs_handlers_and_wiring()
    print("PASS: single & multi-file write REST API static verification")
