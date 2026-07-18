#!/usr/bin/env python3
"""Static contract for agent working/stopped banners above chat composers."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "src" / "ui" / "components" / "App.tsx").read_text(encoding="utf-8")
SETTINGS = (ROOT / "src" / "ui" / "components" / "SettingsPage.tsx").read_text(encoding="utf-8")
AGENTS = (ROOT / "AGENTS.md").read_text(encoding="utf-8")


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f"missing {label}: {snippet}")


def main() -> None:
    for snippet in [
        "function ChatRuntimeBanner",
        "function agentWorkingBannerState",
        "function agentCurrentTaskLabel",
        "activity === 'active'",
        "return '';",
        "{label} is {mode}",
        "Task: ${task.title}",
        "${debugPrefix}-status-start-btn",
        "debugPrefix=\"agent-detail-chat\"",
        "debugPrefix=\"conversation-composer\"",
        "debugPrefix=\"home-running-agent-chat\"",
        "debugPrefix=\"guide-chat\"",
        "debugPrefix=\"chain-coordinator\"",
    ]:
        require(APP, snippet, "App runtime banner")

    for snippet in [
        "<ChatRuntimeBanner agent={agent} tasksById={tasksById} debugPrefix=\"agent-detail-chat\"",
        "<ChatRuntimeBanner agent={locallyStopped ? { ...agent, status: 'stopped'",
        "<ChatRuntimeBanner agent={selectedAgent} debugPrefix=\"home-running-agent-chat\"",
        "<ChatRuntimeBanner agent={agent || { id: GUIDE_AGENT_ID",
        "<ChatRuntimeBanner agent={coordinatorAgent || { id: coordinatorAgentId",
    ]:
        require(APP, snippet, "banner placement")

    require(SETTINGS, "function SettingsChatRuntimeBanner", "settings banner helper")
    require(SETTINGS, "settings-direct-chat-status-start-btn", "settings start button")
    require(SETTINGS, "<SettingsChatRuntimeBanner agent={selectedAgent}", "settings banner placement")

    for debug_id in [
        "agent-detail-chat-status-start-btn",
        "conversation-composer-status-start-btn",
        "home-running-agent-chat-status-start-btn",
        "guide-chat-status-start-btn",
        "chain-coordinator-status-start-btn",
        "settings-direct-chat-status-start-btn",
    ]:
        require(AGENTS, debug_id, "debug id registry")

    if "This thread is stopped. Sending will start" in APP:
        raise AssertionError("stopped composer warning should be represented by the status banner")
    print("PASS: chat runtime banners are wired above chat composers")


if __name__ == "__main__":
    main()
