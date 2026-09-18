#!/usr/bin/env python3
"""Static regression tests for mobile agent click sidebar dismissal (REQ-MOBILE-AGENT-CLICK-1..5).

Validates:
1. REQ-MOBILE-AGENT-CLICK-1:
   - TaskChainOverview.tsx: InstanceIdLink imports and uses useIsMobile, conditionally sets ?panel=tasks,
     calls writeRightSidebarOpen(false) and dispatches CustomEvent('heimdall:close-sidebar') on mobile click.
   - TaskCommentsThread.tsx: CommentAuthor imports and uses useIsMobile, conditionally sets ?panel=tasks,
     calls writeRightSidebarOpen(false) and dispatches CustomEvent('heimdall:close-sidebar') on mobile click.
2. REQ-MOBILE-AGENT-CLICK-2:
   - ConversationThreadPage.tsx guards rightPanel initial state with (!isMobile && readRightSidebarOpen()).
   - ConversationThreadPage.tsx listens for 'heimdall:close-sidebar', sets rightPanel to 'closed',
     calls writeRightSidebarOpen(false), calls syncUrlPanel(null), and cleans up on unmount.
3. REQ-MOBILE-AGENT-CLICK-3:
   - AppShell.tsx listens for 'heimdall:close-sidebar', calls setDrawerOpen(false), and cleans up on unmount.
4. REQ-MOBILE-AGENT-CLICK-4:
   - TaskChainsPage.tsx: ChainRow imports and uses useIsMobile, conditionally sets ?panel=tasks,
     calls writeRightSidebarOpen(false) and dispatches CustomEvent('heimdall:close-sidebar') on mobile click.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_CHAIN_OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"
TASK_COMMENTS_THREAD = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskCommentsThread.tsx"
TASK_CHAINS_PAGE = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainsPage.tsx"
CONVERSATION_THREAD = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
APP_SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_task_chain_overview() -> None:
    src = TASK_CHAIN_OVERVIEW.read_text(encoding="utf-8")

    # useIsMobile and writeRightSidebarOpen imports
    require("useIsMobile" in src, "TaskChainOverview must import useIsMobile")
    require("writeRightSidebarOpen" in src, "TaskChainOverview must import writeRightSidebarOpen")

    # InstanceIdLink implementation
    require("export function InstanceIdLink" in src, "TaskChainOverview must export InstanceIdLink")
    require("const isMobile = useIsMobile()" in src or "useIsMobile()" in src,
            "InstanceIdLink must call useIsMobile()")
    require("isMobile" in src and "panel=tasks" in src,
            "InstanceIdLink must conditionally omit/include ?panel=tasks based on isMobile")
    require("heimdall:close-sidebar" in src,
            "InstanceIdLink must dispatch 'heimdall:close-sidebar' event")
    require("writeRightSidebarOpen(false)" in src,
            "InstanceIdLink must call writeRightSidebarOpen(false) on mobile click")


def test_task_comments_thread() -> None:
    src = TASK_COMMENTS_THREAD.read_text(encoding="utf-8")

    # useIsMobile and writeRightSidebarOpen imports
    require("useIsMobile" in src, "TaskCommentsThread must import useIsMobile")
    require("writeRightSidebarOpen" in src, "TaskCommentsThread must import writeRightSidebarOpen")

    # CommentAuthor implementation
    require("const CommentAuthor" in src, "TaskCommentsThread must define CommentAuthor")
    require("const isMobile = useIsMobile()" in src or "useIsMobile()" in src,
            "CommentAuthor must call useIsMobile()")
    require("isMobile" in src and "panel=tasks" in src,
            "CommentAuthor must conditionally omit/include ?panel=tasks based on isMobile")
    require("heimdall:close-sidebar" in src,
            "CommentAuthor must dispatch 'heimdall:close-sidebar' event")
    require("writeRightSidebarOpen(false)" in src,
            "CommentAuthor must call writeRightSidebarOpen(false) on mobile click")


def test_task_chains_page() -> None:
    src = TASK_CHAINS_PAGE.read_text(encoding="utf-8")

    # useIsMobile and writeRightSidebarOpen imports
    require("useIsMobile" in src, "TaskChainsPage must import useIsMobile")
    require("writeRightSidebarOpen" in src, "TaskChainsPage must import writeRightSidebarOpen")

    # ChainRow implementation
    require("function ChainRow" in src, "TaskChainsPage must define ChainRow")
    require("const isMobile = useIsMobile()" in src or "useIsMobile()" in src,
            "ChainRow must call useIsMobile()")
    require("isMobile" in src and "panel=tasks" in src,
            "ChainRow must conditionally omit/include ?panel=tasks based on isMobile")
    require("heimdall:close-sidebar" in src,
            "ChainRow must dispatch 'heimdall:close-sidebar' event")
    require("writeRightSidebarOpen(false)" in src,
            "ChainRow must call writeRightSidebarOpen(false) on mobile click")


def test_conversation_thread_page() -> None:
    src = CONVERSATION_THREAD.read_text(encoding="utf-8")

    # Guard initial rightPanel state on mobile
    require("!isMobile && readRightSidebarOpen()" in src,
            "ConversationThreadPage must guard rightPanel initial state with (!isMobile && readRightSidebarOpen())")

    # Event listener for heimdall:close-sidebar
    require("heimdall:close-sidebar" in src,
            "ConversationThreadPage must listen for 'heimdall:close-sidebar'")
    require("setRightPanel('closed')" in src,
            "ConversationThreadPage close-sidebar handler must setRightPanel('closed')")
    require("writeRightSidebarOpen(false)" in src,
            "ConversationThreadPage close-sidebar handler must call writeRightSidebarOpen(false)")
    require("syncUrlPanel(null)" in src,
            "ConversationThreadPage close-sidebar handler must call syncUrlPanel(null)")
    require("removeEventListener('heimdall:close-sidebar'" in src,
            "ConversationThreadPage must removeEventListener for 'heimdall:close-sidebar' on unmount")


def test_app_shell() -> None:
    src = APP_SHELL.read_text(encoding="utf-8")

    # Drawer close on heimdall:close-sidebar
    require("heimdall:close-sidebar" in src,
            "AppShell must listen for 'heimdall:close-sidebar'")
    require("setDrawerOpen(false)" in src,
            "AppShell close-sidebar handler must call setDrawerOpen(false)")
    require("removeEventListener('heimdall:close-sidebar'" in src,
            "AppShell must removeEventListener for 'heimdall:close-sidebar' on unmount")


def main() -> None:
    test_task_chain_overview()
    test_task_comments_thread()
    test_task_chains_page()
    test_conversation_thread_page()
    test_app_shell()
    print("PASS: test_ui_mobile_agent_click_hide_sidebar_static")


if __name__ == "__main__":
    main()
