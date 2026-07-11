#!/usr/bin/env python3
"""Static snapshot checks for coordinator-owned user contact in generated bootstraps."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "src" / "wrapper" / "main.odin"
DOC_BOOTSTRAP = ROOT / "docs" / "teams-v1" / "06-bootstrap.md"
DOC_API = ROOT / "docs" / "teams-v1" / "08-http-and-cli.md"
DOC_INV = ROOT / "docs" / "teams-v1" / "10-review-invariants.md"
PROMPT = ROOT / "src" / "prompts" / "bootstrap_profile_guidance.md"


def require(haystack: str, needle: str, where: str) -> None:
    if needle not in haystack:
        raise AssertionError(f"missing {needle!r} in {where}")


def main() -> None:
    src = WRAPPER.read_text()

    require(src, 'is_coordinator := !is_team_member || role_key == "coordinator"', str(WRAPPER))
    require(src, 'You are the coordinator for free-form user contact', str(WRAPPER))
    require(src, 'Coordinator owns user-facing decisions; route free-form user communication through the coordinator.', str(WRAPPER))
    require(src, 'Do not use direct `chat send-to-user` for normal user contact.', str(WRAPPER))
    require(src, 'For user-facing questions, comment/nudge the coordinator; the coordinator owns free-form user replies.', str(WRAPPER))
    require(src, 'Structured Needs attention approval/action prompts are allowed when the product models them durably.', str(WRAPPER))

    coordinator_tool = '`ham-ctl chat send-to-user --token <token> --user-id operator@local --body <text>` for coordinator-owned user replies.'
    require(src, coordinator_tool, str(WRAPPER))
    coord_idx = src.index(coordinator_tool)
    guard_idx = src.rfind('if is_coordinator {', 0, coord_idx)
    else_idx = src.rfind('} else {', 0, coord_idx)
    if guard_idx < 0 or else_idx > guard_idx:
        raise AssertionError('send-to-user tool guidance is not guarded by the coordinator branch')

    prompt = PROMPT.read_text()
    require(prompt, 'If you are the coordinator, reply to `operator@local`', str(PROMPT))
    require(prompt, 'If you are not the coordinator, do not use direct `chat send-to-user` for normal user contact.', str(PROMPT))
    require(prompt, 'Structured durable `Needs attention` prompts remain allowed', str(PROMPT))
    require(prompt, 'Coordinator CLI example:', str(PROMPT))
    if 'CRITICAL INSTRUCTION' in prompt or 'Always reply to user messages' in prompt:
        raise AssertionError('prompt still contains unconditional direct-user-contact wording')

    for path, invariant in [(DOC_BOOTSTRAP, 'BS-6'), (DOC_API, 'API-4'), (DOC_INV, 'BS-6'), (DOC_INV, 'API-4')]: 
        text = path.read_text()
        require(text, invariant, str(path))
        require(text, 'Needs attention', str(path))

    print('PASS: bootstrap user-contact policy snapshots (BS-6, UI-5, API-4)')


if __name__ == '__main__':
    main()
