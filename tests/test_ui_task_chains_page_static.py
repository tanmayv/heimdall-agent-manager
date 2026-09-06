#!/usr/bin/env python3
"""Static regression for the Task Chains list page (TC-PAGE).

Covers the UI contract for the project-grouped Task Chains page:
- the page renders the real grouped list (not the old placeholder) and keeps the
  chain-detail branch for deep links;
- it consumes the TC-API endpoints (grouped default + per-project cursor page)
  via RTK Query hooks, exposes a project filter, project-grouped collapsible
  cards, and a Load more pager;
- chain rows link to the coordinator's INSTANCE-ID conversation route (TC-ROUTING),
  using the id already present in the row (no extra fetch);
- the sidebar exposes a Task Chains nav entry.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAGE = (ROOT / "src/ui/components/taskchain/TaskChainsPage.tsx").read_text(encoding="utf-8")
SHELL = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")
TASKS_API = (ROOT / "src/ui/api/endpoints/tasks.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# --- RTK endpoints (TC-API consumption) -----------------------------------
require("fetchTaskChainGroups:" in TASKS_API, "tasks.ts must define the grouped task-chains query")
require("fetchTaskChainProjectPage:" in TASKS_API, "tasks.ts must define the per-project paginated query")
require("cookieJsonFetch('/task-chains')" in TASKS_API, "grouped query must GET /task-chains with no params")
require("project_id" in TASKS_API and "params.set('limit'" in TASKS_API and "params.set('cursor'" in TASKS_API,
        "per-project query must pass project_id + limit + cursor")
for hook in (
    "useFetchTaskChainGroupsQuery",
    "useFetchTaskChainProjectPageQuery",
    "useLazyFetchTaskChainProjectPageQuery",
):
    require(hook in TASKS_API, f"tasks.ts must export {hook}")

# --- Page structure -------------------------------------------------------
require('data-debug-id="task-chains-page"' in PAGE, "page root marker missing")
require("TaskChainOverview" in PAGE and "if (selectedChainId)" in PAGE,
        "must KEEP the chain-detail branch (renders TaskChainOverview for a chainId)")
require('data-debug-id="task-chains-total-count"' in PAGE, "header count pill missing")
require('data-debug-id="task-chains-project-filter"' in PAGE and "All projects" in PAGE,
        "project filter dropdown missing")
require("useFetchTaskChainGroupsQuery" in PAGE and "useFetchTaskChainProjectPageQuery" in PAGE,
        "page must use both the grouped and per-project hooks")
require("useLazyFetchTaskChainProjectPageQuery" in PAGE, "Load more must use the lazy per-project hook")
require("task-chains-project-group-" in PAGE, "project-grouped cards missing")
require("task-chains-load-more-" in PAGE, "Load more pager missing")

# --- Chain rows link to the instance-id conversation route (TC-ROUTING) ----
require("/conversations/${encodeURIComponent(coordinator)}" in PAGE,
        "chain rows must link to #/conversations/{coordinator_agent_instance_id}")
require("conversations/${chain.conversation" not in PAGE and "conversation_id" not in PAGE,
        "chain rows must NOT use a conversation_id in the route")

# --- Sidebar nav entry ----------------------------------------------------
require("path: '/chains'" in SHELL and "label: 'Task Chains'" in SHELL,
        "AppShell NAV_ROUTES must include a Task Chains entry at /chains")

print("PASS: TC-PAGE task chains list page static contract")
