# Multi-Agent Best Practices for Heimdall

Heimdall is an orchestration system for AI work. Its goal is not just to make agents produce more output, but to make multi-agent work auditable, reviewable, and resilient against cognitive atrophy, hallucination, and black-box automation.

This document adapts the 5 AI Archetypes framework into practical Heimdall operating rules.

## Core Principle: Orchestrate, Do Not Automate Blindly

A common failure mode in AI adoption is treating the model as a one-shot producer: “write the strategy,” “build the feature,” or “fix the bug.” This skips context gathering, reasoning, planning, and review.

In Heimdall, high-quality work should move through explicit roles and checkpoints:

1. **Scholar** — gather context and establish facts.
2. **Analyst** — reason about risks, constraints, and tradeoffs.
3. **Architect** — structure the plan and task chain.
4. **Producer** — implement the artifact.
5. **Advisor** — review, critique, and approve.

The human or planner agent acts as the **Orchestrator**: they decide which role is needed next, inspect handoffs, and keep the work from becoming a black box.

## Mapping the Archetypes to Heimdall

| Archetype | Heimdall Pattern | Typical Agent/Workflow |
| --- | --- | --- |
| Scholar | Read docs, task history, memory, code, prior decisions | Researcher, memory auditor, coder investigation |
| Analyst | Identify risks, failure modes, blockers, regressions | Planner, reviewer, debugging task |
| Architect | Draft task chains, dependencies, acceptance criteria | Planner |
| Producer | Implement code/docs/config changes | Coder |
| Advisor | Review changes, simulate user impact, LGTM/NGTM | Reviewer |

A single agent may perform multiple archetypes, but Heimdall should make the transition between archetypes explicit in task descriptions, comments, reviews, and final summaries.

## Best Practices

### 1. Start With a Draft Plan

Before creating a new task chain, the planner should send the user a draft chain plan and wait for explicit approval.

A good draft includes:

- chain title and purpose
- absolute project directory
- source docs or relevant files
- ordered tasks
- assignees
- required reviewers
- dependencies
- acceptance criteria
- validation/audit requirements
- risks and assumptions

This is the Architect checkpoint. It prevents premature execution.

### 2. Keep Task Chains Focused

One task chain should represent one user-visible outcome: a feature, fix, investigation, migration, or documented plan.

Avoid giant umbrella chains where the true work is hidden in comments. Split work into independently reviewable tasks.

### 3. Put Review on the Implementation Task

Do not create separate review-only tasks by default. Add the reviewer as `lgtm_required` on the implementation task.

A task is complete only when the required reviewer approves that same task.

This keeps production and review evidence attached to the same durable unit of work.

### 4. Make Tasks Self-Contained

Every implementation task should include enough context for a restarted or newly assigned agent to act without relying on chat history.

Include:

- absolute project directory
- source documents
- likely files/components
- objective and non-goals
- acceptance criteria
- validation commands
- audit/logging expectations

### 5. Use Evidence, Not Vibes

Completion comments and final summaries should include concrete evidence:

- changed files
- commit IDs
- tests run
- command output summaries
- reviewer LGTM/NGTM result
- known caveats

Avoid vague summaries like “done successfully.” Heimdall’s value comes from reconstructable work history.

### 6. Treat Reviewer Friction as a Feature

Reviewer NGTM is not failure. It is the Advisor archetype applying benevolent friction.

Good reviewer feedback should reference:

- unmet acceptance criteria
- missing validation
- unsafe assumptions
- file/line concerns
- user impact

Assignees should address the feedback, resolve comments where appropriate, and resubmit.

### 7. Preserve the Glass Box

Do not hide important reasoning in private chat or ephemeral context. Use durable task comments, descriptions, chain summaries, and memory proposals.

Direct messages are useful for coordination, but durable decisions belong in tasks.

### 8. Use Memory Deliberately

When a task chain reveals a reusable habit, constraint, or failure mode, propose memory after review.

Good memory candidates include:

- recurring workflow rules
- project-specific constraints
- known bugs/workarounds
- reviewer preferences
- validation patterns

Do not store unreviewed assumptions as durable memory.

### 9. Avoid Premature Producer Mode

If the task is ambiguous, do not send it straight to the coder.

Ask whether the next needed archetype is:

- Scholar: do we need context?
- Analyst: do we need risk/tradeoff reasoning?
- Architect: do we need a plan?
- Producer: are we ready to build?
- Advisor: do we need critique/review?

Most failures come from activating Producer too early.

### 10. Close the Chain Properly

When the last task is approved, the coordinator should complete the chain and send the user a concise closeout.

The final summary should include:

- chain ID
- completed tasks
- commits/artifacts
- validation evidence
- reviewer outcome
- known caveats or follow-up work

## Common Failure Modes

### One-Shot Producer Failure

User asks for output without context, planning, or review.

**Heimdall fix:** create a chain with Scholar/Architect/Advisor checkpoints before production.

### Hidden Context Failure

Agent relies on chat history or implicit working directory.

**Heimdall fix:** put project directory, source docs, and acceptance criteria in the task description.

### Review Drift

Review happens in a separate task or chat thread and becomes disconnected from implementation evidence.

**Heimdall fix:** add reviewer as `lgtm_required` on the implementation task.

### Black-Box Chain Failure

Task chain completes but no one can reconstruct what happened.

**Heimdall fix:** require task comments, validation logs, commit IDs, and final chain summary.

### Cognitive Atrophy Failure

Human stops evaluating AI outputs and accepts plausible answers.

**Heimdall fix:** use explicit Architect and Advisor checkpoints; require approval before execution and LGTM before completion.

## Practical Heimdall SOP

For non-trivial work:

1. **Receive intent.** Clarify the user-visible outcome.
2. **Draft chain.** Decompose work and share plan with user.
3. **Wait for approval.** Do not create the chain until approved.
4. **Create tasks.** Include context, assignee, reviewer, dependencies, and acceptance criteria.
5. **Activate chain.** Let assignees work through task state.
6. **Produce evidence.** Coder logs changed files, validation, and commits.
7. **Review on-task.** Reviewer votes LGTM/NGTM on the implementation task.
8. **Iterate if needed.** Address NGTM with focused fixes.
9. **Complete chain.** Coordinator writes evidence-rich final summary.
10. **Update user.** Send concise closeout and note follow-ups.

## Summary

The 5 AI Archetypes provide the cognitive model. Heimdall provides the operating system.

Together, they turn AI collaboration from ad-hoc prompting into auditable orchestration:

- Scholar grounds the work.
- Analyst sharpens the reasoning.
- Architect plans the path.
- Producer builds the artifact.
- Advisor protects quality.
- Orchestrator keeps the whole system aligned with human intent.
