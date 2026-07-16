#!/usr/bin/env python3
"""Static service-boundary checks for the RTK Query UI request architecture."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC_UI = ROOT / "src" / "ui"
COMPONENTS_DIR = SRC_UI / "components"
APP = COMPONENTS_DIR / "App.tsx"
SETTINGS = COMPONENTS_DIR / "SettingsPage.tsx"
TODO_EXCEPTION_RE = re.compile(r"TODO\(rtkq-migration owner=task-[^)]+\)")
LEGACY_COMPONENT_THUNKS = [
    "fetchSelectedTaskLog",
    "fetchTasksForChain",
    "fetchSelectedChat",
    "fetchGuideChat",
    "refreshConversationSummaries",
    "refreshTaskBoard",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def excerpt_after(text: str, marker: str, span: int = 900) -> str:
    idx = text.find(marker)
    require(idx >= 0, f"marker not found: {marker}")
    return text[idx:idx + span]


def line_numbers_with(path: Path, pattern: str) -> list[int]:
    matcher = re.compile(pattern)
    return [index for index, line in enumerate(read(path).splitlines(), start=1) if matcher.search(line)]


def main() -> None:
    app = read(APP)
    settings = read(SETTINGS)
    component_files = list(COMPONENTS_DIR.rglob("*.ts*"))

    # Migrated high-refresh surfaces should not call recurring daemon reads from components.
    forbidden_component_reads = [
        "daemonApi.fetchTaskLog(",
        "daemonApi.fetchChat(",
        "daemonApi.listChainTasks(",
        "daemonApi.listConversations(",
        "daemonApi.markChatRead(",
    ]
    for path in component_files:
        text = read(path)
        for marker in forbidden_component_reads:
            require(marker not in text, f"{path.relative_to(ROOT)} should not call recurring daemon read {marker}")

    # RTKQ cache invalidation/patch utilities must stay inside src/ui/api or tests.
    forbidden_cache_utils = ["invalidateTags(", "upsertQueryData(", "updateQueryData("]
    for path in component_files:
        text = read(path)
        for marker in forbidden_cache_utils:
            require(marker not in text, f"{path.relative_to(ROOT)} should not use RTKQ cache utility {marker}")

    # Legacy task/chat thunk imports and dispatches in components must be fully gone,
    # or explicitly tracked as transitional TODO(rtkq-migration) exceptions with
    # follow-up ownership.
    for path in component_files:
        text = read(path)
        matched = []
        for thunk in LEGACY_COMPONENT_THUNKS:
            import_lines = line_numbers_with(path, rf"\b{thunk}\b")
            dispatch_lines = line_numbers_with(path, rf"dispatch\(\s*{thunk}\(")
            if import_lines or dispatch_lines:
                matched.append({
                    "thunk": thunk,
                    "symbol_lines": import_lines,
                    "dispatch_lines": dispatch_lines,
                })
        if matched:
            require(
                TODO_EXCEPTION_RE.search(text) is not None,
                (
                    f"{path.relative_to(ROOT)} uses legacy task/chat thunks in components; "
                    f"add TODO(rtkq-migration owner=task-...) or finish the migration. "
                    f"Matches: {matched}"
                ),
            )

    # App should use RTKQ hooks for migrated task/chat first-page ownership.
    require("useFetchChainTasksQuery(" in app, "App should use useFetchChainTasksQuery for live chain task reads")
    require("useFetchTaskLogQuery(" in app, "App should use useFetchTaskLogQuery for live task log reads")
    require("useListConversationSummariesQuery(" in app, "App should use useListConversationSummariesQuery for live conversation summaries")

    # Direct chat debug panel remains allowed temporarily, but only with an
    # explicit migration exception marker until it is converted to RTKQ hooks.
    require("daemonApi.fetchChat(" not in settings, "SettingsPage must not bypass RTKQ with daemonApi.fetchChat")
    require(TODO_EXCEPTION_RE.search(settings) is not None, "SettingsPage legacy chat thunk usage must be explicitly marked TODO(rtkq-migration owner=task-...)")
    require(TODO_EXCEPTION_RE.search(app) is not None, "App legacy task/chat thunk usage must be explicitly marked TODO(rtkq-migration owner=task-...)")

    # Migrated mutation/send handlers in App should not chain manual refresh thunks.
    task_mutation_blocks = [
        excerpt_after(app, "onAddComment={async (task: any, body: string) => {"),
        excerpt_after(app, "onSetTaskStatus={async (task: any, status: string, body: string) => {"),
        excerpt_after(app, "onVoteTask={async (task: any, approved: boolean, comment?: string) => {"),
        excerpt_after(app, "onNudgeTask={async (task: any, body: string) => {"),
        excerpt_after(app, "onAssignTask={async (task: any, agentInstanceId: string) => {"),
    ]
    for block in task_mutation_blocks:
        require("refreshTaskBoard(" not in block, "task mutation handlers must not chain refreshTaskBoard")
        require("fetchTasksForChain(" not in block, "task mutation handlers must not chain fetchTasksForChain")
        require("fetchSelectedTaskLog(" not in block, "task mutation handlers must not chain fetchSelectedTaskLog")

    chat_send_blocks = [
        excerpt_after(app, "const sendGuideBody = useCallback(async (body: string) => {"),
        excerpt_after(app, "onSend={async (body: string) => {"),
        excerpt_after(app, "onSendAgentMessage: async (agentId: string, body: string, interrupt = false, runtime: any = {}) => {"),
    ]
    for block in chat_send_blocks:
        require("fetchSelectedChat(" not in block, "chat send handlers must not chain fetchSelectedChat")
        require("fetchGuideChat(" not in block, "chat send handlers must not chain fetchGuideChat")
        require("refreshConversationSummaries(" not in block, "chat send handlers must not chain refreshConversationSummaries")

    print("UI SERVICE BOUNDARIES TEST PASSED")


if __name__ == "__main__":
    main()
