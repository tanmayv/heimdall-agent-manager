#!/usr/bin/env python3
"""Static regression checks for the Task Chain Editor UI surface.

Covers route wiring plus the key mockup affordances required by TCE-1/TCE-2/
TCE-3/TCE-6/TCE-7/TCE-8/TCE-9/TCE-10/TCE-11/TCE-13/TCE-14 when a full Electron
smoke run is not available in CI/local headless environments.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")
EDITOR = (ROOT / "src/ui/components/ChainEditor.tsx").read_text(encoding="utf-8")
API = (ROOT / "src/ui/api/daemonApi.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}")
        sys.exit(1)


# TCE-1: dedicated route/page reachable from existing ChainView.
require("import ChainEditor from './ChainEditor';" in APP, "App must import ChainEditor")
require("const openChainEditor = useCallback((chainId: string, taskId = '') => {" in APP, "openChainEditor helper missing")
require("updateUrlParams({ chainId, view: 'chain-editor'" in APP, "chain editor route URL update missing")
require("home.surface === 'chain' && selectedChain && urlParams.view === 'chain-editor'" in APP, "chain-editor route branch missing")
require("<ChainEditor" in APP, "App must render ChainEditor")
require('data-debug-id="chain-open-editor-btn"' in APP, "ChainView must expose Open editor entry button")

# TCE-2/TCE-9: graph navigator, drag/pan, edge rendering, local layout persistence.
require("const STORAGE_PREFIX = 'heimdall.chainEditor.layout.v1:';" in EDITOR, "chain layout storage key missing")
require("function loadLayout(chainId: string): Record<string, Point> | null" in EDITOR, "loadLayout helper missing")
require("function saveLayout(chainId: string, positions: Record<string, Point>)" in EDITOR, "saveLayout helper missing")
require('data-debug-id="chain-editor-graph-card"' in EDITOR, "graph card affordance missing")
require('data-debug-id="chain-editor-graph-canvas"' in EDITOR, "graph canvas debug id missing")
require('data-debug-id="chain-editor-graph-autolayout-btn"' in EDITOR, "graph auto-layout button missing")
require('data-debug-id="chain-editor-graph-fit-btn"' in EDITOR, "graph fit button missing")
require("onCanvasPointerDown" in EDITOR and "event.button !== 1 && !event.shiftKey" in EDITOR, "canvas pan interaction missing")
require("onNodePointerDown" in EDITOR and "dragRef.current = { kind: 'node'" in EDITOR, "node drag interaction missing")
require("data-debug-id={`chain-editor-edge-${edge.from}-${edge.to}`}" in EDITOR, "dependency edge debug id missing")
require("void removeEdgeDependency(edge.from, edge.to)" in EDITOR, "click-to-remove dependency edge missing")
require("The graph is the primary navigator." in EDITOR, "graph-primary copy missing")

# TCE-14: graph add-edge mode selects source node then target node and uses depends_on replacement.
for needle, message in [
    ('data-debug-id="chain-editor-graph-edge-mode-btn"', "graph add-edge mode button missing"),
    ('data-debug-id="chain-editor-graph-edge-cancel-btn"', "graph add-edge cancel button missing"),
    ('data-debug-id="chain-editor-graph-edge-mode-hint"', "graph add-edge hint missing"),
    ("const [edgeCreateMode, setEdgeCreateMode] = useState(false);", "edge-create mode state missing"),
    ("const [edgeSourceTaskId, setEdgeSourceTaskId] = useState('');", "edge source state missing"),
    ("const createGraphDependency = async (fromTaskId: string, toTaskId: string)", "createGraphDependency handler missing"),
    ("const handleGraphNodeClick = (id: string) =>", "graph node click handler missing"),
    ("await runMutation('create-edge'", "create-edge mutation path missing"),
    ("dependsOn: nextDeps.join(',')", "graph add-edge must use full depends_on replacement"),
    ("if (fromTaskId === toTaskId)", "graph add-edge self-dependency guard missing"),
    ("onClick={() => handleGraphNodeClick(id)}", "node click must route through graph edge handler"),
]:
    require(needle in EDITOR, message)

require("The graph is the primary navigator." in EDITOR, "graph-primary copy missing")

# TCE-3/TCE-6/TCE-9/TCE-10: selected-task card, fields, dependencies, add/delete, Vim buttons.
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

# TCE-13: multi-reviewer/participant controls must add/remove individuals without replacement.
for needle, message in [
    ('data-debug-id="chain-editor-participants-panel"', "participants panel missing"),
    ('data-debug-id={`chain-editor-participant-row-${participant.role}-${participant.agentInstanceId}`}', "participant row debug id missing"),
    ('data-debug-id={`chain-editor-participant-remove-${participant.role}-${participant.agentInstanceId}`}', "individual participant remove button missing"),
    ('data-debug-id="chain-editor-participant-add-agent-select"', "participant add agent select missing"),
    ('data-debug-id="chain-editor-participant-add-role-select"', "participant add role select missing"),
    ('data-debug-id="chain-editor-participant-add-btn"', "participant add button missing"),
]:
    require(needle in EDITOR, message)
require("const PARTICIPANT_ROLES = ['lgtm_required', 'lgtm_optional', 'subscriber'];" in EDITOR, "supported participant roles missing")
require("const addTaskParticipant = async (agentInstanceId: string, role: string)" in EDITOR, "generic participant add handler missing")
require("const removeTaskParticipant = async (agentInstanceId: string, role: string)" in EDITOR, "generic participant remove handler missing")
require("await addTaskParticipant(agentInstanceId, 'lgtm_required');" in EDITOR, "primary reviewer compatibility must add required reviewer")
require("removeTaskParticipant({ ...auth" in EDITOR and "addTaskParticipant({ ...auth" in EDITOR, "participant controls must use daemonApi participant helpers")
require("for (const reviewer of current)" not in EDITOR, "reviewer select must not remove/replace existing reviewers")

# TCE-7/TCE-8/TCE-9/TCE-10: roster and chain controls panels.
for needle, message in [
    ('data-debug-id="chain-editor-roster-panel"', "roster panel missing"),
    ('data-debug-id="chain-editor-roster-add-agent-input"', "roster add-agent input missing"),
    ('data-debug-id="chain-editor-roster-add-role-select"', "roster add-role select missing"),
    ('data-debug-id="chain-editor-roster-add-btn"', "roster add button missing"),
    ('data-debug-id="chain-editor-chain-controls-panel"', "chain controls panel missing"),
    ('data-debug-id="chain-editor-chain-title-input"', "chain title input missing"),
    ('data-debug-id="chain-editor-chain-coordinator-select"', "chain coordinator select missing"),
    ('data-debug-id="chain-editor-chain-reviewer-select"', "chain reviewer select missing"),
    ('data-debug-id="chain-editor-chain-save-btn"', "chain save button missing"),
    ('data-debug-id="chain-editor-chain-pause-btn"', "chain pause button missing"),
    ('data-debug-id="chain-editor-chain-complete-btn"', "chain complete button missing"),
]:
    require(needle in EDITOR, message)
require('debugId="chain-editor-description-vim-edit-btn"' in EDITOR and 'lang="markdown"' in EDITOR, "chain description Vim editor missing")

# TCE-11: UI must use existing helper flows and new narrow helpers.
require("daemonApi.updateTask({ ...auth, taskId: id, chainId: chain.chainId, title: titleDraft, description: descriptionDraft, acceptanceCriteria: acceptanceDraft })" in EDITOR, "task text save must use daemonApi.updateTask")
require("daemonApi.updateTask({ ...auth, taskId: id, chainId: chain.chainId, dependsOn: unique.join(',') })" in EDITOR, "dependency replacement must use daemonApi.updateTask")
require("daemonApi.deleteTask({ ...auth, taskId: id, chainId: chain.chainId })" in EDITOR, "delete must use daemonApi.deleteTask")
require("daemonApi.addTeamMember" in EDITOR, "roster add-member must use daemonApi.addTeamMember")
require("daemonApi.startAgent" in EDITOR and "daemonApi.stopAgent" in EDITOR, "roster runtime controls must use start/stop helpers")
require("daemonApi.updateTaskChain" in EDITOR and "daemonApi.updateTaskChainStatus" in EDITOR, "chain controls must use chain update/status helpers")

# API helper coverage for TCE-4/TCE-5/TCE-6/TCE-7/TCE-11.
require("export async function addTeamMember" in API and "/teams/add-member" in API, "daemonApi.addTeamMember helper missing")
require("export async function updateTask({" in API, "daemonApi.updateTask helper missing")
require("if (acceptanceCriteria !== undefined) body.acceptance_criteria = acceptanceCriteria;" in API, "updateTask must pass acceptance_criteria")
require("if (dependsOn !== undefined) body.depends_on = dependsOn;" in API, "updateTask must pass depends_on")
require("export async function deleteTask({" in API and "action: 'task_delete'" in API and "agentPath: '/tasks/delete'" in API, "daemonApi.deleteTask helper missing")

print("TASK CHAIN EDITOR UI STATIC TEST PASSED")
