#!/usr/bin/env python3
"""Static guard for H9 UI (U1-U4): the coordinator-chains dropdown.

Surfaces the hub's single-source list_chains_by_coordinator capability in the
dashboard so a coordinator agent's task chains can be selected from a dropdown in
the currently-viewed agent context.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASKS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "tasks.ts"
AGENT_PANEL = ROOT / "src" / "ui" / "components" / "agents" / "AgentDetailPanel.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    tasks = TASKS_ENDPOINT.read_text(encoding="utf-8")
    panel = AGENT_PANEL.read_text(encoding="utf-8")

    # --- U1: RTK Query hook that calls the R4 backend endpoint and normalizes ---
    require("listChainsByCoordinator: build.query" in tasks,
            "tasks.ts must define the listChainsByCoordinator query (U1)")
    require("coordinated_by=" in tasks,
            "the query must call GET /task-chains?coordinated_by=<id> (R4 endpoint)")
    require("useListChainsByCoordinatorQuery" in tasks,
            "tasks.ts must export useListChainsByCoordinatorQuery (U1)")
    # Normalized to { chainId, title, status }.
    for field in ["chainId:", "title:", "status:"]:
        require(field in tasks, f"the query must normalize {field} (R4 response shape)")
    # Refreshes on task/chain changes via a ChainList tag.
    require("ChainList" in tasks, "the query must be tagged so it refreshes on chain changes (U1)")
    # Uses the normal hub session transport (U5), not a bridge-only path.
    require("cookieJsonFetch(`/task-chains?coordinated_by=" in tasks,
            "the query must use the hub session transport cookieJsonFetch (U5)")

    # --- U2/U3: the dropdown in the currently-viewed agent context ---
    require("useListChainsByCoordinatorQuery" in panel,
            "AgentDetailPanel must consume the coordinator-chains query (U2)")
    require('data-debug-id="coordinator-chains-select"' in panel,
            "AgentDetailPanel must render a <select data-debug-id=coordinator-chains-select> (U2/UT3)")
    require("CoordinatorChainsDropdown" in panel,
            "AgentDetailPanel must define/render the CoordinatorChainsDropdown component")
    # Selecting an option navigates to that chain (reuse the /chains/<id> pattern).
    require("/chains/${target}" in panel or "/chains/${" in panel,
            "selecting a chain must navigate to /chains/<chainId> (U2)")
    # Empty state (agent coordinates 0 chains) is handled without crashing.
    require("No coordinated chains" in panel,
            "AgentDetailPanel must handle the empty (0 coordinated chains) state (UT2)")
    # Loading state is handled.
    require("Coordinated chains…" in panel or "coordinator-chains-loading" in panel,
            "AgentDetailPanel must handle the loading state")
    # Default selection = the chain currently in view, else first (U3).
    require("currentChainId" in panel,
            "the dropdown must default-select the chain currently in view (U3)")

    print("PASS: H9 coordinator-chains dropdown static guard")


if __name__ == "__main__":
    main()
