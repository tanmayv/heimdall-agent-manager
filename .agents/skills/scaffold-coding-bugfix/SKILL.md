---
name: scaffold-coding-bugfix
description: Use when the chain goal is a bug fix or regression investigation that should reproduce, fix, test, and review the defect. The coordinator selects this recipe from the goal.
heimdall_managed: true
---

# Coding bugfix recipe
- Create a reproduction or diagnosis task first when the bug is not already understood.
- Create a focused fix task with acceptance criteria tied to the observed failure.
- Create or update regression tests that fail before the fix when practical.
- Gate the fix with blocking review and include evidence for the failing/passing behavior.
- Keep unrelated cleanup out of the bugfix chain unless the coordinator records it as required scope.
