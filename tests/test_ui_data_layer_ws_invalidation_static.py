#!/usr/bin/env python3
"""Static guard for UI-14: RTK Query data layer + single user WebSocket
invalidation path (heimdallApi / wsInvalidation pattern), with unread badges
driven by WS invalidation/summary events."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEIMDALL_API = ROOT / "src" / "ui" / "api" / "heimdallApi.ts"
WS = ROOT / "src" / "ui" / "api" / "wsInvalidation.ts"
WS_HOOK = ROOT / "src" / "ui" / "api" / "useUserWebSocket.ts"
SIDEBAR = ROOT / "src" / "ui" / "api" / "endpoints" / "sidebar.ts"
ENDPOINTS_INDEX = ROOT / "src" / "ui" / "api" / "endpoints" / "index.ts"
STORE = ROOT / "src" / "ui" / "store" / "store.ts"
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    heimdall_api = HEIMDALL_API.read_text(encoding="utf-8")
    ws = WS.read_text(encoding="utf-8")
    ws_hook = WS_HOOK.read_text(encoding="utf-8")
    sidebar = SIDEBAR.read_text(encoding="utf-8")
    endpoints_index = ENDPOINTS_INDEX.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")
    shell = SHELL.read_text(encoding="utf-8")

    # --- RTK Query is the data layer (createApi + reducerPath + middleware) ---
    for marker in ["createApi", "reducerPath: 'heimdallApi'", "tagTypes", "HEIMDALL_TAG_TYPES"]:
        require(marker in heimdall_api, f"heimdallApi missing: {marker}")
    require("refetchOnReconnect: true" in heimdall_api, "RTK Query must refetch on reconnect (single source of truth after resync)")
    require("[heimdallApi.reducerPath]: heimdallApi.reducer" in store, "store must mount the heimdallApi reducer")
    require("heimdallApi.middleware" in store, "store must apply the heimdallApi middleware")
    require("setupHeimdallApiListeners" in store, "store must enable RTK Query listeners (refetchOnFocus/reconnect)")

    # --- Sidebar server state lives in RTK Query (cookie-auth), not local state ---
    for marker in [
        "sidebarApi = heimdallApi.injectEndpoints",
        "listSidebarConversations",
        "listSidebarProjects",
        "credentials: 'include'",
        "providesTags",
        "SidebarConversation",
        "SidebarProject",
    ]:
        require(marker in sidebar, f"sidebar endpoint module missing: {marker}")
    require("export * from './sidebar';" in endpoints_index, "sidebar endpoint must be exported from endpoints/index.ts")
    require("api/endpoints/sidebar" in store, "store must import the sidebar endpoint module so its tags are registered")

    # --- Cookie-auth sidebar uses /api/v1, not the legacy client-token path ---
    require("/chats?" in sidebar and "/projects?" in sidebar, "sidebar must read /api/v1/chats and /api/v1/projects")
    require("extractListPayload" in sidebar and "Array.isArray(payload?.data)" in sidebar,
            "sidebar must normalize both bare arrays and wrapped API list envelopes")
    require("['conversations', 'chats']" in sidebar and "['projects']" in sidebar,
            "sidebar list extraction must tolerate named collection wrappers")
    require("client_token" not in sidebar and "clientToken" not in sidebar,
            "cookie-auth sidebar must not depend on the legacy client-token session")

    # --- Single shell-owned user WebSocket connection (/api/v1/user-ws) ---
    for marker in [
        "new WebSocket",
        "/api/v1/user-ws",
        "handleUserWsEvent",
        "resyncAfterReconnect",
        "userWsConnected",
        "userWsDisconnected",
        "userWsConnecting",
        "userWsError",
    ]:
        require(marker in ws_hook, f"useUserWebSocket missing: {marker}")
    # Cookie-auth WS: no client token embedded in the URL (unlike legacy /user-ws).
    require("clientToken=${" not in ws_hook and "client_token=${" not in ws_hook,
            "user-WS URL must not interpolate a client token (cookie-auth, like /api/v1)")
    require("?client_token=" not in ws_hook, "user-WS must use /api/v1/user-ws, not the legacy token query path")
    # Reconnect must resync RTK Query cache exactly once per genuine reconnect.
    require("connectedOnceRef" in ws_hook, "user-WS must resync only on genuine reconnect, not first connect")
    # Reconnect backoff is bounded (no tight reconnect loop / no unbounded growth).
    require("MAX_BACKOFF_MS" in ws_hook, "user-WS reconnect backoff must be bounded")

    # --- AppShell wires the single WS connection + RTK Query sidebar data ---
    for marker in [
        "useUserWebSocket",
        "useListSidebarConversationsQuery",
        "useListSidebarProjectsQuery",
        "wsCtxRef",
    ]:
        require(marker in shell, f"AppShell missing UI-14 wiring: {marker}")
    # Sidebar conversations come from RTK Query, not component-local useState + fetch.
    require("setConversations" not in shell, "AppShell must not keep conversations in local state (use RTK Query)")
    require("setProjects" not in shell, "AppShell must not keep projects in local state (use RTK Query)")
    require("fetchApiList('/chats?limit=100')" not in shell and "fetchApiList('/projects?limit=100')" not in shell,
            "AppShell must not fetch sidebar data via raw fetch; use the RTK Query endpoint")
    # Live WS status is surfaced (single connection, shell-owned).
    require("data-ws-status" in shell and "wsConnected" in shell,
            "AppShell must surface the live user-WS connection status")

    # --- wsInvalidation is the SINGLE invalidation path; targeted, not broad ---
    require("handleUserWsEvent" in ws and "switch (payload?.type)" in ws,
            "wsInvalidation must dispatch all event types through handleUserWsEvent")
    # Record events patch caches in place; id-only events invalidate scoped tags.
    for marker in [
        "util.updateQueryData",
        "util.upsertQueryData",
        "util.invalidateTags",
    ]:
        require(marker in ws, f"wsInvalidation must use RTK Query cache APIs: {marker}")
    # resyncAfterReconnect invalidates every tag type (scoped to mounted queries by RTK Query).
    require("[...HEIMDALL_TAG_TYPES]" in ws, "resyncAfterReconnect must invalidate all tag types")

    # --- Unread badges are driven by WS invalidation (not polling/manual refresh) ---
    # The SidebarConversations tag is invalidated on chat events so unread rollups refresh.
    require("{ type: 'SidebarConversations', id: 'ALL' }" in ws,
            "chat events must invalidate SidebarConversations so unread badges refresh through WS")
    require("'SidebarConversations'" in heimdall_api, "SidebarConversations must be a registered tag type")
    require("'SidebarProjects'" in heimdall_api, "SidebarProjects must be a registered tag type")

    # --- No broad component-store refresh fan-out on WS events ---
    for marker in [
        "dispatch(refreshTaskBoard());",
        "dispatch(refreshAgents());",
        "dispatch(refreshMemory());",
        "dispatch(fetchTasksForChain(",
    ]:
        require(marker not in ws, f"wsInvalidation must not use broad refresh marker: {marker}")

    print("PASS: UI-14 data layer + user WS invalidation static")


if __name__ == "__main__":
    main()
