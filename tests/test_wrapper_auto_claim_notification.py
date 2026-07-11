#!/usr/bin/env python3
"""Regression guard: wrapper must NOT filter task events by author/status.

Historically the wrapper suppressed noisy ``system-auto`` task events before
they reached the tmux pane, with narrow exemptions for auto-claim and
auto-approve. This masked legitimate coordinator-actionable events
(chain-19f4b3d0617 RCA).

Per operator direction the fix is source-side: the daemon is the sole
authority on whether an event is generated and to whom. The wrapper delivers
every ``task_event`` it receives, except events it authored itself
(self-authored suppression stays).

This test enforces that the wrapper stays that way and does not regrow
author/status-based filtering.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "src" / "wrapper" / "main.odin"


def main() -> None:
    src = WRAPPER.read_text()

    forbidden_helpers = [
        "task_event_is_auto_claim",
        "task_event_is_actionable_system_auto",
    ]
    for name in forbidden_helpers:
        assert name not in src, (
            f"wrapper regressed: helper {name!r} reintroduces author-based filtering; "
            "daemon is the sole recipient authority now"
        )

    forbidden_suppression_snippets = [
        'suppressed system-auto task event',
        'strings.has_prefix(changed_by, "system-auto")',
    ]
    for snippet in forbidden_suppression_snippets:
        assert snippet not in src, (
            f"wrapper regressed: suppression pattern {snippet!r} reintroduces "
            "wrapper-side filtering that hides coordinator-actionable events"
        )

    # Self-authored suppression must remain — an agent should not be notified of
    # its own actions.
    assert 'suppressed self-authored task event' in src, (
        "self-authored suppression is required; do not remove it"
    )
    assert 'changed_by == agent_instance_id' in src, (
        "self-authored suppression check must remain in handle_task_event"
    )

    print("WRAPPER SOURCE-SIDE ROUTING REGRESSION GUARD PASSED")


if __name__ == "__main__":
    main()
