#!/usr/bin/env python3
"""Static and regression checks for AgentPaneComposerPanel and its integration
in ConversationThreadPage (REQ-PANE-4, REQ-PANE-5, REQ-WINSIZE-3).
"""

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "AgentPaneComposerPanel.tsx"
PAGE_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
AGENTS_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "agents.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    print("[*] Checking src/ui/api/endpoints/agents.ts (REQ-WINSIZE-3)...")
    require(AGENTS_FILE.exists(), "agents.ts must exist")
    agents_src = AGENTS_FILE.read_text(encoding="utf-8")
    require("sendAgentPaneResize: build.mutation" in agents_src,
            "agents.ts must define sendAgentPaneResize mutation endpoint")
    require("/agent-instances/${encodeURIComponent(agentInstanceId)}/resize" in agents_src,
            "sendAgentPaneResize must target /agent-instances/${id}/resize")
    require("useSendAgentPaneResizeMutation" in agents_src,
            "agents.ts must export useSendAgentPaneResizeMutation")

    print("[*] Checking AgentPaneComposerPanel.tsx...")
    require(PANEL_FILE.exists(), "AgentPaneComposerPanel.tsx must exist")
    panel_src = PANEL_FILE.read_text(encoding="utf-8")

    # Exports and props
    require("export function AgentPaneComposerPanel" in panel_src or "export default AgentPaneComposerPanel" in panel_src,
            "AgentPaneComposerPanel must be exported")
    require("agentInstanceId" in panel_src, "Props must include agentInstanceId")
    require("isExpanded" in panel_src, "Props must include isExpanded")
    require("onClose" in panel_src or "onToggleExpand" in panel_src, "Props must include onClose/onToggleExpand")
    require("isActiveTab" in panel_src, "Props must include isActiveTab")
    require("runtimeStatus" in panel_src, "Props must include runtimeStatus")

    # Hook usage
    require("useAgentPaneSubscription" in panel_src, "Component must use useAgentPaneSubscription hook")

    # Header controls
    require('data-debug-id="agent-pane-composer-header"' in panel_src, "Header must have data-debug-id")
    require('data-debug-id="agent-pane-status-dot"' in panel_src, "Status indicator dot must have data-debug-id")
    require("animate-pulse" in panel_src and "bg-emerald-400" in panel_src, "Status dot must pulse green when updating/running")
    require("Terminal Output" in panel_src, "Header must include 'Terminal Output' title")
    require('data-debug-id="agent-pane-interval-tag"' in panel_src, "Refresh interval tag must have data-debug-id")
    require("500ms" in panel_src, "Interval tag must surface 500ms interval")
    require('data-debug-id="agent-pane-refresh-btn"' in panel_src, "Manual refresh button must have data-debug-id")
    require('data-debug-id="agent-pane-copy-btn"' not in panel_src, "No copy button allowed per user requirement")
    require(all(ord(c) <= 0x1F000 for c in panel_src), "Zero emojis allowed in panel")
    require('data-debug-id="agent-pane-collapse-btn"' in panel_src, "Collapse button must have data-debug-id")
    require("chevron-down" in panel_src, "Collapse button must use chevron-down icon")

    # Interactive terminal cursor & keystroke refetch checks (REQ-STREAM-2, REQ-CURSOR-1)
    require("cursorBlink: false" in panel_src, "Terminal cursorBlink must be false")
    require("cursorInactiveStyle: 'none'" in panel_src or 'cursorInactiveStyle: "none"' in panel_src,
            "Terminal cursorInactiveStyle must be 'none'")
    require(".xterm-cursor-layer" in panel_src or "\\x1b[?25l" in panel_src,
            "Component must hide trailing end-cursor via CSS or escape sequence")
    require("50" in panel_src and ("refetch" in panel_src or "setTimeout" in panel_src),
            "Terminal onData must trigger debounced refetch(50ms) on keystrokes")

    # Content pre element & interactive terminal (REQ-INT-3)
    require("@xterm/xterm" in panel_src, "Component must import @xterm/xterm")
    require("@xterm/addon-fit" in panel_src, "Component must import @xterm/addon-fit")
    require('data-debug-id="agent-pane-terminal"' in panel_src, "Component must mount interactive terminal with data-debug-id")
    require("useSendAgentPaneInputMutation" in panel_src, "Component must use useSendAgentPaneInputMutation hook")
    require("max-h-[180px]" in panel_src and "max-h-[300px]" in panel_src, "Component must maintain responsive heights (max-h-[180px] mobile, max-h-[300px] desktop)")
    require("onData" in panel_src, "Terminal must hook onData for keystroke dispatch")
    require("<pre" in panel_src, "Component must render a <pre> element")
    require("chat-scrollbar" in panel_src, "Pre element must use chat-scrollbar class")
    require("max-h-[300px]" in panel_src, "Pre element must use max-h-[300px] class")
    require("overflow-auto" in panel_src, "Pre element must use overflow-auto class")
    require("font-mono" in panel_src, "Pre element must use font-mono class")
    require("text-xs" in panel_src, "Pre element must use text-xs class")
    require("scrollTop" in panel_src and "scrollHeight" in panel_src, "Pre element must handle auto-scroll")

    # Terminal resize & dimension synchronization (REQ-WINSIZE-3)
    require("useSendAgentPaneResizeMutation" in panel_src,
            "Component must import/use useSendAgentPaneResizeMutation hook")
    require("onResize" in panel_src,
            "Terminal must hook onResize for dimensions dispatch")
    require("sendAgentPaneResize" in panel_src,
            "Component must dispatch sendAgentPaneResize")
    require("fitAddon.fit()" in panel_src,
            "Component must trigger fitAddon.fit() on mount/expansion")
    require("window.addEventListener('resize'" in panel_src or 'window.addEventListener("resize"' in panel_src,
            "Component must attach window resize listener for fitAddon.fit()")
    require("width:" in panel_src and "lineLimit:" in panel_src,
            "useAgentPaneSubscription must receive dynamic width and lineLimit")

    # Collapsed guard
    require("if (!isExpanded)" in panel_src or "!isExpanded &&" in panel_src, "Component must hide output when not expanded")

    print("[*] Checking ConversationThreadPage.tsx...")
    require(PAGE_FILE.exists(), "ConversationThreadPage.tsx must exist")
    page_src = PAGE_FILE.read_text(encoding="utf-8")

    # Import
    require("AgentPaneComposerPanel" in page_src, "ConversationThreadPage must import AgentPaneComposerPanel")

    # State
    require("isPaneExpanded" in page_src, "ConversationThreadPage must declare isPaneExpanded state")
    require("setIsPaneExpanded" in page_src, "ConversationThreadPage must declare setIsPaneExpanded setter")

    # Embedded in renderComposer above textarea
    require("<AgentPaneComposerPanel" in page_src, "renderComposer must embed <AgentPaneComposerPanel />")
    panel_idx = page_src.find("<AgentPaneComposerPanel")
    input_idx = page_src.find("conversation-composer-input")
    require(panel_idx != -1 and input_idx != -1 and panel_idx < input_idx,
            "AgentPaneComposerPanel must be embedded above the composer textarea")

    # Button updates
    require('data-debug-id="conversation-request-pane-btn"' in page_src, "Terminal button must exist")
    require("Toggle terminal pane panel" in page_src, "Terminal button title/aria-label must be 'Toggle terminal pane panel'")
    require("aria-pressed={isPaneExpanded}" in page_src, "Terminal button must set aria-pressed={isPaneExpanded}")
    require("setIsPaneExpanded" in page_src, "Terminal button onClick must toggle setIsPaneExpanded")
    require("bg-sky-400/20" in page_src and "text-sky-300" in page_src and "border-sky-400/40" in page_src,
            "Terminal button must use active highlight when isPaneExpanded is true")

    # Legacy chat message send removed
    require("requestPaneFromComposer" not in page_src, "Legacy requestPaneFromComposer must be removed")

    # Backward compatibility for existing pane_capture messages
    require("conversation-pane-capture-" in page_src, "Existing pane_capture message rendering must be preserved")
    require("PaneCaptureOutput" in page_src, "PaneCaptureOutput must be preserved for existing transcript items")

    print("[*] Running tests/ui_agent_pane_composer_panel_test.ts via npx tsx...")
    ts_test = ROOT / "tests" / "ui_agent_pane_composer_panel_test.ts"
    cmd = ["npx", "tsx", str(ts_test)]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        require(False, f"ui_agent_pane_composer_panel_test.ts failed with code {result.returncode}")
    else:
        print(result.stdout.strip())

    print("[+] ALL CHECKS PASSED (REQ-PANE-4, REQ-PANE-5, REQ-WINSIZE-3)")


if __name__ == "__main__":
    main()
