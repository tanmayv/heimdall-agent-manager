#!/usr/bin/env python3
"""Regression guard for wrapper task_event auto-claim notifications.

The wrapper intentionally suppresses noisy system-auto task events, but
system-auto-claim / system_auto:auto_claimed is the signal that an idle agent
has just received active work and must remain visible in the agent pane.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "src" / "wrapper" / "main.odin"


def main() -> None:
    src = WRAPPER.read_text()
    assert "task_event_is_auto_claim" in src, "missing targeted auto-claim allow helper"
    assert 'changed_by == "system-auto-claim"' in src, "system-auto-claim author must be allowed"
    assert 'status != "in_progress"' in src, "auto-claim allow should be status-targeted"
    assert 'Task auto-claimed' in src, "daemon summary text should identify auto-claim notifications"
    assert 'system_auto:auto_claimed' in src, "raw auto-claim marker should be recognized"
    suppress = 'strings.has_prefix(changed_by, "system-auto") && !task_event_is_auto_claim(status, changed_by, body)'
    assert suppress in src, "broad system-auto suppression must exempt targeted auto-claim events"
    print("WRAPPER AUTO-CLAIM NOTIFICATION REGRESSION PASSED")


if __name__ == "__main__":
    main()
