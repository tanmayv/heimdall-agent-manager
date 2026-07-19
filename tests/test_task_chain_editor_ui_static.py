#!/usr/bin/env python3
"""Static regression checks for the Task Chain Editor UI surface.

Phase 7 updates: the editor must not expose a team roster or /teams add-member
flow. Task/participant state is the collaboration authority.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")
EDITOR = (ROOT / "src/ui/components/ChainEditor.tsx").read_text(encoding="utf-8")
API = (ROOT / "src/ui/api/daemonApi.ts").read_text(encoding="utf-8")
WORKSPACE_API = (ROOT / "src/ui/api/endpoints/workspace.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}")
        sys.exit(1)


# Dedicated route/page remains reachable from existing ChainView.
require("import ChainEditor from './ChainEditor';" in APP, "App must import ChainEditor")
require("const openChainEditor = useCallback((chainId: string, taskId = '') => {" in APP, "openChainEditor helper missing")
require("updateUrlParams({ chainId, view: 'chain-editor'" in APP, "chain editor route URL update missing")
require("home.surface === 'chain' && selectedChain && urlParams.view === 'chain-editor'" in APP, "chain-editor route branch missing")
require("<ChainEditor" in APP, "App must render ChainEditor")
require('data-debug-id="chain-open-editor-btn"' in APP, "ChainView must expose Open editor entry button")

# Graph navigator, drag/pan, edge rendering, local layout persistence.
for needle, message in [
    ("const STORAGE_PREFIX = 'heimdall.chainEditor.layout.v1:';", "chain layout storage key missing"),
    ("function loadLayout(chainId: string): Record<string, Point> | null", "loadLayout helper missing"),
    ("function saveLayout(chainId: string, positions: Record<string, Point>)", "saveLayout helper missing"),
    ('data-debug-id="chain-editor-graph-card"', "graph card affordance missing"),
    ('data-debug-id="chain-editor-graph-canvas"', "graph canvas debug id missing"),
    ('data-debug-id="chain-editor-graph-autolayout-btn"', "graph auto-layout button missing"),
    ('data-debug-id="chain-editor-graph-fit-btn"', "graph fit button missing"),
    ("onCanvasPointerDown", "canvas pan interaction missing"),
    ("onNodePointerDown", "node drag interaction missing"),
    ("data-debug-id={`chain-editor-edge-${edge.from}-${edge.to}`}", "dependency edge debug id missing"),
    ("void removeEdgeDependency(edge.from, edge.to)", "click-to-remove dependency edge missing"),
]:
    require(needle in EDITOR, message)

# Selected-task card and task mutation affordances remain.
for needle, message in [
    ('data-debug-id="chain-editor-selected-task-card"', "selected-task card missing"),
    ('data-debug-id="chain-editor-task-title-input"', "task title input missing"),
    ('data-debug-id="chain-editor-task-description-textarea"', "task description textarea missing"),
    ('data-debug-id="chain-editor-task-acceptance-textarea"', "task acceptance textarea missing"),
    ('data-debug-id="chain-editor-task-status-select"', "task status select missing"),
    ('data-debug-id="chain-editor-task-assignee-select"', "task assignee select missing"),
    ('data-debug-id="chain-editor-task-reviewer-select"', "task reviewer select missing"),
    ('data-debug-id="chain-editor-dependency-add-select"', "dependency add select missing"),
    ('data-debug-id="chain-editor-dependency-add-btn"', "dependency add button missing"),
    ('data-debug-id="chain-editor-add-task-title-input"', "add-task title input missing"),
    ('data-debug-id="chain-editor-add-task-btn"', "add-task button missing"),
    ('data-debug-id="chain-editor-task-delete-btn"', "task delete button missing"),
]:
    require(needle in EDITOR, message)
require('debugId="chain-editor-task-description-vim-edit-btn"' in EDITOR and 'lang="markdown"' in EDITOR, "task description Vim editor missing")
require('debugId="chain-editor-task-acceptance-vim-edit-btn"' in EDITOR and 'lang="markdown"' in EDITOR, "task acceptance Vim editor missing")

# Participant controls are the replacement for the old roster/add-member surface.
for needle, message in [
    ('data-debug-id="chain-editor-participants-panel"', "participants panel missing"),
    ('data-debug-id={`chain-editor-participant-row-${participant.role}-${participant.agentInstanceId}`}', "participant row debug id missing"),
    ('data-debug-id={`chain-editor-participant-remove-${participant.role}-${participant.agentInstanceId}`}', "individual participant remove button missing"),
    ('data-debug-id="chain-editor-participant-add-agent-select"', "participant add agent select missing"),
    ('data-debug-id="chain-editor-participant-add-role-select"', "participant add role select missing"),
    ('data-debug-id="chain-editor-participant-add-btn"', "participant add button missing"),
    ("const PARTICIPANT_ROLES = ['lgtm_required', 'lgtm_optional', 'subscriber'];", "supported participant roles missing"),
    ("const addTaskParticipant = async (agentInstanceId: string, role: string)", "generic participant add handler missing"),
    ("const removeTaskParticipant = async (agentInstanceId: string, role: string)", "generic participant remove handler missing"),
]:
    require(needle in EDITOR, message)

# Chain controls remain, but no roster/team add-member panel may exist.
for needle, message in [
    ('data-debug-id="chain-editor-chain-controls-panel"', "chain controls panel missing"),
    ('data-debug-id="chain-editor-chain-title-input"', "chain title input missing"),
    ('data-debug-id="chain-editor-chain-coordinator-picker-btn"', "chain coordinator picker missing"),
    ('data-debug-id="chain-editor-chain-reviewer-picker-btn"', "chain reviewer picker missing"),
    ('data-debug-id="chain-editor-chain-save-btn"', "chain save button missing"),
    ('data-debug-id="chain-editor-chain-pause-btn"', "chain pause button missing"),
    ('data-debug-id="chain-editor-chain-complete-btn"', "chain complete button missing"),
]:
    require(needle in EDITOR, message)
require('debugId="chain-editor-description-vim-edit-btn"' in EDITOR and 'lang="markdown"' in EDITOR, "chain description Vim editor missing")

for forbidden in [
    'chain-editor-roster-panel',
    'chain-editor-roster-add-agent-input',
    'chain-editor-roster-add-role-select',
    'chain-editor-roster-add-btn',
    'addTeamMember',
    '/teams/add-member',
    'teamId',
    'team_id',
    'Team member',
]:
    require(forbidden not in EDITOR, f"ChainEditor still contains forbidden team/roster snippet {forbidden!r}")
require("export async function addTeamMember" not in API and "/teams/add-member" not in API, "daemonApi team helper must be removed")
require("fetchTeam" not in WORKSPACE_API and "addTeamMember" not in WORKSPACE_API, "workspace endpoints must not expose team queries/mutations")

# RTKQ mutation invalidation remains the editor data path.
require("workspaceApi.endpoints.updateChain.initiate" in EDITOR, "ChainEditor chain metadata saves should use RTKQ mutation invalidation")
require("workspaceApi.endpoints.updateChainStatus.initiate" in EDITOR, "ChainEditor chain status saves should use RTKQ mutation invalidation")
require("tasksApi.endpoints.updateTask.initiate" in EDITOR, "task updates should use RTKQ mutation invalidation")
require("tasksApi.endpoints.addTaskParticipant.initiate" in EDITOR, "participant adds should use RTKQ mutation invalidation")
require("tasksApi.endpoints.removeTaskParticipant.initiate" in EDITOR, "participant removals should use RTKQ mutation invalidation")

print("TASK CHAIN EDITOR UI STATIC TEST PASSED")
