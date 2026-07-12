#!/usr/bin/env python3
"""Regression: final VCS chain scaffolds include an approval-friendly merge/push/cleanup task."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
TASK_SERVICE = ROOT / "src/daemon/task_service.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    src = TASK_SERVICE.read_text(encoding="utf-8")

    scaffold_block = re.search(
        r"task_service_create_chain_scaffold :: proc[\s\S]+?return true, \"ok\"\n}\n",
        src,
    )
    require(scaffold_block is not None, "create_chain_scaffold block not found")
    block = scaffold_block.group(0)

    require(
        'cmd.wants_vcs && task_service_project_supports_vcs(cmd.project_id)' in block,
        "VCS finalize task should only be scaffolded when VCS is enabled",
    )
    require('key = "vcs_finalize"' in block, "VCS final scaffold task must be appended")
    require('assignee_agent_instance_id = cmd.coordinator_agent_instance_id' in block, "VCS final scaffold task should be assigned to resolved coordinator")
    require(
        'task_service_scaffold_terminal_task_depends_on(built[:])' in block,
        "VCS final task should depend on terminal scaffold tasks only",
    )
    require(
        'reviewer_agent_instance_ids = []string{reviewer}' in block,
        "VCS final scaffold task should use reviewer selection result",
    )
    require(
        'task_service_scaffold_vcs_finalize_description(cmd.title, cmd.project_id, base_ref, team_id, chain_id)' in block,
        "VCS final scaffold task should include finalize description helper",
    )

    finalize_block = re.search(
        r"task_service_scaffold_vcs_finalize_description :: proc[\s\S]+?return strings.to_string\(b\)\n}\n",
        src,
    )
    require(finalize_block is not None, "finalize description helper not found")
    final_desc = finalize_block.group(0)

    require('Merge the approved work into the configured base ref' in final_desc, "finalize description must require merge to base ref")
    require('merge --ff-only origin/' in final_desc, "finalize description should include an explicit merge command")
    require('push origin HEAD:' in final_desc, "finalize description must include push command guidance")
    require('Workspace cleanup' in final_desc, "finalize description must include cleanup section")
    require(
        'If cleanup fails, include the failure details and add a follow-up cleanup task' in final_desc,
        "finalize description must document cleanup failures",
    )
    require('task_service_scaffold_vcs_workspace_path' in final_desc, "finalize description should mention workspace path derived by helper")

    require('legacy_cmd.chain_id = chain_id' in src, "scaffold creation should pass resolved chain id into generated task helpers")
    require('legacy_cmd.coordinator_agent_instance_id = coordinator_agent_instance_id' in src, "scaffold creation should pass resolved coordinator into generated task helpers")
    require('task_service_project_supports_vcs' in src, "project VCS support guard helper must exist")
    require('project_anchor_value(project, "vcs_kind", "auto")' in src, "VCS support guard should treat configured project directories as auto VCS by default")
    require('return repo != "" && vcs_kind != "none"' in src, "VCS support guard must exclude non-VCS projects")
    require('if member.is_user_proxy do continue' in src, "non-user reviewer helper should skip user proxy members")
    require('agent_id == "operator@local"' in src, "non-user reviewer helper should exclude operator@local")

    print("VCS FINAL SCHEMA TASK TEST PASSED")


if __name__ == "__main__":
    main()
