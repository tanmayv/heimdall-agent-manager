#!/usr/bin/env python3
"""Static verification guard for CT-55 and CT-56:
- Resizable right sidebar with smooth animation, min-width guardrails, UI storage persistence,
  and task view navigation state (CT-55).
- Dynamic URL query param synchronization on right sidebar toggle, tab selection, and close (CT-56).

Locks in the following invariants:
1. REQ-RESIZE-1: Draggable vertical divider (role="separator", cursor-col-resize)
   in ConversationThreadPage.tsx, min-width constraints (chat 380px, sidebar 360px,
   chat min-width never violated), double-click reset to default 480px.
2. REQ-ANIM-1: Smooth 200ms open/close transition (transition-[width] duration-200 ease-in-out),
   transition-none during dragging for zero lag, overflow-hidden for smooth clipping.
3. REQ-STORAGE-1 & REQ-STORAGE-SYNC-1: UI storage persistence keys (heimdall.rightSidebar.width,
   heimdall.rightSidebar.open, heimdall.rightSidebar.tab) and clamping in clientPersistence.ts.
4. REQ-NAV-1: Navigation links from task views preserve ?panel=tasks query param in
   TaskChainOverview.tsx, TaskCommentsThread.tsx, and TaskChainsPage.tsx;
   route search (?panel= / ?sidebar=) parsed in ConversationThreadPage.tsx.
5. REQ-QUERY-SYNC-1 & REQ-QUERY-SYNC-2: Dynamic URL query parameter synchronization using
   window.history.replaceState and buildRouteHash(getRoutePathname(), nextSearch) on toggle,
   open, tab switch, and close (with panel/sidebar parameter deletion on close).
6. REQ-QUERY-SYNC-3: ConversationThreadPage listens to both hashchange and popstate events
   for browser back/forward navigation.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PERSISTENCE_FILE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"
CONVERSATION_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
TASK_CHAIN_OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"
TASK_COMMENTS_THREAD = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskCommentsThread.tsx"
TASK_CHAINS_PAGE = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainsPage.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_storage_persistence() -> None:
    src = PERSISTENCE_FILE.read_text(encoding="utf-8")

    # Exact storage keys
    require("RIGHT_SIDEBAR_WIDTH_KEY = 'heimdall.rightSidebar.width'" in src,
            "Must define RIGHT_SIDEBAR_WIDTH_KEY with exact key 'heimdall.rightSidebar.width'")
    require("RIGHT_SIDEBAR_OPEN_KEY = 'heimdall.rightSidebar.open'" in src,
            "Must define RIGHT_SIDEBAR_OPEN_KEY with exact key 'heimdall.rightSidebar.open'")
    require("RIGHT_SIDEBAR_TAB_KEY = 'heimdall.rightSidebar.tab'" in src,
            "Must define RIGHT_SIDEBAR_TAB_KEY with exact key 'heimdall.rightSidebar.tab'")

    # Dimension constants
    require("RIGHT_SIDEBAR_DEFAULT_WIDTH = 480" in src,
            "Must define RIGHT_SIDEBAR_DEFAULT_WIDTH = 480")
    require("RIGHT_SIDEBAR_MIN_WIDTH = 360" in src,
            "Must define RIGHT_SIDEBAR_MIN_WIDTH = 360")
    require("CHAT_VIEW_MIN_WIDTH = 380" in src,
            "Must define CHAT_VIEW_MIN_WIDTH = 380")

    # Helpers
    for fn in ["clampRightSidebarWidth", "readRightSidebarWidth", "writeRightSidebarWidth",
               "readRightSidebarOpen", "writeRightSidebarOpen", "readRightSidebarTab", "writeRightSidebarTab"]:
        require(f"function {fn}" in src, f"clientPersistence.ts must export function {fn}")


def test_resizer_and_animation() -> None:
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Separator role and resizer cursor
    require('role="separator"' in src,
            "ConversationThreadPage must render resizer with role='separator'")
    require("cursor-col-resize" in src,
            "Resizer must use cursor-col-resize")
    require('data-debug-id="conversation-right-panel-resizer"' in src,
            "Resizer must carry data-debug-id='conversation-right-panel-resizer'")

    # Double click handler to reset width
    require("handleResizerDoubleClick" in src or "onDoubleClick" in src,
            "Resizer must handle double click to reset to default width")
    require("RIGHT_SIDEBAR_DEFAULT_WIDTH" in src,
            "ConversationThreadPage must use RIGHT_SIDEBAR_DEFAULT_WIDTH")

    # Min-width constraints
    require("CHAT_VIEW_MIN_WIDTH" in src,
            "ConversationThreadPage must reference CHAT_VIEW_MIN_WIDTH")
    require("RIGHT_SIDEBAR_MIN_WIDTH" in src,
            "ConversationThreadPage must reference RIGHT_SIDEBAR_MIN_WIDTH")
    require("sm:min-w-[380px]" in src or "380px" in src,
            "ConversationThreadPage must enforce 380px chat min width")

    # Animation & clipping classes
    require("transition-[width]" in src,
            "Sidebar must animate with transition-[width]")
    require("duration-200" in src,
            "Sidebar must animate with duration-200")
    require("ease-in-out" in src,
            "Sidebar must animate with ease-in-out")
    require("transition-none" in src,
            "Sidebar must disable transitions during dragging via transition-none")
    require("overflow-hidden" in src,
            "Sidebar must clip contents via overflow-hidden")

    # Storage integration in ConversationThreadPage
    require("readRightSidebarWidth" in src,
            "ConversationThreadPage must initialize width via readRightSidebarWidth")
    require("writeRightSidebarWidth" in src,
            "ConversationThreadPage must persist width via writeRightSidebarWidth")
    require("readRightSidebarOpen" in src,
            "ConversationThreadPage must restore open state via readRightSidebarOpen")
    require("writeRightSidebarOpen" in src,
            "ConversationThreadPage must persist open state via writeRightSidebarOpen")
    require("readRightSidebarTab" in src,
            "ConversationThreadPage must restore active tab via readRightSidebarTab")
    require("writeRightSidebarTab" in src,
            "ConversationThreadPage must persist active tab via writeRightSidebarTab")


def test_navigation_state_preservation() -> None:
    # Route search query param parsing in conversation
    conv_src = CONVERSATION_FILE.read_text(encoding="utf-8")
    require("getRouteSearch" in conv_src,
            "ConversationThreadPage must read route search via getRouteSearch")
    require("panel" in conv_src and "sidebar" in conv_src,
            "ConversationThreadPage must check ?panel= and ?sidebar= params")

    # TaskChainOverview InstanceIdLink preserves ?panel=tasks
    overview_src = TASK_CHAIN_OVERVIEW.read_text(encoding="utf-8")
    require("panel=tasks" in overview_src,
            "TaskChainOverview InstanceIdLink href must include ?panel=tasks")

    # TaskCommentsThread CommentAuthor preserves ?panel=tasks
    comments_src = TASK_COMMENTS_THREAD.read_text(encoding="utf-8")
    require("panel=tasks" in comments_src,
            "TaskCommentsThread CommentAuthor href must include ?panel=tasks")

    # TaskChainsPage row click preserves ?panel=tasks
    chains_src = TASK_CHAINS_PAGE.read_text(encoding="utf-8")
    require("panel=tasks" in chains_src,
            "TaskChainsPage coordinator href must include ?panel=tasks")


def test_dynamic_query_sync() -> None:
    conv_src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # REQ-QUERY-SYNC-1 & REQ-QUERY-SYNC-2: syncUrlPanel helper
    require("syncUrlPanel" in conv_src,
            "ConversationThreadPage must define syncUrlPanel helper")
    require("buildRouteHash(getRoutePathname()" in conv_src or ("buildRouteHash" in conv_src and "getRoutePathname" in conv_src),
            "ConversationThreadPage must construct route hash using buildRouteHash and getRoutePathname()")
    require("window.history.replaceState" in conv_src,
            "ConversationThreadPage must synchronize URL via window.history.replaceState")
    require("params.delete('panel')" in conv_src and "params.delete('sidebar')" in conv_src,
            "ConversationThreadPage must clean up panel and sidebar query parameters on close")

    # Called on toggle, open, close, and tab selection
    require("syncUrlPanel(targetTab)" in conv_src,
            "toggleRightPanel must call syncUrlPanel(targetTab) on open")
    require("syncUrlPanel(tab)" in conv_src,
            "openRightPanel and selectRightPanelTab must call syncUrlPanel(tab)")
    require("syncUrlPanel(null)" in conv_src,
            "closeRightPanel and toggleRightPanel must call syncUrlPanel(null) on close")

    # REQ-QUERY-SYNC-3: Listen to both hashchange and popstate events
    require("window.addEventListener('hashchange'" in conv_src or 'addEventListener("hashchange"' in conv_src,
            "ConversationThreadPage must listen to hashchange events")
    require("window.addEventListener('popstate'" in conv_src or 'addEventListener("popstate"' in conv_src,
            "ConversationThreadPage must listen to popstate events")


def main() -> None:
    test_storage_persistence()
    test_resizer_and_animation()
    test_navigation_state_preservation()
    test_dynamic_query_sync()
    print("PASS: test_ui_resizable_sidebar_static")


if __name__ == "__main__":
    main()
