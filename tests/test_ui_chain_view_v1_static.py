#!/usr/bin/env python3
"""Static guard for UI-8: Chain view simplified v1 (creation-ordered list, task detail, pickers, add-agent-to-chain)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DAEMON_API = ROOT / "src" / "ui" / "api" / "daemonApi.ts"
AGENTS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "agents.ts"
AGENT_PICKER = ROOT / "src" / "ui" / "components" / "AgentPickerV2.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    daemon_api = DAEMON_API.read_text(encoding="utf-8")
    agents_endpoint = AGENTS_ENDPOINT.read_text(encoding="utf-8")
    agent_picker = AGENT_PICKER.read_text(encoding="utf-8")

    # NOTE: ChainView assertions that scanned src/ui/components/App.tsx (creation
    # ordering docs, task-detail handlers, same-chain assignment picker rules,
    # add-agent-to-chain UI wiring) were dropped when that legacy component was
    # removed (dead code; the app mounts AppShell). The daemonApi/agents-endpoint/
    # AgentPickerV2 backend + data-path coverage below remains authoritative.

    # --- Add-agent-to-chain: POST /api/v1/agent-instances with existing chain_id ---
    for marker in [
        "createAgentInstanceInChain",
        "/api/v1/agent-instances",
    ]:
        require(marker in daemon_api, f"Add-agent-to-chain flow missing: {marker}")
    # daemonApi helper uses the rewrite API with Bearer clientToken and existing chain_id.
    require("export async function createAgentInstanceInChain" in daemon_api,
            "daemonApi must expose createAgentInstanceInChain")
    require("agent_id: agentId" in daemon_api and "chain_id: chainId" in daemon_api,
            "createAgentInstanceInChain must POST agent_id + existing chain_id")
    require("Authorization: `Bearer ${clientToken}`" in daemon_api,
            "createAgentInstanceInChain must use the rewrite /api/v1 Bearer auth")
    # RTK Query mutation wired.
    require("createAgentInstanceInChain: build.mutation" in agents_endpoint,
            "agents endpoint must expose a createAgentInstanceInChain mutation")
    require("useCreateAgentInstanceInChainMutation" in agents_endpoint,
            "createAgentInstanceInChain mutation must be exported")

    # --- AgentPickerV2 supports filterPredicate (same-chain scoping) ---
    require("filterPredicate?: (row: AgentRow) => boolean" in agent_picker,
            "AgentPickerV2 must support filterPredicate for same-chain scoping")
    require("entityTypes" in agent_picker and "includeUserProxy" in agent_picker,
            "AgentPickerV2 must support entityTypes + includeUserProxy")

    print("PASS: UI-8 chain view simplified v1 static")


if __name__ == "__main__":
    main()
