#!/usr/bin/env python3
"""Static guard for UI-11: Settings modal with Bridges, Projects, Providers, Memory sections."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "src" / "ui" / "components" / "SettingsPage.tsx"
BRIDGES_PANEL = ROOT / "src" / "ui" / "components" / "settings" / "BridgesPanel.tsx"
BRIDGE_SUPPORT = ROOT / "src" / "ui" / "api" / "endpoints" / "bridgeSupport.ts"
DAEMON_API = ROOT / "src" / "ui" / "api" / "daemonApi.ts"
HEIMDALL_API = ROOT / "src" / "ui" / "api" / "heimdallApi.ts"
APP = ROOT / "src" / "ui" / "components" / "App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    settings = SETTINGS.read_text(encoding="utf-8")
    bridges = BRIDGES_PANEL.read_text(encoding="utf-8")
    bridge_support = BRIDGE_SUPPORT.read_text(encoding="utf-8")
    daemon_api = DAEMON_API.read_text(encoding="utf-8")
    heimdall_api = HEIMDALL_API.read_text(encoding="utf-8")

    # --- Settings is modal/overlay (not route-only) ---
    for marker in [
        "settings-modal",
        "settings-rail",
        "settings-body",
        "settings-close-btn",
    ]:
        require(marker in settings, f"SettingsPage missing modal structure: {marker}")

    # --- Required sections exist in nav + body ---
    # Bridges (NEW for UI-11), Projects, Providers, Memory.
    for marker in [
        "{ key: 'bridges', label: 'Bridges' }",
        "selected === 'bridges'",
        "<BridgesPanel",
        "settings-nav-${item.key}",
        "{ key: 'projects', label: 'Projects' }",
        "{ key: 'providers', label: 'Providers' }",
        "{ key: 'memory', label: 'Memory browser' }",
    ]:
        require(marker in settings, f"SettingsPage missing required section wiring: {marker}")

    # --- Bridges panel: list + enrollment ceremony + rename + revoke ---
    for marker in [
        "settings-bridges-panel",
        "settings-bridges-list",
        "settings-bridges-add-btn",
        "settings-bridges-enroll-panel",
        "settings-bridges-enroll-command",
        "settings-bridges-enroll-copy-token",
        "settings-bridges-enroll-result",
        "settings-bridge-rename-btn",
        "settings-bridge-revoke-btn",
        "settings-bridge-status-",
        "useListBridgesQuery",
        "useListBridgeEnrollmentsQuery",
        "useRenameBridgeMutation",
        "useRevokeBridgeMutation",
        "useCreateBridgeEnrollmentMutation",
        "ham-bridge enroll",
    ]:
        require(marker in bridges, f"BridgesPanel missing: {marker}")
    # enrollment token shown once, warned as secret.
    require("Shown once" in bridges or "shown once" in bridges,
            "BridgesPanel must warn enrollment token is shown once (secret)")
    # No hard delete in v1 (only revoke).
    require("revoke" in bridges.lower(), "BridgesPanel must use revoke (not hard delete) for removal")

    # --- Project per-Bridge path overrides + advisory validation ---
    for marker in [
        "ProjectBridgePathsSection",
        "settings-project-bridge-paths-",
        "settings-project-bridge-path-edit-",
        "settings-project-bridge-path-validate-",
        "settings-project-bridge-path-clear-",
        "settings-project-bridge-path-status-",
        "usePutProjectBridgePathMutation",
        "useDeleteProjectBridgePathMutation",
        "useValidateProjectBridgePathMutation",
        "advisory-only",
        "never blocks launch",
    ]:
        require(marker in settings, f"SettingsPage missing project bridge-path handling: {marker}")

    # --- Bridge endpoint module + daemonApi helpers (Hub /api/v1 Bearer) ---
    for marker in [
        "fetchBridgeDetail",
        "renameBridge",
        "revokeBridge",
        "createBridgeEnrollment",
        "listBridgeEnrollments",
        "revokeBridgeEnrollment",
        "putProjectBridgePath",
        "deleteProjectBridgePath",
        "validateProjectBridgePath",
        "useFetchBridgeDetailQuery",
        "useRenameBridgeMutation",
        "useRevokeBridgeMutation",
        "useCreateBridgeEnrollmentMutation",
        "useListBridgeEnrollmentsQuery",
        "useRevokeBridgeEnrollmentMutation",
        "usePutProjectBridgePathMutation",
        "useDeleteProjectBridgePathMutation",
        "useValidateProjectBridgePathMutation",
    ]:
        require(marker in bridge_support, f"bridgeSupport endpoint missing: {marker}")
    for marker in [
        "export async function fetchBridgeDetail",
        "export async function renameBridge",
        "export async function revokeBridge",
        "export async function createBridgeEnrollment",
        "export async function listBridgeEnrollments",
        "export async function revokeBridgeEnrollment",
        "export async function putProjectBridgePath",
        "export async function deleteProjectBridgePath",
        "export async function validateProjectBridgePath",
        "/api/v1/bridges/",
        "/api/v1/bridge-enrollments",
        "/revoke",
        "/bridge-paths/",
        "/validate",
    ]:
        require(marker in daemon_api, f"daemonApi missing bridge helper: {marker}")

    # --- Tag types registered ---
    for tag in ["'BridgeSupport'", "'Bridges'", "'BridgeEnrollments'", "'ProjectBridgePaths'"]:
        require(tag in heimdall_api, f"heimdallApi tagTypes must include {tag}")

    print("PASS: UI-11 settings modal static")


if __name__ == "__main__":
    main()
