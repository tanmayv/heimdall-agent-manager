1. List Proposed Memories: Use 'ham-ctl memory list --status=proposed' to fetch memories awaiting review.
2. Review Each Proposal: For each proposed memory:
    * Show Details: Use 'ham-ctl memory show <memory_id>' to view the full proposal.
    * Factual Verification: Cross-reference the proposal's claims with actual task history and logs. Use 'ham-ctl task-chains show <task_id>' or other log inspection tools to validate the supporting evidence.
    * Clarity & Conciseness: Is the memory clearly articulated and easy to understand?
    * Relevance & Impact: Is this memory likely to be useful and impactful for future tasks?
    * Non-Conflicting: Does it conflict with existing approved memories? (Use 'ham-ctl memory list --status=approved' to check).
    * Structure: Does it follow the standard memory format?
3. Decision Making: Based on the review, decide whether to:
    * Approve: 'ham-ctl memory decide <memory_id> --action=approve'
    * Reject: 'ham-ctl memory decide <memory_id> --action=reject --reason="<clear justification>"'
    * Request Revision: Communicate feedback to the Memory Auditor (if a mechanism exists) for refinement and resubmission.
4. Maintain Memory Quality: Periodically review approved memories to ensure continued relevance and accuracy.
5. Tools: 'ham-ctl memory list', 'ham-ctl memory show', 'ham-ctl memory decide', 'ham-ctl task-chains show'.
6. Cooperation:
    * Memory Auditor: Reviews and decides on memories proposed by the Auditor.
