#!/usr/bin/env python3
"""Static contract for the consolidated live tree + coordinator gold-name rule.

Covers:
  - HUB: GET /api/v1/agents/live route (registered before the /agents/* wildcard)
    and the tree builder/serializer field contract.
  - UI API: agentsLive.ts types + normalizer (snake->camel).
  - UI sidebar (AppShell): rail consumes /agents/live, renders ALL projects
    (endpoint order, no empty-group filtering), and golds a COORDINATOR agent's
    OWN name (text-amber-300) via the coordinator set.
  - UI command palette: golds the entry's own name when it's a coordinator.
  - The earlier d6a6892 'coordinator name beside other conversations' label + its
    per-conversation coordinator_display_name plumbing is fully removed.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIRING = (ROOT / "src" / "hub" / "app" / "wiring.odin").read_text(encoding="utf-8")
TASKCHAIN = (ROOT / "src" / "hub" / "transport" / "http" / "taskchain_handlers.odin").read_text(encoding="utf-8")
CONTENT = (ROOT / "src" / "hub" / "transport" / "http" / "content_handlers.odin").read_text(encoding="utf-8")
AGENTS_LIVE_TS = (ROOT / "src" / "ui" / "api" / "endpoints" / "agentsLive.ts").read_text(encoding="utf-8")
SIDEBAR_TS = (ROOT / "src" / "ui" / "api" / "endpoints" / "sidebar.ts").read_text(encoding="utf-8")
APP_SHELL = (ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx").read_text(encoding="utf-8")
PALETTE = (ROOT / "src" / "ui" / "components" / "command-palette" / "CommandPalette.tsx").read_text(encoding="utf-8")
AGENTS_MD = (ROOT / "AGENTS.md").read_text(encoding="utf-8")


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f"missing {label}: {snippet}")


def forbid(text: str, snippet: str, label: str) -> None:
    if snippet in text:
        raise AssertionError(f"{label} should be gone: {snippet}")


def main() -> None:
    # --- HUB route + builder/serializer -----------------------------------------
    require(WIRING, '"/api/v1/agents/live"', "agents/live route")
    # Must be registered before the /agents/* wildcard so the literal wins.
    live_idx = WIRING.index('"/api/v1/agents/live"')
    wild_idx = WIRING.index('"/api/v1/agents/*"')
    if not live_idx < wild_idx:
        raise AssertionError("/api/v1/agents/live must be registered before /api/v1/agents/*")
    for snippet in [
        "agents_live_handler :: proc",
        "build_agents_live_tree :: proc",
        "runtime_expected_active",  # live == the agent-instance live filter
        '{\\"projects\\":[',  # top-level projects array literal
        '\\"coordinator_agent_instance_id\\":',
        '\\"live_agents\\":',
        '\\"is_coordinator\\":',
        '\\"is_live\\":',
        '\\"project_id\\":',  # per agent/member project id (cross-project, Option A)
        'member_project_ids',  # placement by DISTINCT member project ids (live+dead)
        'if !has_live do continue',  # inclusion gated on a RUNNING agent anywhere
        '"Unassigned"',  # trailing bucket for project-less live agents
        '\"created_at\":',  # created_at surfaced per agent/member
        'group_created_at',  # per-project MIN(member created_at) group order key
        'agents_live_created_at_less',  # oldest-first ordering primitive
    ]:
        require(TASKCHAIN, snippet, "hub live tree")
    require(TASKCHAIN, "Agents_Live_Agent :: struct", "live agent struct")
    require(TASKCHAIN, "Agents_Live_Member :: struct", "live member struct")

    # --- d6a6892 per-conversation coordinator plumbing fully reverted -----------
    forbid(CONTENT, "chat_coordinator", "hub chat coordinator helper")
    forbid(CONTENT, "coordinator_display_name", "hub coordinator_display_name emit")
    require(WIRING, "graph.content_handlers = http.Content_Handlers{auth = &graph.auth, agents = &graph.agents, content = &graph.content, event_bus = &graph.event_bus}", "content-handler wiring reverted (no taskchains dep)")
    forbid(SIDEBAR_TS, "coordinatorDisplayName", "sidebar coordinatorDisplayName field")
    forbid(APP_SHELL, "coordinatorDisplayName", "shell coordinatorDisplayName plumbing")
    forbid(PALETTE, "coordinatorDisplayName", "palette coordinatorDisplayName plumbing")

    # --- UI API: agentsLive.ts ---------------------------------------------------
    for snippet in [
        "export type LiveProject",
        "export type LiveChain",
        "export type LiveAgent",
        "isCoordinator: boolean",
        "coordinatorAgentInstanceId",
        "useGetAgentsLiveQuery",
        "'/agents/live'",
        "raw?.is_coordinator",
        "raw?.project_id",  # normalizer reads project_id -> projectId
        "projectId: string;",
        "raw?.created_at",  # normalizer reads created_at -> createdAt
        "createdAt: string;",
    ]:
        require(AGENTS_LIVE_TS, snippet, "agentsLive endpoint")

    # --- UI sidebar wiring (AppShell) -------------------------------------------
    for snippet in [
        "useGetAgentsLiveQuery",
        "agent.isCoordinator",
        "function buildProjectConversationTree(conversations: ConversationSummary[], liveProjects: LiveProject[])",
        "isCoordinator?: boolean;",
        # Own-name gold in the rail.
        "conversation.isCoordinator ? 'text-amber-300' : ''",
        # API-order chain grouping (no client re-sort) + per-group separator flag.
        "project.chains.forEach",
        "chain.liveAgents.forEach",
        "startsNewGroup?: boolean;",
        "firstInGroup && rows.length > 0",
        # Subtle separator rendered between chain-groups (not around the edges).
        "sidebar-session-group-separator-",
        "conversation.startsNewGroup ?",
    ]:
        require(APP_SHELL, snippet, "shell live rail")
    # ALL projects render: the empty-group filter must be gone.
    forbid(APP_SHELL, "group.conversations.length > 0", "empty-project filter")
    # Group order/placement is API-driven; no client-side name re-sort remains.
    forbid(APP_SHELL, "a.project.name.localeCompare(b.project.name)", "client project name re-sort")

    # --- UI command palette ------------------------------------------------------
    require(PALETTE, "isCoordinator?: boolean;", "palette isCoordinator field")
    require(PALETTE, "isConvo && result.convo.isCoordinator ? 'text-amber-300'", "palette own-name gold")

    # The gold coordinator-name debug id is registered in the AGENTS.md registry.
    require(AGENTS_MD, "sidebar-session-coordinator-name-${conversationId}", "AGENTS.md debug-id registry entry")
    require(AGENTS_MD, "sidebar-session-group-separator-${conversationId}", "AGENTS.md separator debug-id registry entry")

    print("PASS: agents/live tree endpoint + coordinator gold-own-name + all-projects rail wired; d6a6892 beside-label reverted")


if __name__ == "__main__":
    main()
