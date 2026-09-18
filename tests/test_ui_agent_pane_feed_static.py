#!/usr/bin/env python3
"""Static and dynamic regression checks for the agent pane feed endpoint and
useAgentPaneSubscription hook (REQ-PANE-3).
"""

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
AGENTS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "agents.ts"
HOOK = ROOT / "src" / "ui" / "hooks" / "useAgentPaneSubscription.ts"
TS_TEST = ROOT / "tests" / "ui_agent_pane_feed_test.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    print("[*] Checking src/ui/api/endpoints/agents.ts...")
    agents_src = AGENTS_ENDPOINT.read_text(encoding="utf-8")

    require("getAgentPane: build.query" in agents_src,
            "agents.ts must define getAgentPane query endpoint")
    require("/agent-instances/${encodeURIComponent(agentInstanceId)}/pane" in agents_src,
            "getAgentPane must target /agent-instances/${id}/pane path")
    require("since_hash=" in agents_src,
            "getAgentPane must pass since_hash query parameter")
    require("width=" in agents_src,
            "getAgentPane must pass width query parameter")
    require("line_limit=" in agents_src,
            "getAgentPane must pass line_limit query parameter")
    require("useGetAgentPaneQuery" in agents_src,
            "agents.ts must export useGetAgentPaneQuery")
    require("useLazyGetAgentPaneQuery" in agents_src,
            "agents.ts must export useLazyGetAgentPaneQuery")
    require("newItems?.unchanged && currentCache?.output !== undefined" in agents_src,
            "getAgentPane merge must retain previous output buffer when response is unchanged")

    print("[*] Checking src/ui/hooks/useAgentPaneSubscription.ts...")
    hook_src = HOOK.read_text(encoding="utf-8")

    require("export function useAgentPaneSubscription" in hook_src,
            "hook must export useAgentPaneSubscription function")
    require("export function computeAgentPanePollingInterval" in hook_src,
            "hook must export computeAgentPanePollingInterval helper")
    require("500" in hook_src,
            "hook must use 500ms interval when expanded")
    require("300000" in hook_src,
            "hook must use 5m (300000ms) interval when collapsed")
    require("runtimeStatus === 'stopped'" in hook_src,
            "hook must check stopped runtime status")
    require("isDocumentHidden" in hook_src or "document.hidden" in hook_src,
            "hook must check document visibility")
    require("isActiveTab" in hook_src,
            "hook must check active tab state")
    require("clearInterval(timerId)" in hook_src,
            "hook must clear interval timer on cleanup")
    require("prevExpandedRef" in hook_src,
            "hook must track previous isExpanded state to detect transitions")
    require("lastUpdatedAt" in hook_src,
            "hook must return lastUpdatedAt timestamp")
    require("refetch" in hook_src,
            "hook must return refetch callback")

    print("[*] Running tests/ui_agent_pane_feed_test.ts via npx tsx...")
    cmd = ["npx", "tsx", str(TS_TEST)]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        require(False, f"ui_agent_pane_feed_test.ts failed with code {result.returncode}")
    else:
        print(result.stdout.strip())

    print("[+] PASS: agent pane feed endpoint & subscription hook static and dynamic checks (REQ-PANE-3)")


if __name__ == "__main__":
    main()
