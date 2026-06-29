#!/usr/bin/env python3
"""Regression guard for the chat-window Restart control."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT_PANE = ROOT / "src" / "ui" / "components" / "ChatPane.tsx"


def main() -> None:
    src = CHAT_PANE.read_text()
    assert "chat-agent-restart-btn" in src, "Restart button debug id missing"
    assert "runAgentAction('restart')" in src, "Restart button must invoke restart action"
    assert "timeInSec: 1" in src, "Restart should use force-stop timeout before starting"
    assert "waitForAgentStopped" in src, "Restart should wait/poll for stop before restart start"
    assert "startAgentInstance(agent)" in src, "Restart should start the same selected agent"
    assert "fresh run directory" in src, "Restart button should document fresh run semantics"
    print("CHATPANE RESTART CONTROL REGRESSION PASSED")


if __name__ == "__main__":
    main()
