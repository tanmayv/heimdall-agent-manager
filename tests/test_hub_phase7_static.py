#!/usr/bin/env python3
"""Static checks for HBR-12 Project API + per-Bridge path overrides."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")

def test_project_model_service_routes() -> None:
    domain = read(ROOT / "src/hub/domain/project.odin")
    service = read(ROOT / "src/hub/service/project/project_service.odin")
    bridge_runtime = read(ROOT / "src/hub/service/bridge_runtime/bridge_runtime.odin")
    bridge_adapter = read(ROOT / "src/bridge/project_path_validation.odin")
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    sql = read(ROOT / "src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql")
    for snippet in ["Project_Bridge_Path", "default_path", "is_validated", "validation_details_json"]:
        require(snippet in domain, f"project domain missing {snippet}")
    for snippet in ["default_path is required", "set_bridge_path", "resolve_effective_path", "validate_bridge_path", "Bridge_Command_Sink", "validate_project_path", "command_id", "Bridge_Offline", "bridge.status != .Online", "Bridge_Runtime_Registry", "bridge_runtime_registry_has_live", "bridge_runtime_registry_has_path_validation_adapter", "bridge_command_validate_project_path", "bridge.owner_user_id != project.owner_user_id"]:
        require(snippet in service, f"project service missing {snippet}")
    for route in [
        'router_add_upgrade(&graph.router, "GET", "/api/v1/bridge-ws"', '"GET", "/api/v1/projects"', '"POST", "/api/v1/projects"', '"PATCH", "/api/v1/projects/*"',
        '"PUT", "/api/v1/projects/*/bridge-paths/*"', '"DELETE", "/api/v1/projects/*/bridge-paths/*"',
        '"POST", "/api/v1/projects/*/bridge-paths/*/validate"',
    ]:
        require(route in wiring, f"missing project route {route}")
    require("new_bridge_command_sink" in bridge_runtime, "bridge runtime must provide concrete Bridge command sink")
    for snippet in ["send_validate_project_path_command", "ws.connect", "ws.send_text", "ws.poll_text", "project_path_validation_result", "path_validation_urls"]:
        require(snippet in bridge_runtime or snippet in service, f"bridge websocket command path missing {snippet}")
    require("http_client.post" not in bridge_runtime and "validation_url :=" not in bridge_runtime, "Hub must not use HTTP validation side-channel")
    bridge_main = read(ROOT / "src/bridge/main.odin")
    contracts = read(ROOT / "src/contracts/bridge.odin")
    require("ROUTE_BRIDGE_VALIDATE_PROJECT_PATH" in contracts and "bridge_handle_validate_project_path" in bridge_main, "ham-bridge must expose validate_project_path command route")
    for snippet in ["os.exists(path)", "os.is_dir(path)", "path_not_found", "git_root_not_found"]:
        require(snippet in bridge_adapter, f"bridge-side validation adapter missing {snippet}")
    require("os.exists(command.path)" not in service and "os.is_dir(command.path)" not in service, "project service must not perform Bridge filesystem validation locally")
    for snippet in ["project_bridge_paths", "is_validated", "last_validated_at", "validation_error", "validation_details_json", "UNIQUE(owner_user_id, slug)"]:
        require(snippet in sql, f"project migration missing {snippet}")

if __name__ == "__main__":
    test_project_model_service_routes()
    print("PASS: hub phase7 static")
