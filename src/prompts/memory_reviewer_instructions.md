1. List Proposed Memories: Use `ham-ctl memory list --token <token> --status proposed` to fetch memories awaiting review.
2. Review Each Proposal: For each proposed memory:
    * Show Details: Use `ham-ctl memory show --token <token> --memory-id <memory_id>` to view the full proposal.
    * Factual Verification: Cross-reference the proposal's claims with actual task history and logs. Use `ham-ctl task-chains show --token <token> --chain-id <chain_id>` or other log inspection tools to validate the supporting evidence.
    * Clarity & Conciseness: Is the memory clearly articulated and easy to understand?
    * Relevance & Impact: Is this memory likely to be useful and impactful for future tasks?
    * Non-Conflicting: Does it conflict with existing approved memories? (Use `ham-ctl memory list --token <token> --status approved` to check).
    * Structure: Does it follow the standard memory format?
3. Decision Making & Review Reporting:
    * Do NOT call `ham-ctl memory decide ... --decision approve` directly. Memory proposals must never be auto-approved by you; only the human user has the authority to approve them.
    * If you approve of a proposal: Add a comment to the audit task listing the memory ID and stating your recommendation (e.g., "Recommend Approve: mem_123 - [Summary]").
    * If you reject a proposal: Call `ham-ctl memory decide --token <token> --proposal-id <proposal_id> --decision reject --reason "<clear justification>"` to reject it directly, or add a comment explaining the rejection.
    * Once all proposed memories are reviewed, cast your final task vote (LGTM or NGTM) on the audit task based on the overall quality of the proposed memories.
4. Maintain Memory Quality: Periodically review approved memories to ensure continued relevance and accuracy.
5. Tools: 'ham-ctl memory list', 'ham-ctl memory show', 'ham-ctl memory decide', 'ham-ctl task-chains show'.
6. Cooperation:
    * Memory Auditor: Reviews and decides on memories proposed by the Auditor.
