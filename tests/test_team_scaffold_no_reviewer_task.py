#!/usr/bin/env python3
"""Regression: no team scaffold should emit a standalone review task where the
reviewer role is also the assignee. Reviewer participation must happen via the
lgtm_required participant on the preceding work task, not as its own task.

The user_proxy role is intentionally allowed to be an assignee, because it
represents an explicit human approval step, not the automated `reviewer` role.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
KINDS = ROOT / "src/daemon/team_kinds.odin"

TASK_RE = re.compile(
    r"\{key = \"(?P<key>[^\"]+)\", title_template = \"(?P<title>[^\"]+)\", role_key = \"(?P<role>[^\"]+)\", reviewer_role = \"(?P<reviewer>[^\"]+)\"",
)


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    src = KINDS.read_text()
    matches = list(TASK_RE.finditer(src))
    require(len(matches) > 0, "no scaffold tasks parsed from team_kinds.odin")

    violations = []
    for match in matches:
        role = match.group("role")
        title = match.group("title")
        key = match.group("key")
        if role == "reviewer":
            violations.append(f"key={key} title={title}")

    if violations:
        print("[-] FAIL: scaffold tasks assign the reviewer role as assignee:")
        for entry in violations:
            print(f"    - {entry}")
        sys.exit(1)

    # Sanity: the specific scaffolds we cleaned up must not still have their
    # historical reviewer-as-assignee slots.
    for banned in [
        "role_key = \"reviewer\", reviewer_role = \"coordinator\"",
    ]:
        require(banned not in src, f"forbidden pattern found: {banned}")

    print(f"TEAM SCAFFOLD REVIEWER AUDIT PASSED ({len(matches)} tasks checked)")


if __name__ == "__main__":
    main()
