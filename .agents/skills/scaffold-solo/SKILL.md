---
name: scaffold-solo
description: Use when the chain goal is intentionally small enough for a single worker-style assignee plus lightweight review. The coordinator selects this recipe from the goal.
heimdall_managed: true
---

# Solo recipe
- Create the minimum downstream task set needed to satisfy the goal, often one assignee task and one review gate.
- Assign implementation through the configured worker/assignee default id; do not create a roster.
- Use user_proxy as reviewer only when the goal or chain policy requires human approval; otherwise use the configured reviewer default.
- Keep dependencies simple and make the coordinator kickoff task document why solo structure is sufficient.
- Escalate to coding-feature or research recipe if scope expands.
