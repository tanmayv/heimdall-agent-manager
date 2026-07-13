#!/usr/bin/env python3
"""Static contract checks for coordinator/user-contact and prompt responsiveness.

This locks in two things:
1. generated-bootstrap safety/routing invariants for coordinator-only free-form
   user contact, including chain-scoped replies (RESP-1, RESP-7); and
2. proactive coordinator/guide prompt wording for quick acknowledgement,
   plan-before-action, and pivot updates (RESP-1..RESP-6), while preserving
   guide safety boundaries (RESP-7).

Assertions are phrased as REQ-ID-tagged "any of these phrase variants" checks so
that the contract catches behavioral regressions without freezing unrelated
prompt wording.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "src" / "wrapper" / "main.odin"
DOC_BOOTSTRAP = ROOT / "docs" / "teams-v1" / "06-bootstrap.md"
DOC_API = ROOT / "docs" / "teams-v1" / "08-http-and-cli.md"
DOC_INV = ROOT / "docs" / "teams-v1" / "10-review-invariants.md"
BOOTSTRAP_GUIDANCE = ROOT / "src" / "prompts" / "bootstrap_profile_guidance.md"
COORDINATOR_PROMPT = ROOT / "src" / "prompts" / "coordinator_instructions.md"
GUIDE_PROMPT = ROOT / "src" / "prompts" / "guide_instructions.md"
GUIDE_HANDBOOK = ROOT / "src" / "prompts" / "guide-agent.md"


def require(haystack: str, needle: str, where: Path) -> None:
    if needle not in haystack:
        raise AssertionError(f"missing {needle!r} in {where}")


def forbid(haystack: str, needle: str, where: Path) -> None:
    if needle in haystack:
        raise AssertionError(f"forbidden {needle!r} still present in {where}")


def require_all_regex(haystack: str, patterns, req_id: str, where: Path) -> None:
    """Every pattern (case-insensitive) must match; used to bind one REQ-ID."""
    for pat in patterns:
        if not re.search(pat, haystack, re.IGNORECASE):
            raise AssertionError(
                f"{req_id}: prompt in {where} is missing required concept /{pat}/"
            )


def check_wrapper() -> None:
    src = WRAPPER.read_text(encoding="utf-8")

    # RESP-7: coordinator-only free-form contact + guarded routing preserved.
    require(src, 'is_coordinator := !is_team_member || role_key == "coordinator"', WRAPPER)
    require(src, 'You are the coordinator for free-form user contact', WRAPPER)
    require(src, 'Coordinator owns user-facing decisions; route free-form user communication through the coordinator.', WRAPPER)
    require(src, 'Do not use direct `chat send-to-user` for normal user contact.', WRAPPER)
    require(src, 'For user-facing questions, comment/nudge the coordinator; the coordinator owns free-form user replies.', WRAPPER)
    require(src, 'Structured Needs attention approval/action prompts are allowed when the product models them durably.', WRAPPER)

    # RESP-1: coordinator bootstrap advertises chain-scoped send-to-user.
    require(src, 'chat send-to-user --chain-id <chain_id>', WRAPPER)
    coordinator_tool = '`ham-ctl chat send-to-user --token <token> --user-id operator@local --chain-id <chain_id> --body <text>` for coordinator-owned chain replies.'
    require(src, coordinator_tool, WRAPPER)
    coord_idx = src.index(coordinator_tool)
    guard_idx = src.rfind('if is_coordinator {', 0, coord_idx)
    else_idx = src.rfind('} else {', 0, coord_idx)
    if guard_idx < 0 or else_idx > guard_idx:
        raise AssertionError('chain-scoped send-to-user tool guidance is not guarded by the coordinator branch')


def check_bootstrap_guidance() -> None:
    src = BOOTSTRAP_GUIDANCE.read_text(encoding="utf-8")
    # RESP-7: non-coordinator agents must not initiate free-form user contact.
    require(src, 'The **only** free-form user channel is the task-chain coordinator.', BOOTSTRAP_GUIDANCE)
    require(src, 'Do **not** call `chat send-to-user` with chain context.', BOOTSTRAP_GUIDANCE)
    require(src, 'Structured, product-modeled durable `Needs attention` prompts', BOOTSTRAP_GUIDANCE)
    # Old unconditional/direct-contact wording must not creep back in.
    forbid(src, 'CRITICAL INSTRUCTION', BOOTSTRAP_GUIDANCE)
    forbid(src, 'Always reply to user messages', BOOTSTRAP_GUIDANCE)


def check_coordinator_prompt() -> None:
    src = COORDINATOR_PROMPT.read_text(encoding="utf-8")

    # RESP-1: exact chain-scoped command must be present in the coordinator prompt.
    require(
        src,
        '`ham-ctl chat send-to-user --token <token> --user-id operator@local --chain-id <chain_id> --body <text>`',
        COORDINATOR_PROMPT,
    )

    # RESP-2: quick acknowledgement + next-step/why before tool/investigation/delegation work.
    require_all_regex(
        src,
        [
            r"acknowledge[^\n]*\b(promptly|quick|first|before)\b",
            r"before[^\n]*\b(tool|investigat|delegat|research|deeper work)",
            r"next (action|step)[^\n]*\bwhy\b|state[^\n]*next (action|step)",
        ],
        "RESP-2",
        COORDINATOR_PROMPT,
    )

    # RESP-3: send another chain-scoped update before materially pivoting.
    require_all_regex(
        src,
        [
            r"pivot",
            r"before[^\n]*pivot|pivot[^\n]*update|another[^\n]*update",
        ],
        "RESP-3",
        COORDINATOR_PROMPT,
    )

    # Responsiveness must not be smothered by the older "minimize contact" framing.
    require_all_regex(
        src,
        [r"do not (hold back|delay|withhold)[^\n]*acknowledg|acknowledg[^\n]*don't[^\n]*batch|acknowledg[^\n]*before[^\n]*batch"],
        "RESP-2",
        COORDINATOR_PROMPT,
    )


def check_guide_prompt() -> None:
    src = GUIDE_PROMPT.read_text(encoding="utf-8")
    # RESP-4: quick acknowledgement with intended next step/why.
    require_all_regex(
        src,
        [
            r"quick[^\n]*initial response|respond[^\n]*quickly|acknowledge[^\n]*quick",
            r"next step[^\n]*why|why[^\n]*next step|immediate next step",
        ],
        "RESP-4",
        GUIDE_PROMPT,
    )
    # RESP-5: notify before material pivots / additional user-visible actions.
    require_all_regex(
        src,
        [r"pivot|before[^\n]*additional[^\n]*(action|investigat|coordination)"],
        "RESP-5",
        GUIDE_PROMPT,
    )
    # RESP-7: guide safety boundaries preserved.
    require(src, 'Do not silently mutate project/task/user state.', GUIDE_PROMPT)
    require(src, 'Avoid coding or directly editing project files yourself.', GUIDE_PROMPT)


def check_guide_handbook() -> None:
    src = GUIDE_HANDBOOK.read_text(encoding="utf-8")
    # RESP-4: quick acknowledgement + intended next step/why.
    require_all_regex(
        src,
        [
            r"respond to the user quickly|quick[^\n]*initial|acknowledge the request",
            r"next step[^\n]*why|why[^\n]*next step|immediate next step",
        ],
        "RESP-4",
        GUIDE_HANDBOOK,
    )
    # RESP-5: material-pivot update requirement.
    require_all_regex(
        src,
        [r"pivot"],
        "RESP-5",
        GUIDE_HANDBOOK,
    )
    # RESP-7: guide safety boundaries preserved.
    require(src, 'Avoid coding or directly editing project files yourself.', GUIDE_HANDBOOK)
    require(src, 'route through the chain coordinator', GUIDE_HANDBOOK)


def check_docs() -> None:
    for path, invariant in [
        (DOC_BOOTSTRAP, 'BS-6'),
        (DOC_API, 'API-4'),
        (DOC_INV, 'BS-6'),
        (DOC_INV, 'API-4'),
    ]:
        text = path.read_text(encoding="utf-8")
        require(text, invariant, path)
        require(text, 'Needs attention', path)


def main() -> None:
    check_wrapper()
    check_bootstrap_guidance()
    check_coordinator_prompt()
    check_guide_prompt()
    check_guide_handbook()
    check_docs()
    print('PASS: bootstrap/prompt responsiveness policy snapshots (RESP-1..RESP-7, BS-6, API-4)')


if __name__ == '__main__':
    main()
