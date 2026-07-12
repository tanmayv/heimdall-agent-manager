#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

UI_FILES = {
    "src/ui/api/daemonApi.ts": [
        "action: 'memory_list'",
        "agent_instance_id:",
        "team_id:",
        "template_key:",
        "project_ids:",
        "role_keys:",
        "task_chain_types:",
    ],
    "src/ui/store/memorySlice.ts": [
        "agentInstanceId",
        "teamId",
        "templateKey",
        "projectIds",
        "roleKeys",
        "taskChainTypes",
        "target:",
        "templateKey: '',",
        "targeting: 'all'",
    ],
    "src/ui/components/App.tsx": [
        "Target:",
        "rec.target || rec.scope",
    ],
    "src/ui/components/SettingsPage.tsx": [
        "Target:",
        "record.target || record.scope",
    ],
    "src/ui/components/MessageBubble.tsx": [
        "Target:",
        "entity.target || entity.scope",
    ],
    "src/ui/components/MemoryManagementPage.tsx": [
        "Target",
        "templateKey",
        "projectIds",
        "roleKeys",
        "taskChainTypes",
    ],
}

FORBIDDEN = [
    "subjectAgent",
    "subject_agent",
    "subjectKey",
    "subject_key",
    "Subject:",
]


def main() -> None:
    missing = []
    forbidden_hits = []

    for rel, required_snippets in UI_FILES.items():
        text = (ROOT / rel).read_text(encoding="utf-8")
        for snippet in required_snippets:
            if snippet not in text:
                missing.append(f"{rel}: missing required snippet {snippet!r}")
        for snippet in FORBIDDEN:
            if snippet in text:
                forbidden_hits.append(f"{rel}: still contains forbidden snippet {snippet!r}")

    if missing or forbidden_hits:
        raise SystemExit("\n".join(missing + forbidden_hits))

    print("ok: UI memory subject-field references removed and canonical targeting snippets present")


if __name__ == "__main__":
    main()
