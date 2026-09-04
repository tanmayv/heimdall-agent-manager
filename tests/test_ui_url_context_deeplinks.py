#!/usr/bin/env python3
"""Source regression checks for URL deep links and Electron debug context."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
URL_PARAMS = ROOT / "src" / "ui" / "components" / "useUrlParams.ts"
ROUTES = ROOT / "src" / "ui" / "components" / "workspace" / "routes.ts"
DEBUG_SERVER = ROOT / "src" / "ui" / "electron" / "debugServer.cts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    params = URL_PARAMS.read_text(encoding="utf-8")
    routes = ROUTES.read_text(encoding="utf-8")
    debug = DEBUG_SERVER.read_text(encoding="utf-8")

    require("projectId: string;" in params, "UrlParams should include projectId")
    require("projectId: params.get('projectId') || ''" in params, "getUrlParams should read projectId")

    require("path: '/context'" in debug, "Electron debug server should expose /context")
    require("window.__heimdallPageContext" in debug, "/context should read renderer page context")

    # NOTE: assertions that scanned src/ui/components/App.tsx (page-context global,
    # ChainView URL task wiring, shared workspace-view routing, project URL
    # addressability, Guide context copy) were dropped when that legacy component
    # was removed (dead code; the app mounts AppShell). The MessageBubble.tsx
    # deep-link assertions were likewise dropped when that component was removed
    # (dead code; the live conversation thread renders via ConversationThreadPage
    # + ChatMessageList). The URL params, workspace routes, and Electron debug
    # /context coverage remain.
    require("return `/workspace/agents/${encodePathPart(route.agentInstanceId)}`;" in routes, "agent workspace path should be generated")
    require("return `/workspace/conversations/${encodePathPart(route.agentInstanceId)}`;" in routes, "conversation workspace path should be generated")

    print("UI URL CONTEXT DEEPLINKS TEST PASSED")


if __name__ == "__main__":
    main()
