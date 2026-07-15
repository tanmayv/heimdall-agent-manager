#!/usr/bin/env python3
"""Static regression checks for conversation-shell UI wiring (REQ-CONV-011/012/014)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"
AGENTS = ROOT / "AGENTS.md"


def require(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    agents = AGENTS.read_text(encoding="utf-8")

    for needle, message in [
        ('data-debug-id="sidebar-new-conversation-btn"', "missing sidebar new conversation button debug id"),
        ('data-debug-id="sidebar-conversation-list"', "missing sidebar conversation list debug id"),
        ('data-debug-id={`conversation-thread-${entry.agentInstanceId}`}', "missing conversation thread row debug id"),
        ('data-debug-id={`conversation-thread-open-btn-${entry.agentInstanceId}`}', "missing conversation thread open button debug id"),
        ('data-debug-id="conversation-model-select"', "missing conversation model/provider select debug id"),
        ('data-debug-id="conversation-tier-select"', "missing conversation tier select debug id"),
        ('data-debug-id={conversationAgent ? \'conversation-composer-input\' : \'agent-detail-chat-input\'}', "missing conversation composer input debug id wiring"),
        ('data-debug-id={conversationAgent ? \'conversation-composer-send-btn\' : \'agent-detail-chat-send-btn\'}', "missing conversation composer send debug id wiring"),
        ('data-debug-id="chain-tasks-toggle-btn"', "missing chain tasks toggle button debug id"),
        ('data-debug-id="chain-task-pane"', "missing chain task pane debug id"),
        ('Conversations', "conversation-first sidebar heading missing"),
        ('Active task chains', "active task chains section heading missing"),
        ('This thread resumes on the same exact conversation instance and keeps its full history.', "conversation detail copy missing exact-resume affordance"),
    ]:
        require(app, needle, message)

    for needle, message in [
        ('sidebar-new-conversation-btn', "AGENTS.md missing sidebar new conversation registry entry"),
        ('conversation-thread-${instanceId}', "AGENTS.md missing conversation thread registry entry"),
        ('conversation-thread-open-btn-${instanceId}', "AGENTS.md missing conversation thread open registry entry"),
        ('conversation-model-select', "AGENTS.md missing conversation model select registry entry"),
        ('conversation-tier-select', "AGENTS.md missing conversation tier registry entry"),
        ('chain-tasks-toggle-btn', "AGENTS.md missing chain tasks toggle registry entry"),
        ('chain-task-pane', "AGENTS.md missing chain task pane registry entry"),
        ('conversation-composer-input', "AGENTS.md missing conversation composer input registry entry"),
        ('conversation-composer-send-btn', "AGENTS.md missing conversation composer send registry entry"),
    ]:
        require(agents, needle, message)

    print("PASS: conversation UI static")


if __name__ == "__main__":
    main()
