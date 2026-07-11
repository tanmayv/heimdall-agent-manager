#!/usr/bin/env python3
"""Regression: VCS chain creation creates an approval-gated setup task instead of a worktree."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TASK_SERVICE = ROOT / "src/daemon/task_service.odin"
APP = ROOT / "src/ui/components/App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    src = TASK_SERVICE.read_text(encoding="utf-8")
    create_chain = re.search(r'task_service_create_chain :: proc[\s\S]+?task_service_default_chain_title :: proc', src)
    require(create_chain is not None, "create-chain function block not found")
    block = create_chain.group(0)
    require('task_service_maybe_provision_workspace' not in block, "chain creation must not synchronously provision worktrees")
    require('task_service_create_workspace_setup_task' in block, "VCS chain creation should create workspace setup task")
    require('workspace_setup_task_id' in block, "create response should include workspace_setup_task_id")
    require('task_service_create_coordinator_discovery_task' in block and 'workspace_setup_task_id)' in block, "discovery task should depend on workspace setup task")
    require('Do not run any VCS command until you have asked the user' in src, "setup task must require explicit user approval")
    require('git -C %s worktree add --detach %s %s' in src, "setup task should suggest safe detached worktree command")
    require('depends_on                 = depends_on' in src, "discovery task must persist dependency")

    app = APP.read_text(encoding="utf-8")
    require('workspaceSetupTaskId' in app, "UI progress should track workspace setup task id")
    require('Workspace setup task created' in app, "UI progress should show setup task checkpoint")

    print("VCS WORKSPACE SETUP TASK TEST PASSED")


if __name__ == "__main__":
    main()
