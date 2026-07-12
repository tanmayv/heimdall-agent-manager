#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED = {
    "src/daemon/user_pref_rest.odin": [
        "for {target} ({status})",
        "for {target}. Review with:",
    ],
    "src/wrapper/main.odin": [
        'extract_json_string(text, "target", "")',
        'replace_all(res, "{target}", target)',
        'for {target} ({status})',
        'for {target}. Review with:',
    ],
    "src/prompts/memory_audit_task_4.md": [
        "target/scope",
        "Target, Scope, Type, Title, Body",
    ],
    "docs/teams-v1/05-memory.md": [
        "project_ids",
        "role_keys",
        "task_chain_types",
        "team_id",
        "template_key",
    ],
    "src/ctl/main.odin": [
        "--agent-instance-id <id>",
        "memory list --token <token> [--agent-instance-id <id>]",
        "deprecated: --subject-key/--subject-agent/--agent are rejected",
    ],
}

FORBIDDEN = {
    "src/daemon/user_pref_rest.odin": ["{subject_agent}"],
    "src/prompts/memory_audit_task_4.md": ["Subject Agent"],
    "docs/teams-v1/05-memory.md": ["subject_key", "subject_agent"],
    "src/ctl/main.odin": [
        "memory list --token <token> [--agent <agent>] [--scope <scope>] [--subject-key <key>]",
    ],
}


def main() -> None:
    errors: list[str] = []

    for rel, snippets in REQUIRED.items():
        text = (ROOT / rel).read_text(encoding="utf-8")
        for snippet in snippets:
            if snippet not in text:
                errors.append(f"{rel}: missing required snippet {snippet!r}")

    for rel, snippets in FORBIDDEN.items():
        text = (ROOT / rel).read_text(encoding="utf-8")
        for snippet in snippets:
            if snippet in text:
                errors.append(f"{rel}: still contains forbidden snippet {snippet!r}")

    if errors:
        raise SystemExit("\n".join(errors))

    print("ok: wrapper/preferences/docs/prompt memory subject cleanup surface looks canonical")


if __name__ == "__main__":
    main()
