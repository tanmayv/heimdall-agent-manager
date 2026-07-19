#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

UI_FILES = {
    "src/ui/api/daemonApi.ts": [
        "action: 'memory_list'",
        "target_agent_id",
        "target_project_id",
    ],
    "src/ui/store/memorySlice.ts": [
        "targetAgentId",
        "targetProjectId",
        "targeting: 'all'",
    ],
    "src/ui/components/App.tsx": [
        "Target: {rec.target || 'global'}",
    ],
    "src/ui/components/SettingsPage.tsx": [
        "Target: {record.target || 'global'}",
    ],
    "src/ui/components/MessageBubble.tsx": [
        "Target: <span className=\"text-[#aaa]\">{entity.target || 'global'}</span>",
    ],
    "src/ui/components/MemoryManagementPage.tsx": [
        "Agent target",
        "Project target",
        "target_agent_id",
        "target_project_id",
    ],
}

FORBIDDEN_BY_FILE = {
    "src/ui/components/MemoryManagementPage.tsx": [
        "templateKey",
        "projectIds",
        "roleKeys",
        "taskChainTypes",
        "scope",
        "subjectAgent",
        "subjectKey",
    ],
    "src/ui/store/memorySlice.ts": [
        "templateKey",
        "projectIds",
        "roleKeys",
        "taskChainTypes",
        "scope",
    ],
}


def main() -> None:
    missing = []
    forbidden_hits = []

    for rel, required_snippets in UI_FILES.items():
        text = (ROOT / rel).read_text(encoding="utf-8")
        for snippet in required_snippets:
            if snippet not in text:
                missing.append(f"{rel}: missing required snippet {snippet!r}")
        for snippet in FORBIDDEN_BY_FILE.get(rel, []):
            if snippet in text:
                forbidden_hits.append(f"{rel}: still contains forbidden snippet {snippet!r}")

    if missing or forbidden_hits:
        raise SystemExit("\n".join(missing + forbidden_hits))

    print("ok: UI uses simplified memory target pair only")


if __name__ == "__main__":
    main()
