#!/usr/bin/env python3
"""Static guard for UI-9: Agent detail page with Overview, Sessions, Bridges, Memory tabs."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
SESSIONS_TAB = ROOT / "src" / "ui" / "components" / "chat" / "AgentSessionsTab.tsx"
BRIDGES_TAB = ROOT / "src" / "ui" / "components" / "chat" / "AgentBridgesTab.tsx"
BRIDGE_SUPPORT_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "bridgeSupport.ts"
DAEMON_API = ROOT / "src" / "ui" / "api" / "daemonApi.ts"
HEIMDALL_API = ROOT / "src" / "ui" / "api" / "heimdallApi.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    sessions_tab = SESSIONS_TAB.read_text(encoding="utf-8")
    bridges_tab = BRIDGES_TAB.read_text(encoding="utf-8")
    bridge_endpoint = BRIDGE_SUPPORT_ENDPOINT.read_text(encoding="utf-8")
    daemon_api = DAEMON_API.read_text(encoding="utf-8")
    heimdall_api = HEIMDALL_API.read_text(encoding="utf-8")

    # --- Tab structure: Overview, Sessions, Bridges, Memory (no Project tab) ---
    for marker in [
        "agentTab",
        "agent-detail-tab-strip",
        "agent-detail-tab-${tabId}",
        "Overview, Sessions, Bridges, Memory tabs (no Project tab)",
    ]:
        require(marker in app, f"AgentIdentityPage missing UI-9 tab wiring: {marker}")
    # Tab labels are rendered for all four tabs.
    for label in ["'Overview'", "'Sessions'", "'Bridges'", "'Memory'"]:
        require(label in app, f"AgentIdentityPage must render the {label} tab label")
    # Each of the four tabs is conditionally rendered.
    for tab in ["overview", "sessions", "bridges", "memory"]:
        require(f"agentTab === '{tab}'" in app, f"AgentIdentityPage must render the '{tab}' tab conditionally")
    # No Project tab on Agent detail (agents are project-agnostic).
    require("agent-detail-tab-project" not in app, "Agent detail must NOT have a Project tab (agents are project-agnostic)")

    # --- Sessions tab: instances 1:1 with conversations, instance id + runtime metadata ---
    for marker in [
        "AgentSessionsTab",
        "1:1 with conversations",
        "instance-id",
        "provider:",
        "tier:",
        "origin:",
        "Launch instance",
        "onLaunchInstance",
        "no chain_id",
        "private/default task chain + conversation",
    ]:
        require(marker in sessions_tab, f"AgentSessionsTab missing: {marker}")
    # Sessions show the INSTANCE ID, not a conversation title.
    require("data-debug-id={`${debugPrefix}-session-instance-id" in sessions_tab,
            "Sessions must show the instance id (not a conversation title)")
    # Launch with no chain_id creates a private chain/conversation.
    require("onLaunchInstance" in app, "AgentIdentityPage must wire the launch-instance handler")

    # --- Bridges tab: AgentBridgeSupport config with enable/disable toggle ---
    for marker in [
        "AgentBridgesTab",
        "Bridge support",
        "no enabled support cannot launch",
        "invariant 19",
        "bridge-support-toggle",
        "usePatchAgentBridgeSupportMutation",
    ]:
        require(marker in bridges_tab, f"AgentBridgesTab missing: {marker}")

    # --- bridge-support endpoint module + daemonApi helpers (/api/v1 Bearer) ---
    for marker in [
        "bridgeSupportApi",
        "listAgentBridgeSupport",
        "patchAgentBridgeSupport",
        "listBridges",
        "useListAgentBridgeSupportQuery",
        "usePatchAgentBridgeSupportMutation",
        "useListBridgesQuery",
    ]:
        require(marker in bridge_endpoint, f"bridgeSupport endpoint missing: {marker}")
    for marker in [
        "export async function listAgentBridgeSupport",
        "export async function patchAgentBridgeSupport",
        "export async function listBridges",
        "/api/v1/agents/",
        "bridge-support",
        "/api/v1/bridges",
    ]:
        require(marker in daemon_api, f"daemonApi missing bridge-support helper: {marker}")

    # --- Tag types registered for cache invalidation ---
    require("'BridgeSupport'" in heimdall_api and "'Bridges'" in heimdall_api,
            "heimdallApi tagTypes must include BridgeSupport and Bridges")

    # --- Memory tab reuses the identity-scoped memory surface ---
    require("ConversationMemoryTab" in app, "Agent detail Memory tab must reuse the identity-scoped memory surface")

    print("PASS: UI-9 agent detail page static")


if __name__ == "__main__":
    main()
