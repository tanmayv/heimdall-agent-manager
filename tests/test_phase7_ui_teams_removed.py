#!/usr/bin/env python3
"""Phase 7 UI regression: no teams/kinds, default-agent settings, skills visible."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    rel: (ROOT / rel).read_text(encoding="utf-8")
    for rel in [
        "src/ui/components/App.tsx",
        "src/ui/components/ChainEditor.tsx",
        "src/ui/components/SettingsPage.tsx",
        "src/ui/components/MemoryManagementPage.tsx",
        "src/ui/components/AgentPicker.tsx",
        "src/ui/api/daemonApi.ts",
        "src/ui/api/endpoints/workspace.ts",
        "src/ui/api/endpoints/settings.ts",
        "src/ui/api/chainViewCache.ts",
        "src/ui/api/heimdallApi.ts",
        "src/ui/store/homeSlice.ts",
        "src/ui/store/taskSlice.ts",
        "AGENTS.md",
    ]
}


def require(cond: bool, message: str):
    if not cond:
        raise AssertionError(message)


def all_text() -> str:
    # Broad proof is scoped to active UI source. AGENTS.md is checked separately
    # for debug-id registration and may mention historical docs paths.
    return "\n".join(value for key, value in FILES.items() if key != "AGENTS.md")


def main():
    app = FILES["src/ui/components/App.tsx"]
    chain_editor = FILES["src/ui/components/ChainEditor.tsx"]
    settings = FILES["src/ui/components/SettingsPage.tsx"]
    memory = FILES["src/ui/components/MemoryManagementPage.tsx"]
    daemon_api = FILES["src/ui/api/daemonApi.ts"]
    workspace_api = FILES["src/ui/api/endpoints/workspace.ts"]
    settings_api = FILES["src/ui/api/endpoints/settings.ts"]
    home = FILES["src/ui/store/homeSlice.ts"]
    text = all_text()

    # TR-14: new-chain modal is goal/project/VCS only; no kind/scaffold selector or team progress.
    for required in [
        'data-debug-id="new-chain-title-input"',
        'data-debug-id="new-chain-goal-textarea"',
        'data-debug-id="new-chain-project-select"',
        'data-debug-id="new-chain-wants-vcs-checkbox"',
        'data-debug-id="new-chain-create-btn"',
        'data-debug-id="new-chain-skill-note"',
        "coordinator planning task",
    ]:
        require(required in app, f"new chain mock element missing: {required}")
    for forbidden in [
        'new-chain-kind-select',
        'new-chain-scaffold-select',
        'NEW_CHAIN_KIND_SCAFFOLD_DEFAULT_KEY',
        'kindOptionLabel',
        'scaffoldOptionLabel',
        'findTeamKind',
        'teamKinds',
        'teamId',
        'team_id',
        'Team allocated',
    ]:
        require(forbidden not in app, f"App still contains removed chain team/kind/scaffold surface: {forbidden}")
    for forbidden in ['kind:', 'scaffold:', 'no_scaffold:']:
        require(forbidden not in home, f"homeSlice still sends removed chain-create field: {forbidden}")

    # TR-14: no /teams API dependency and no chain roster/add-member editor.
    for forbidden in ['/teams', 'fetchTeam', 'addTeamMember', 'useFetchTeamQuery', 'Team']:
        require(forbidden not in workspace_api, f"workspace API still exposes team surface: {forbidden}")
    require('fetchTeam' not in daemon_api and 'addTeamMember' not in daemon_api and '/teams' not in daemon_api, "daemonApi still exposes /teams helpers")
    for forbidden in ['chain-editor-roster', 'addTeamMember', 'teamId', 'team_id', 'Team member']:
        require(forbidden not in chain_editor, f"ChainEditor still exposes removed team surface: {forbidden}")
    require('chain-editor-participants-panel' in chain_editor, "ChainEditor must show participants guidance instead of roster")

    # TR-15: settings can view/edit role/default-use -> durable agent id map.
    for required in [
        'useFetchAgentDefaultsQuery',
        'useSaveAgentDefaultMutation',
        'settings-default-agents-panel',
        'settings-default-agents-refresh-btn',
        'settings-default-agents-save-btn',
        'settings-default-agent-use-${use}-picker-btn',
        'DEFAULT_AGENT_USES',
        'conversation',
        'coordinator',
        'worker',
        'reviewer',
    ]:
        require(required in settings, f"default-agent settings UI missing: {required}")
    require('/agents/defaults' in daemon_api, "daemonApi must call /agents/defaults")
    require('fetchAgentDefaults' in settings_api and 'saveAgentDefault' in settings_api, "settings RTKQ defaults endpoints missing")

    # TR-16: memory UI exposes skills as normal memories with no role/team-kind targeting labels.
    for required in ['Agent target', 'Project target', 'target_agent_id', 'target_project_id', 'memory-form-type-select']:
        require(required in memory, f"memory management simplified target/control missing: {required}")
    for forbidden in ['team kind', 'targetTeamKind', 'targetRole', 'target_team_kind', 'target_role', 'role target']:
        require(forbidden.lower() not in memory.lower(), f"memory UI still has removed targeting terminology: {forbidden}")

    # Registered debug ids must include new interactive controls.
    agents_md = FILES['AGENTS.md']
    for required in ['new-chain-wants-vcs-checkbox', 'new-chain-create-btn', 'settings-default-agents-panel', 'settings-default-agent-use-${use}-picker-btn', 'chain-editor-participants-panel']:
        require(required in agents_md, f"AGENTS.md missing debug id registration: {required}")

    # Broad source proof for the scoped UI modules.
    for forbidden in ['fetchTeam', 'addTeamMember', 'useFetchTeamQuery', 'teamByChainId', 'teamKinds', 'new-chain-kind-select', 'new-chain-scaffold-select', '/teams']:
        require(forbidden not in text, f"scoped UI source still contains forbidden symbol: {forbidden}")

    print('test_phase7_ui_teams_removed: ok')


if __name__ == '__main__':
    main()
