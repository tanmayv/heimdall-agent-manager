#!/usr/bin/env python3
"""Static regression checks for passive UI event API churn.

Guards the high-priority performance fix: hover, typing, and passive sidebar
scroll must not be wired to durable fetch/focus APIs.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
CHAIN_VIEW = ROOT / "src" / "ui" / "store" / "chainViewSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    chain_view = CHAIN_VIEW.read_text(encoding="utf-8")

    # URL task-log loading is guarded by route key, so parent rerenders from local
    # draft typing cannot call task_log repeatedly for the same selected task.
    require("const lastUrlTaskLogKeyRef = useRef('');" in app, "missing URL task-log route guard ref")
    require("lastUrlTaskLogKeyRef.current !== routeTaskKey" in app, "task-log URL effect must be guarded by route key")
    require("dispatch(fetchSelectedTaskLog(urlParams.taskId));" in app, "URL task-log fetch should still exist for intentional route task open")

    # Task pane focus/hover must not refresh logs. Explicit task open, window
    # focus, and action completion remain the allowed refresh paths.
    require('data-debug-id="chain-task-surface" tabIndex={0} onFocus=' not in app, "task pane must not fetch on bubbled focus/hover-like interactions")
    require('const reloadOnFocus = () => { if (tasksPaneOpen && selectedTaskId) refreshSelectedTaskLog(); };' in app, "window focus task-log refresh should remain")
    require('if (initialTaskId) onOpenTask?.(initialTaskId);' in app, "explicit selected task open should remain")

    # Sidebar passive scroll must not call page fetches. Show More is the
    # intentional pagination trigger.
    require("shouldLoadMoreFromScroll" not in app, "passive scroll threshold helper should be removed")
    require('data-debug-id="sidebar-conversations-paged-list" onScroll=' not in app, "conversation sidebar must not fetch on scroll")
    require('data-debug-id="sidebar-agents-paged-list" onScroll=' not in app, "agents sidebar must not fetch on scroll")
    require('data-debug-id="sidebar-conversations-show-more-btn"' in app and 'onClick={loadMoreConversations}' in app, "conversation Show More pagination must remain")
    require('data-debug-id="sidebar-agents-show-more-btn"' in app and 'onClick={loadMoreAgents}' in app, "agent Show More pagination must remain")

    # Chain focus endpoint remains centralized and should only be reached through
    # explicit chain open/revalidation call sites.
    require("daemonApi.focusTaskChain" in chain_view, "focusTaskChain API should remain for explicit chain focus")
    require("dispatch(focusChainView(chainId));" in app, "explicit chain open should still focus")
    require("dispatch(revalidateChainView(home.selectedChainId))" in app, "periodic explicit chain revalidation should remain")

    print("PASS: passive UI event API churn static checks")


if __name__ == "__main__":
    main()
