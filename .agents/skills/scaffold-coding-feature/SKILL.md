---
name: scaffold-coding-feature
description: Use when the chain goal is a coding feature, enhancement, refactor, or product change that needs implementation plus review. The coordinator selects this recipe from the goal; the daemon does not select it from a chain kind.
heimdall_managed: true
---

# Coding feature recipe
- Start with one coordinator planning/kickoff task that turns the goal into downstream tasks.
- Create focused implementation tasks assigned through default-use ids such as assignee/worker/coder/tester/specialist, not through a generated roster.
- Add at least one blocking review task/participant for changed behavior; use the configured reviewer default unless the plan explicitly requires user_proxy.
- Add testing/documentation tasks when behavior, contracts, UI, or docs change.
- If a VCS workspace task exists, make implementation tasks that need files depend on it.
