# Memory Audit Pipeline Task Chain

This task chain coordinates a structured, multi-step cognitive memory audit process. It discovered relevant task execution histories, filters them according to guidelines, performs deep analytical audits on logs/comments/artifacts, compiles markdown memory recommendations, and proposes the final approved memories to the system.

## Coordinator / Assignee Role
The **Memory Auditor** acts as the Assignee for all tasks in this chain, driving the execution from discovery to proposal generation.

## Reviewer Role
The **Memory Reviewer** acts as the Reviewer (LGTM required) for each step of the pipeline. They audit the inputs, filters, analysis, recommendations, and proposals to ensure high quality and standard compliance.
