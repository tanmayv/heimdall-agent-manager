#!/usr/bin/env python3
"""Static service-boundary checks for the RTK Query UI request architecture."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC_UI = ROOT / "src" / "ui"
COMPONENTS_DIR = SRC_UI / "components"
API_ENDPOINTS_DIR = SRC_UI / "api" / "endpoints"
WS_INVALIDATION = SRC_UI / "api" / "wsInvalidation.ts"
APP = COMPONENTS_DIR / "App.tsx"
SETTINGS = COMPONENTS_DIR / "SettingsPage.tsx"
TODO_EXCEPTION_RE = re.compile(r"TODO\(rtkq-migration owner=task-[^)]+\)")
TAG_TYPE_RE = re.compile(r"type:\s*'([A-Za-z][A-Za-z0-9]*)'")
LEGACY_COMPONENT_THUNKS = [
    "fetchSelectedTaskLog",
    "fetchTasksForChain",
    "fetchSelectedChat",
    "fetchGuideChat",
    "refreshConversationSummaries",
    "refreshTaskBoard",
]
ORPHAN_INVALIDATION_ALLOWLIST: set[str] = set()
FOLLOW_UP_DOMAIN_GUARDS = {
    # Flip migrated=True as each follow-up domain becomes RTKQ-authoritative.
    "agents": {
        "migrated": True,
        "legacy_selector_patterns": [r"state\.chat\.(agents|agentIdentities)\b"],
        "manual_poller_symbols": ["refreshAgents"],
    },
    "memory": {
        "migrated": True,
        "legacy_selector_patterns": [r"state\.memory\.(recordsById|recordIds|historyById)\b"],
        "manual_poller_symbols": ["refreshMemory", "fetchMemoryDetail"],
    },
    "attention": {
        "migrated": True,
        "legacy_selector_patterns": [r"state\.attention\.(chatApprovalsById|chatApprovalIds|mergeDecisionsById|mergeDecisionIds|federationPeerBlocksById|federationPeerBlockIds)\b"],
        "manual_poller_symbols": ["refreshChatApprovals", "refreshMergeDecisions", "tickChatApprovalExpiry"],
    },
    "workspace": {
        "migrated": True,
        "legacy_selector_patterns": [r"state\.chainView\??\.(workspaceByChainId|teamByChainId|mergePreviewByChainId|workspaceDiffByChainId|focusByChainId|lastPeriodicRefreshByChainId|lastHttpLoadByChainId)\b"],
        "manual_poller_symbols": ["revalidateChainView", "fetchWorkspaceForChain", "fetchWorkspaceDiff", "previewWorkspaceMerge"],
    },
    "chain-metadata": {
        "migrated": True,
        "legacy_selector_patterns": [r"state\.tasks\??\.chainsById\b"],
        "manual_poller_symbols": ["revalidateChainView", "refreshTaskBoard"],
    },
    "projects": {
        "migrated": True,
        "legacy_selector_patterns": [r"state\.projects\??\.(projectsById|projectIds|loading|detailLoading|mutating)\b"],
        "manual_poller_symbols": [],
        "component_fetch_patterns": [
            r"refreshProjects\(",
            r"fetchProjectDetail\(",
            r"createProjectFromUi\(",
            r"updateProjectFromUi\(",
            r"deleteProjectFromUi\(",
            r"daemonApi\.listProjects\(",
            r"daemonApi\.showProject\(",
            r"daemonApi\.createProject\(",
            r"daemonApi\.updateProject\(",
            r"daemonApi\.deleteProject\(",
            r"daemonApi\.reorderProjects\(",
        ],
    },
    "settings": {
        "migrated": True,
        "legacy_selector_patterns": [
            r"state\.chat\??\.preferences\b",
            r"state\.chat\??\.settingsTemplates\b",
            r"state\.chat\??\.settingsProviders\b",
            r"state\.chat\??\.userPreferences\b",
        ],
        "manual_poller_symbols": [],
        "component_fetch_patterns": [
            r"fetchPreferences\(",
            r"refreshSettingsCatalog\(",
            r"saveUserPreference\(",
            r"daemonApi\.fetchPreferences\(",
            r"daemonApi\.savePreference\(",
            r"daemonApi\.listAgentTemplates\(",
            r"daemonApi\.listAgentProviders\(",
        ],
    },
    "artifacts": {
        "migrated": True,
        "legacy_selector_patterns": [],
        "manual_poller_symbols": [],
        "component_fetch_patterns": [
            r"daemonApi\.listArtifacts\(",
            r"daemonApi\.fetchArtifactMeta\(",
            r"daemonApi\.createArtifact\(",
            r"daemonApi\.updateArtifact\(",
            r"daemonApi\.deleteArtifact\(",
            r"setArtifacts\(",
            r"refreshArtifacts\(",
        ],
    },
}


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


def endpoint_files() -> list[Path]:
    return sorted(API_ENDPOINTS_DIR.glob("*.ts"))


def extract_tag_types(text: str) -> set[str]:
    return set(TAG_TYPE_RE.findall(text))


def extract_property_expressions(text: str, property_name: str) -> list[str]:
    marker = f"{property_name}:"
    expressions: list[str] = []
    cursor = 0
    while True:
        start = text.find(marker, cursor)
        if start < 0:
            return expressions
        index = start + len(marker)
        while index < len(text) and text[index].isspace():
            index += 1
        expr_start = index
        paren_depth = 0
        bracket_depth = 0
        brace_depth = 0
        in_single = False
        in_double = False
        in_template = False
        escaped = False
        while index < len(text):
            ch = text[index]
            if escaped:
                escaped = False
                index += 1
                continue
            if in_single:
                if ch == "\\":
                    escaped = True
                elif ch == "'":
                    in_single = False
                index += 1
                continue
            if in_double:
                if ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_double = False
                index += 1
                continue
            if in_template:
                if ch == "\\":
                    escaped = True
                elif ch == "`":
                    in_template = False
                index += 1
                continue
            if ch == "'":
                in_single = True
            elif ch == '"':
                in_double = True
            elif ch == "`":
                in_template = True
            elif ch == "(":
                paren_depth += 1
            elif ch == ")":
                paren_depth = max(0, paren_depth - 1)
            elif ch == "[":
                bracket_depth += 1
            elif ch == "]":
                bracket_depth = max(0, bracket_depth - 1)
            elif ch == "{":
                brace_depth += 1
            elif ch == "}":
                brace_depth = max(0, brace_depth - 1)
            elif ch == "," and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0:
                expressions.append(text[expr_start:index].strip())
                cursor = index + 1
                break
            index += 1
        else:
            expressions.append(text[expr_start:].strip())
            return expressions


def extract_property_tag_types(text: str, property_name: str) -> set[str]:
    tags: set[str] = set()
    for expression in extract_property_expressions(text, property_name):
        tags |= extract_tag_types(expression)
    return tags


def assert_tag_extraction_self_test() -> None:
    sample = """
    const sample = build.query({
      providesTags: [{ type: 'ProvidedTag', id: 'ALL' }],
      invalidatesTags: [{ type: 'InvalidatedTag', id: 'ALL' }],
    });
    """
    require(
        extract_property_tag_types(sample, "providesTags") == {"ProvidedTag"},
        "providesTags extraction must ignore tags from neighboring invalidatesTags expressions",
    )
    require(
        extract_property_tag_types(sample, "invalidatesTags") == {"InvalidatedTag"},
        "invalidatesTags extraction must ignore tags from neighboring providesTags expressions",
    )


def provided_tag_types() -> set[str]:
    provided: set[str] = set()
    for path in endpoint_files():
        provided |= extract_property_tag_types(read(path), "providesTags")
    return provided


def invalidated_tag_types() -> set[str]:
    invalidated = extract_tag_types(read(WS_INVALIDATION))
    for path in endpoint_files():
        text = read(path)
        if "invalidatesTags" in text:
            invalidated |= extract_tag_types(text)
    return invalidated


def assert_no_orphan_invalidations() -> None:
    invalidated = invalidated_tag_types()
    provided = provided_tag_types()
    orphaned = invalidated - provided
    unexpected = sorted(orphaned - ORPHAN_INVALIDATION_ALLOWLIST)
    stale_allowlist = sorted(ORPHAN_INVALIDATION_ALLOWLIST - orphaned)

    require(
        not unexpected,
        (
            "orphan tag invalidations without providers: "
            f"{unexpected}; allowed transitional no-op tags are {sorted(ORPHAN_INVALIDATION_ALLOWLIST)}"
        ),
    )
    require(
        not stale_allowlist,
        (
            "orphan invalidation allow-list is stale; remove migrated entries: "
            f"{stale_allowlist}"
        ),
    )


def assert_migrated_domains_use_single_projection(component_files: list[Path]) -> None:
    for domain, config in FOLLOW_UP_DOMAIN_GUARDS.items():
        if not config["migrated"]:
            continue
        for path in component_files:
            for pattern in config["legacy_selector_patterns"]:
                lines = line_numbers_with(path, pattern)
                require(
                    not lines,
                    (
                        f"{path.relative_to(ROOT)} still reads legacy slice state for migrated domain "
                        f"{domain}: pattern={pattern!r} lines={lines}"
                    ),
                )


def assert_no_manual_pollers_for_migrated_domains(component_files: list[Path]) -> None:
    for domain, config in FOLLOW_UP_DOMAIN_GUARDS.items():
        if not config["migrated"] or not config["manual_poller_symbols"]:
            continue
        for path in component_files:
            lines = read(path).splitlines()
            for index, line in enumerate(lines, start=1):
                if "setInterval(" not in line:
                    continue
                start = max(0, index - 6)
                end = min(len(lines), index + 20)
                context = "\n".join(lines[start:end])
                matched = [symbol for symbol in config["manual_poller_symbols"] if symbol in context]
                require(
                    not matched,
                    (
                        f"{path.relative_to(ROOT)} still uses component-level manual pollers for migrated domain "
                        f"{domain}: setInterval near line {index} references {matched}"
                    ),
                )


def assert_no_component_owned_fetch_mirrors_for_migrated_domains(component_files: list[Path]) -> None:
    for domain, config in FOLLOW_UP_DOMAIN_GUARDS.items():
        patterns = config.get("component_fetch_patterns", [])
        if not config["migrated"] or not patterns:
            continue
        for path in component_files:
            for pattern in patterns:
                lines = line_numbers_with(path, pattern)
                require(
                    not lines,
                    (
                        f"{path.relative_to(ROOT)} still performs component-owned fetch/mirror work for migrated domain "
                        f"{domain}: pattern={pattern!r} lines={lines}"
                    ),
                )


def main() -> None:
    app = read(APP)
    settings = read(SETTINGS)
    component_files = list(COMPONENTS_DIR.rglob("*.ts*"))

    assert_tag_extraction_self_test()
    assert_no_orphan_invalidations()
    assert_migrated_domains_use_single_projection(component_files)
    assert_no_manual_pollers_for_migrated_domains(component_files)
    assert_no_component_owned_fetch_mirrors_for_migrated_domains(component_files)

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
    require("useListAgentsQuery(" in app, "App should use useListAgentsQuery for live agent reads")
    require("useFetchAgentQuery(" in app, "App should use useFetchAgentQuery for live agent detail reads")
    require("useListChatApprovalsQuery(" in app, "App should use useListChatApprovalsQuery for live attention approval reads")
    require("useFetchAttentionQuery(" in app, "App should use useFetchAttentionQuery for live attention/merge reads")
    require("pollingInterval: home.surface === 'attention' ? 15_000 : 0" in app, "App should use RTKQ pollingInterval for attention expiry/refresh instead of manual timers")
    require("guidePanelOpen" in excerpt_after(app, "useListAgentsQuery(undefined, {", 260), "App should use RTKQ pollingInterval while the guide panel is open instead of effect-driven agent refetches")
    for query_name in ["agentsQuery", "projectsQuery", "settingsCatalogQuery"]:
        require(re.search(rf"\[\s*{query_name}\s*(?:,|\])", app) is None, f"App effects/callbacks must not depend on the whole {query_name} object")

    # Direct chat debug panel remains allowed temporarily, but only with an
    # explicit migration exception marker until it is converted to RTKQ hooks.
    require("daemonApi.fetchChat(" not in settings, "SettingsPage must not bypass RTKQ with daemonApi.fetchChat")
    require("useListAgentsQuery(" in settings, "SettingsPage should use useListAgentsQuery for live agent reads")
    memory_page = read(COMPONENTS_DIR / "MemoryManagementPage.tsx")
    require("useListMemoryQuery(" in memory_page, "MemoryManagementPage should use useListMemoryQuery for live memory reads")
    require("useFetchMemoryQuery(" in memory_page, "MemoryManagementPage should use useFetchMemoryQuery for memory detail reads")
    require("useFetchMemoryHistoryQuery(" in memory_page, "MemoryManagementPage should use useFetchMemoryHistoryQuery for memory history reads")
    require("useListChainsQuery(" in app, "App should use useListChainsQuery for chain metadata reads")
    require("useFetchChainQuery(" in app, "App should use useFetchChainQuery for chain detail metadata reads")
    require("useFetchWorkspaceQuery(" in app, "App should use useFetchWorkspaceQuery for workspace reads")
    require("useLazyFetchWorkspaceDiffQuery(" in app, "App should use useLazyFetchWorkspaceDiffQuery for scoped workspace diffs")
    require("useLazyPreviewWorkspaceMergeQuery(" in app, "App should use useLazyPreviewWorkspaceMergeQuery for merge previews")
    require("useListProjectsQuery(" in app, "App should use useListProjectsQuery for project list reads")
    require("skip: !session.connected || !session.clientToken" in app, "App project reads should wait for a connected session before subscribing")
    require("skip: !session.connected || !session.daemonUrl" in app, "App settings catalog reads should wait for a connected session before subscribing")
    require("useCreateProjectMutation(" in app, "App should use useCreateProjectMutation for new project creation")
    require("useFetchSettingsCatalogQuery(" in app, "App should use useFetchSettingsCatalogQuery for settings catalog reads")
    require("useListProjectsQuery(" in settings, "SettingsPage should use useListProjectsQuery for project list reads")
    require("useFetchProjectQuery(" in settings, "SettingsPage should use useFetchProjectQuery for project detail reads")
    require("useUpdateProjectMutation(" in settings, "SettingsPage should use useUpdateProjectMutation for project edits")
    require("useDeleteProjectMutation(" in settings, "SettingsPage should use useDeleteProjectMutation for project deletes")
    require("useFetchPreferencesQuery(" in settings, "SettingsPage should use useFetchPreferencesQuery for preferences reads")
    require("useFetchSettingsCatalogQuery(" in settings, "SettingsPage should use useFetchSettingsCatalogQuery for provider/template reads")
    require("useSavePreferenceMutation(" in settings, "SettingsPage should use useSavePreferenceMutation for preference saves")
    require(settings.count("skip: !effectiveSession?.connected || !effectiveSession?.clientToken") >= 3, "SettingsPage project list/detail/preference reads should wait for a connected session before subscribing")
    require("skip: !effectiveSession?.connected || !effectiveSession?.daemonUrl" in settings, "SettingsPage catalog reads should wait for a connected session before subscribing")
    require("defaultsDirty" in settings and "if (defaultsDirty) return;" in settings, "ProvidersPanel should preserve dirty provider/tier drafts across preference/catalog refetches")
    artifacts_endpoint = read(API_ENDPOINTS_DIR / "artifacts.ts")
    artifact_upload = read(COMPONENTS_DIR / "ArtifactUpload.tsx")
    artifact_viewer = read(COMPONENTS_DIR / "ArtifactViewer.tsx")
    chain_artifacts = read(COMPONENTS_DIR / "ChainArtifactsPanel.tsx")
    markdown_body = read(COMPONENTS_DIR / "MarkdownBody.tsx")
    require("useListArtifactsQuery(" in app and "useListArtifactsQuery(" in chain_artifacts, "Artifact list surfaces should use useListArtifactsQuery")
    require("useFetchArtifactMetaQuery(" in artifact_viewer, "ArtifactViewer should use useFetchArtifactMetaQuery for metadata")
    require("useFetchArtifactTextContentQuery(" in artifact_viewer, "ArtifactViewer should use viewer-lived useFetchArtifactTextContentQuery for text previews")
    require("keepUnusedDataFor: 0" in artifacts_endpoint, "Artifact content cache should be viewer-lived and released immediately when unused")
    require("useCreateArtifactMutation(" in artifact_upload, "Artifact uploads should use useCreateArtifactMutation")
    require("artifactsApi.endpoints.fetchArtifactMeta.initiate" in markdown_body, "Markdown artifact chips should resolve metadata through RTKQ")
    for marker in ["setArtifacts(", "refreshArtifacts(", "daemonApi.listArtifacts(", "daemonApi.fetchArtifactMeta(", "daemonApi.createArtifact("]:
        require(marker not in app and marker not in chain_artifacts and marker not in artifact_viewer and marker not in artifact_upload and marker not in markdown_body, f"Artifact components should not keep component-owned fetched artifact mirrors or bypass RTKQ via {marker}")
    chain_editor = read(ROOT / "src/ui/components/ChainEditor.tsx")
    require("onRefresh" not in chain_editor, "ChainEditor should not own manual refresh fan-out; RTKQ mutation invalidation should refresh chain/team metadata")
    require("workspaceApi.endpoints.updateChain.initiate" in chain_editor, "ChainEditor chain metadata saves should use RTKQ mutation invalidation")
    require("workspaceApi.endpoints.updateChainStatus.initiate" in chain_editor, "ChainEditor chain status saves should use RTKQ mutation invalidation")
    require("workspaceApi.endpoints.addTeamMember.initiate" in chain_editor, "ChainEditor team mutations should use RTKQ mutation invalidation")
    for marker in ["daemonApi.updateTaskChain(", "daemonApi.updateTaskChainStatus(", "daemonApi.addTeamMember("]:
        require(marker not in chain_editor, f"ChainEditor should not bypass RTKQ mutation invalidation via {marker}")
    memory_endpoint = read(API_ENDPOINTS_DIR / "memory.ts")
    require("memoryEventMayChangeListMembership" in memory_endpoint, "Memory WS handling should identify membership/status-changing events")
    require("proposed" in memory_endpoint and "approved" in memory_endpoint and "archived" in memory_endpoint, "Memory WS membership handling should cover proposed/approved/archived daemon events")
    require("{ type: 'Memory', id: 'ALL' }" in memory_endpoint, "Memory WS membership/status changes should invalidate Memory:ALL so list/applicable queries refetch")
    require(TODO_EXCEPTION_RE.search(settings) is not None, "SettingsPage legacy chat thunk usage must be explicitly marked TODO(rtkq-migration owner=task-...)")
    require(TODO_EXCEPTION_RE.search(app) is not None, "App legacy task/chat thunk usage must be explicitly marked TODO(rtkq-migration owner=task-...)")

    # Migrated mutation/send handlers in App should not chain manual refresh thunks.
    task_mutation_blocks = [
        excerpt_after(app, "onAddComment={async (task: any, body: string) => {"),
        excerpt_after(app, "onSetTaskStatus={async (task: any, status: string, body: string) => {"),
        excerpt_after(app, "onVoteTask={async (task: any, approved: boolean, comment?: string) => {"),
        excerpt_after(app, "onNudgeTask={async (task: any, body: string) => {"),
        excerpt_after(app, "onAssignTask={async (task: any, agentInstanceId: string, pickerResult?: any) => {"),
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
