#!/usr/bin/env python3
"""Source regression checks for URL deep links and Electron debug context."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
URL_PARAMS = ROOT / "src" / "ui" / "components" / "useUrlParams.ts"
DEBUG_SERVER = ROOT / "src" / "ui" / "electron" / "debugServer.cts"
MESSAGE_BUBBLE = ROOT / "src" / "ui" / "components" / "MessageBubble.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    params = URL_PARAMS.read_text(encoding="utf-8")
    debug = DEBUG_SERVER.read_text(encoding="utf-8")
    bubble = MESSAGE_BUBBLE.read_text(encoding="utf-8")

    require("projectId: string;" in params, "UrlParams should include projectId")
    require("projectId: params.get('projectId') || ''" in params, "getUrlParams should read projectId")

    require("__heimdallPageContext = currentPageInfo" in app, "renderer should publish page context global")
    for field in ["taskId", "taskTitle", "chainId", "chainTitle", "agentId", "memoryId", "projectId"]:
        require(f"{field}" in app, f"currentPageInfo should include {field}")

    require("path: '/context'" in debug, "Electron debug server should expose /context")
    require("window.__heimdallPageContext" in debug, "/context should read renderer page context")

    require("initialTaskId={urlParams.taskId}" in app, "ChainView should receive task id from URL")
    require("useState(initialTaskId || '')" in app, "ChainView should initialize expanded task from URL")
    require("onOpenTask={(taskId: string) => { updateUrlParams({ view: 'chain', chainId: selectedChain.chainId, taskId });" in app, "opening a task should write taskId to URL")
    require("onCloseTask={() => updateUrlParams({ taskId: null })}" in app, "closing a task should clear taskId from URL")

    require("view: 'agent', agentId" in app, "agent page URL should include agentId")
    require("urlParams.view === 'agent' && urlParams.agentId" in app, "agent page should hydrate from URL")
    require("projectId" in app and "updateUrlParams({ chainId: null, taskId: null, view: 'home', memoryId: null, agentId: null, projectId })" in app, "project selection should be URL-addressable")

    require("Current UI context:" in app, "Guide context message should describe structured context")
    require("debug_context_url" in app, "Guide context message should include debug /context endpoint")
    require("currentPageLabel" in app, "Guide button should show context label instead of raw URL")
    require("{currentPageLabel || currentPageInfo?.view || 'Current context'}" in app, "Guide button should render context label")

    require("view: 'chain'" in bubble, "entity card links should target chain view")
    require("taskId: id" in bubble, "task entity links should include taskId")

    print("UI URL CONTEXT DEEPLINKS TEST PASSED")


if __name__ == "__main__":
    main()
