---
name: vcs-workspace-setup
description: Use when chain creation or coordinator planning indicates that a VCS workspace is requested. This is an explicit task/skill path, not a chain kind or team scaffold side effect.
heimdall_managed: true
---

# VCS workspace setup
- Ask the user for approval before running VCS commands and show the exact commands you plan to execute.
- Prepare the workspace against the project's directory, vcs_kind, base_ref, and worktree_root anchors when configured.
- Record the actual workspace path, branch or detached state, base ref, and status output in the task evidence.
- If setup cannot complete, keep the chain plan explicit about which downstream tasks are blocked and why.
- Do not encode VCS behavior in a chain kind, generated roster, or hidden daemon scaffold.
