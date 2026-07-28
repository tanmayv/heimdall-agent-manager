---
name: review-and-evidence
description: Use when preparing implementation evidence or reviewing a task. It defines LGTM/NGTM expectations and REQ-ID-based validation.
heimdall_managed: true
---

# Review and evidence
- Cite the REQ-IDs covered by every implementation summary, test report, and review vote.
- A reviewer verifies claimed requirements against code, tests, logs, and artifacts, then votes LGTM or NGTM.
- NGTM feedback must identify the unmet REQ-ID or explicitly state that the issue is a non-REQ nit.
- Prefer one consolidated review comment over many hidden blockers.
- Evidence should include exact file paths, commands, exit status, and known gaps.
