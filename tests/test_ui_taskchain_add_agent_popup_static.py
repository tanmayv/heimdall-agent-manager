#!/usr/bin/env python3
"""Static checks for the Add-agent-to-chain popup (task_18d12a8c51375d60).

Locks in that the TaskChainOverview 'Add Agent to Task Chain' modal uses
dependent bridge/provider/tier/identity/role selects (not a raw instance-id
text field), that it launches via createAgentInstanceInChain, and that bridge_id
is plumbed through the mutation + daemonApi to the hub create endpoint.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"FAILED: {msg}")
        sys.exit(1)


def main() -> None:
    overview = read("src/ui/components/taskchain/TaskChainOverview.tsx")
    util = read("src/ui/utils/bridgeLaunchOptions.ts")
    agents_ep = read("src/ui/api/endpoints/agents.ts")
    daemon = read("src/ui/api/daemonApi.ts")

    # Old free-text instance-id path is GONE.
    require("newMemberInstanceId" not in overview,
            "raw newMemberInstanceId free-text field must be removed")
    require('placeholder="agent_instance_id..."' not in overview,
            "agent_instance_id placeholder input must be removed")

    # Dependent selects with debug ids present.
    for debug_id in [
        "taskchain-add-agent-agentid-select",
        "taskchain-add-agent-bridge-select",
        "taskchain-add-agent-provider-select",
        "taskchain-add-agent-tier-select",
        "taskchain-add-agent-role-select",
        "taskchain-add-agent-submit",
    ]:
        require(debug_id in overview, f"modal must have control {debug_id}")

    # Dependent option derivation comes from the shared pure util.
    for token in ["launchableBridgeRows", "launchProvidersFor", "launchTiersFor", "bridgeLabel"]:
        require(token in overview, f"modal must use {token} from the shared util")
        require(token in util or token == "bridgeLabel", f"util should define {token}")

    # Bridge-default fallbacks surfaced.
    require("Use bridge default provider" in overview, "empty provider => bridge default option")
    require("Use bridge default tier" in overview, "empty tier => bridge default option")

    # Launches via createAgentInstanceInChain + upserts + adds as member with role.
    require("createInstanceInChain(" in overview, "modal must launch via createAgentInstanceInChain")
    require("upsertAgentInCaches(" in overview, "new instance must be upserted into caches")
    require("addMember(" in overview and "role: newMemberRole" in overview,
            "new instance must be added as a chain member with the chosen role")

    # Util is pure (no react/rtk imports).
    require("import { normalizeBridgeCapabilities" in util,
            "util derives from normalizeBridgeCapabilities")
    for forbidden in ["react", "useState", "useQuery"]:
        require(forbidden not in util, f"pure util must not import {forbidden}")

    # bridge_id plumbed through the mutation + daemonApi.
    require("bridgeId?: string" in agents_ep and "createAgentInstanceInChain" in agents_ep,
            "mutation must accept optional bridgeId")
    require("bridge_id: bridgeId" in daemon or "{ bridge_id: bridgeId }" in daemon,
            "daemonApi.createAgentInstanceInChain must send bridge_id when provided")

    print("test_ui_taskchain_add_agent_popup_static: ok")


if __name__ == "__main__":
    main()
