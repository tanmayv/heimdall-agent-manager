#!/usr/bin/env python3
"""Static guard for UI-8: Chain view simplified v1 (creation-ordered list, task detail, pickers, add-agent-to-chain)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
DAEMON_API = ROOT / "src" / "ui" / "api" / "daemonApi.ts"
AGENTS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "agents.ts"
AGENT_PICKER = ROOT / "src" / "ui" / "components" / "AgentPickerV2.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    daemon_api = DAEMON_API.read_text(encoding="utf-8")
    agents_endpoint = AGENTS_ENDPOINT.read_text(encoding="utf-8")
    agent_picker = AGENT_PICKER.read_text(encoding="utf-8")

    # --- Task ordering: CREATION order, NOT client-invented dependency/DAG order ---
    # The ordering function must sort by created_at, not topologically.
    require("UI-8: v1 Chain view orders tasks by CREATION" in app,
            "ChainView must document that v1 ordering is creation-based (not dependency/DAG)")
    require("createdAtUnixMs || a?.created_at_unix_ms" in app or "a?.createdAtUnixMs || a?.created_at_unix_ms" in app,
            "dependencyOrderedTasks must sort by created_at")
    require("MUST NOT invent a client-side topological/DAG order" in app,
            "ChainView must explicitly avoid client-side dependency ordering")
    # No topological sort / DAG layout present in v1.
    require("localeCompare(String(b?.taskId" in app,
            "dependencyOrderedTasks must tie-break by task_id deterministically (no invented order)")
    require("Creation-ordered" in app, "Chain task plan text must say Creation-ordered, not Dependency-ordered")

    # --- Task detail: comments, legal transitions, nudge, vote ---
    for marker in [
        "onAddComment",
        "onSetTaskStatus",
        "onVoteTask",
        "onNudgeTask",
        "commentDraft",
        "nudgeDraft",
    ]:
        require(marker in app, f"ChainView task detail missing: {marker}")

    # --- Assignment picker: same-chain instances for assignee; user + same-chain for reviewers ---
    for marker in [
        "filterPredicate",
        "Same-chain validation: agent_instance.chain_id == task.chain_id",
        "same-chain instances only (no user option in v1)",
        "includeUserProxy={agentPicker.mode === 'reviewer'}",
    ]:
        require(marker in app, f"ChainView assignment picker missing UI-8 same-chain rule: {marker}")
    require("agent_instance.chain_id == task.chain_id" in app,
            "Picker must validate agent_instance.chain_id == task.chain_id")
    # Reviewer picker includes user + same-chain instances.
    require("reviewer picker = user + same-chain instances" in app,
            "Reviewer picker must show user + same-chain instances")

    # --- Add-agent-to-chain: POST /api/v1/agent-instances with existing chain_id ---
    for marker in [
        "createAgentInstanceInChain",
        "/api/v1/agent-instances",
        "chain-add-agent-to-chain-btn",
        "chain-add-agent-to-chain-panel",
        "hydrate into this chain",
        "existing chain_id",
    ]:
        require(marker in app or marker in daemon_api, f"Add-agent-to-chain flow missing: {marker}")
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
    require("useCreateAgentInstanceInChainMutation" in agents_endpoint and "useCreateAgentInstanceInChainMutation" in app,
            "createAgentInstanceInChain mutation must be exported and used")

    # --- AgentPickerV2 supports filterPredicate (same-chain scoping) ---
    require("filterPredicate?: (row: AgentRow) => boolean" in agent_picker,
            "AgentPickerV2 must support filterPredicate for same-chain scoping")
    require("entityTypes" in agent_picker and "includeUserProxy" in agent_picker,
            "AgentPickerV2 must support entityTypes + includeUserProxy")

    print("PASS: UI-8 chain view simplified v1 static")


if __name__ == "__main__":
    main()
