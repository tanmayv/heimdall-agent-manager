---
name: testing-discipline
description: Use when deciding what to test, adding regression coverage, or reporting validation for implementation work.
heimdall_managed: true
---

# Testing discipline
- Add or update tests for changed behavior, regressions, and public contract changes.
- Run the smallest focused test first, then the required package build or broader suite for touched components.
- Record commands with exit status and enough output context for reviewers to reproduce failures.
- If a required check cannot run, state why, what risk remains, and which follow-up or environment action would close it.
- For Heimdall daemon, wrapper, and ctl changes, build the affected Nix package before review handoff.
