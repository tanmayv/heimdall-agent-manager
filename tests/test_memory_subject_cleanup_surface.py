#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED = {
    "src/wrapper/main.odin": [
        'extract_json_string(text, "target", "")',
        '"target_agent_id":"',
        '"target_project_id":"',
        '/memory/applicable',
        '--target-agent-id <agent_id> --target-project-id <project_id>',
    ],
    "src/ctl/main.odin": [
        '--target-agent-id <agent>',
        '--target-project-id <project>',
        'memory list --token <token> [--target-agent-id <agent>] [--target-project-id <project>]',
    ],
    "src/daemon/memory_service.odin": [
        'target_agent_id',
        'target_project_id',
        'memory_record_applies :: proc(rec: contracts.Memory_Record, target_agent_id, target_project_id: string) -> bool',
    ],
}

FORBIDDEN = {
    "src/wrapper/main.odin": [
        '"action":"memory_list","type":"template","status":"active"',
        'parse_into_memory_records(resp.body, memory_templates, true,',
    ],
    "src/ctl/main.odin": [
        'memory list --token <token> [--agent <agent>] [--scope <scope>]',
        '--project-ids <csv>',
        '--role-keys <csv>',
        '--task-chain-types <csv>',
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

    print("ok: simplified memory targeting surface looks canonical")


if __name__ == "__main__":
    main()
