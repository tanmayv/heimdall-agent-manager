# Agent task cancellation and splitting

Planning deliverable for `task_18e5b93cb76120e4`, requirements revision 1.
**Proposed, not implemented.** Named independent review and explicit user approval
of this task must precede coding. This extends the approved owner-local design
at `1c83a464`; it does not replace or waive ongoing M3/M4 work or authorize
deployment, service restart, publishing, or a new Hub authority path.

## Source baseline and existing behavior

Inspected checkout: `18d2db38d4f2f85a640886561d68f41e2ec7d7dc` in the planning
task's isolated worktree. The supplied engineer checkpoint
`890f87eb50fc51da5a178e44a2367dc1098afdfc` was checked by commit identity only;
its active working tree was not modified or merged. Implementation tickets must
rebase selected changes onto the coordinator-approved integration base and
reconcile intervening schema/API changes, rather than merge unrelated history.

| Existing surface | Exact source / finding |
| --- | --- |
| Agent CLI | `src/ctl/agent_mode.odin`, `ctl_v2_task` dispatch and task help around line 2052; `src/ctl/taskv2_cmds.odin`, `ctl_v2_task_action`: hold/release/recheck exist, cancel/split do not. Installed `./bin/ham-ctl task --help` confirms this. |
| Other CLI modes | `src/ctl/tasks.odin:798` and `src/ctl/hub_mode.odin:617` already expose legacy user/Hub cancellation. Do not document that as missing everywhere or route agent authority through it. `src/ctl/help.odin` delegates task help to agent help. |
| Legacy cancellation | `src/hub/transport/http/taskchain_handlers.odin:1931`, wiring in `src/hub/app/wiring.odin`; `src/hub/service/taskchain/taskchain_service.odin:2179` permits owner/coordinator and refuses workflow-managed tasks. `src/hub/service/taskv2/lease.odin:847` expires leases, records cancellation and replans. Its documented cancelled-prerequisite behavior unblocks dependents. |
| Native owner cancellation | `src/contracts/owner_local.odin` admits `task.cancel` with `control_payload`; `src/lib/owner_local/store.odin` authenticates current read scope before receipt lookup, then applies fresh revision/time fences. `controls.odin`, `control_human/control_revoke/control_intents`, records cancellation and exact-child stop intents while preserving evidence. Deferred workflow-retirement conflicts already block unsafe controls. |
| Native graph | `src/lib/owner_local/work_graph.odin`, `work_snapshot/work_inputs_ready/work_capture_inputs/work_dependency_add/work_scope`: cancellation is terminal but unsuccessful; prerequisites need success, consumed inputs pin a generation, and started consumers cannot receive new edges. This differs from legacy cancellation. |
| Agent authentication | `src/bridge/agent_api.odin`, `wrapper_endpoint.odin`, `owner_local_leases.odin`, `executor_child.odin`; `src/lib/owner_local/lifecycle_agent.odin`, `operational_metadata.odin`, `workflow_coordinator.odin`: current exact child/member/lease checks and receipt-first execution exist. Current coordinator capability only allows workflow gate posting; it is not blanket task-management authorization. |
| Physical lifecycle | `src/bridge/owner_local_controls.odin` validates exact child generation before stop/checkpoint I/O; obsolete notices cannot stop a transferred child. `src/lib/owner_local/execution.odin`, `execution_child.odin`, `outbox.odin`, `completions.odin` retain execution/intent evidence. Lease retirement alone proves no physical child absence. |
| UI replacement | `src/ui/components/tasks/RequirementsEditorModal.tsx:126-150` creates one task, writes two comments, then cancels via separate requests. It is neither atomic splitting nor dependency rewiring. `src/ui/api/endpoints/tasks.ts:1000` calls the legacy cancel endpoint; `TaskCard.tsx`, `TicketView.tsx`, `BoardTicketCard.tsx`, `useTaskActions.ts`, `taskActions.ts` expose cancellation. |
| Owner UI/routing | `src/ui/api/ownerLocal.ts`, `ownerLocalClient.ts`, `ownerWork.ts`, `components/taskchain/OwnerLocalPanel.tsx`; `src/hub/transport/http/owner_local_handlers.odin` routes opaque envelopes and refuses an unavailable immutable owner. Reuse these boundaries. |

No server-side split transaction or split CLI was found in these targeted
paths. Existing UI replacement is the behavior to converge, not a new duplicate
create/comment/cancel helper.

## Proposed commands and authorization

```bash
ham-ctl task cancel <task-id> --reason "..." --expected-revision <r> --operation-id <stable-id> \
  [--lease <own-work-lease> --checkpoint-file <checkpoint.json>] \
  [--scope keep|exclude --expected-work-revision <w>]
ham-ctl task split <task-id> --file <split.json> \
  [--lease <own-work-lease> --checkpoint-file <checkpoint.json>]
```

The split file carries the operation ID, source requirements/task revisions,
expected chain work revision and all successor/dependency choices. A read-only
`--dry-run` validates and returns normalized choices without allocating durable
IDs, changing dispatch, or creating a receipt. Execution uses the saved exact
manifest; stale state is returned to the caller, never silently refreshed.
Errors are structured and nonzero. Both commands return the owner commit,
operation/receipt identity, resulting revisions, and cancellation/drain or
successor/dependency status. Required request IDs are generated by the caller;
examples teach retaining them before the first send.

| Actor | Proposed authority |
| --- | --- |
| Owner device | Existing signed scoped owner command/grant, current directory authorization and exact chain/task. |
| Current chain coordinator agent | Explicitly enabled `coordinator` membership for the exact authenticated child and immutable owner/chain; static permission only for these task-control methods, with current membership/configuration revision and revocation checks. No account-wide authority or reuse of a workflow-gate-only capability as task authority. |
| Worker on its own current work lease | Cancel that exact manual task, or perform the bounded retain-parent self-split below, only when the owner-issued lease explicitly allows `task.cancel.self` or `task.split.self`. Require exact child/fleet/configuration/requirements fences, reason and durable verified checkpoint. No other task, chain scope exclusion or external consumer rewrites. |
| Reviewer / other worker / arbitrary executor | No cancellation or split authority by virtue of a review, token possession, supplied role string, task ID or same account. Use checkpoint/handoff and route the request to the coordinator. |

**Policy decision for user review:** support both coordinator splitting and
narrow worker self-splitting, so agents can cancel **and** split their own work
without an unnecessary coordinator round-trip. A self-split must retain the
parent with its original full goal/acceptance/review gates and external dependent
edges; children decompose mapped source acceptance within the same assignment,
directory and placement scope, inherit every required gate, and become prerequisites
of the retained parent. It cannot cancel/exclude/re-scope the parent, change
assignees/policy/budget, edit other consumers or touch workflow-managed work.
The owner's grant must bound successor count and budget allocation within
existing policy ceilings; self-split must not mint extra budget or reset spent
parent attempts. Refuse if those bounds cannot be enforced by existing policy.
Refuse self-split while the source is held, budget-blocked or chain-paused, so
successors cannot bypass an operator pause. Bounds are additionally constrained
by the owner-issued self-split policy; unsupported grants return `invalid_scope`.

Existing work-lease authority only covers its allowed lifecycle methods; it
does **not** already authorize arbitrary task creation/graph mutation. Add the
explicit bounded self-split grant/admission instead of broadening every worker
or treating supplied fields as authority. Coordinator/owner remains necessary
for full replacement, external rewiring or changed parent scope. Thus authorized
agents invoke the supported action themselves without a forced human UI step.
User approval of this implementation plan
does not approve future task results, remove named/user gates, or authorize
workers to cancel unrelated tasks. This authorization policy is part of the
plan submitted for approval.

The owner Bridge attests the actual caller and commits the command. For remote
agents, reuse authenticated executor-child relay and exact launch binding;
the executor and Hub cannot manufacture an owner coordinator/member assertion.
Add bounded task-control envelope/payload schemas and method-specific actor
admission in the existing contract/owner paths, not a general-purpose agent
mutation framework. Browser/device requests retain existing signed grant rules.
Expose `agent.task.cancel` and `agent.task.split` as local owner-routed operations,
not new Raw Hub mutation routes. Preserve strict ASCII authority identifiers and
separate encrypted content: Unicode goals/reasons/briefs belong in the existing
vault-protected content payload, never plaintext Hub task state or permissive
authority parsing. The local authenticated agent path must use owner-held keys;
it must not require exporting browser/device keys to an agent.

## Cancellation, checkpoints and physical drain

1. Require a nonempty reason, manual nonterminal task and expected revision.
   Done/cancelled tasks reject a new mutation; an identical prior operation
   still replays its saved receipt. Workflow stages, workflow gates and generated
   fan-out tasks must use whole-run lifecycle commands. Reject unresolved
   prepared/claimed merge or deferred workflow-retirement dispositions rather
   than falsely reporting a Git side effect undone.
2. For **another active work/review holder**, return `checkpoint_required` with
   exact holder/lease information before mutation. The coordinator uses existing
   hold → holder checkpoint/handoff → re-read/retry. No new pending-cancel state
   machine or force flag is needed. Preserve review progress without posting an
   approval. If the child is unreachable or progress unverified, remain held/
   blocked; do not expire it to manufacture a safe checkpoint.
3. An owning worker may self-cancel atomically with a checkpoint containing
   summary, next steps, decisions/dead ends and the last commit/attempt references.
   Require the existing trusted source-proof mechanism to verify preserved work
   and a clean committed worktree when applicable. Uncommitted/unverified work
   returns `checkpoint_required`; never trust a caller's bare head string. Remote
   proof must be authenticated for that exact checkout/child, otherwise refuse.
4. In one owner transaction, append checkpoint/history/reason, record cancellation,
   retire current mutation authority, invalidate only appropriate pending intents,
   enqueue exact-child stop notices and persist the receipt/outbox. Preserve old
   attempts, comments, commits, submissions, review verdicts and merge evidence.
5. Logical cancellation may commit while an exact stop is pending. Return
   `stop_pending`, not `stopped`, and retain physical reservation/capacity until
   authenticated stop/absence/reconciliation evidence arrives. No SQLite
   transaction spans network/PTY I/O. Reconnect/restart retries the same intent;
   stale notices never stop a replacement or newly assigned child. Self-cancel
   may terminate its caller: persist the receipt first; authorized coordinator/
   owner receipt lookup resolves a lost reply without recreating the operation.

Cancellation is **not success** and does not automatically remove prerequisites,
approve work or cascade to dependents. Default `--scope keep` leaves the cancelled
task visible and outstanding in native chain completion; authorized coordinator/
owner `--scope exclude` records an explicit scope decision atomically and requires
the expected chain work revision. A worker
cannot exclude chain scope. Existing dependencies remain unsatisfied unless an
authorized explicit graph change replaces/removes them. Converged UI/agent routes
must use this owner behavior, clearly replacing the legacy automatic-unblock
assumption for owner-managed chains; no silent semantic fork.

## Split manifest and atomic transaction

A version-1 manifest requires: source task/revision/requirements revision,
expected chain work revision, reason, operation ID, `parent_disposition` of
`retain` or `cancel`, and **1–20 explicit self-contained successors**. Zero,
duplicate/oversized IDs, blank/incomplete briefs and missing graph choices fail
before any write. IDs are supplied/retained in the exact request so replay never
creates replacements. Unknown keys and unsupported manifest versions fail closed.

Normative top-level fields are `version`, `operation_id`, `task_id`,
`expected_revision`, `expected_requirements_revision`, `expected_work_revision`,
`reason`, `parent_disposition`, `parent_brief` (retain only), `successors`,
`coverage`, and `rewires`, with `lease_id` and `checkpoint` required for self-split.
Successors use `task_id`, `title`, `brief`,
`requires_user_approval`, placement/directory fields and typed `depends_on`
references `{kind,id}`. Each rewire identifies the consumer kind/id and revision,
the old dependency identity and nonempty `replace_parent_with` successor IDs.
Bound the whole content manifest to the existing 8192-byte plaintext and
16384-byte encoded-content ceilings, as well as per-brief publication limits;
the 20-task count is an upper bound, not permission to exceed byte limits.
Oversized or unrepresentable graph rewrites fail before any write; no multi-call
partial split or silent payload truncation is allowed.

Each successor supplies title, goal, nonempty acceptance criteria, immutable
inputs, assignee, reviewers/review roles, user-approval flag, placement/directory
scope and incoming dependencies. Reuse `work_publish_brief` and
`brief_inputs_resolve/pin` validation; do not use its title-as-goal fallback for
split briefs. Copy parent defaults only through explicit, normalized inheritance
in the manifest; store the resulting full brief. Do not copy task capabilities,
lease state, spent attempts, budgets, approvals or success status. All successors
start as published ready work in the same chain, subject to normal dispatch,
capacity and review admission. User/named/role gates may be strengthened, not
removed by splitting; changing them requires a separate authorized policy change.

The manifest maps each original acceptance index at the pinned requirements
revision to successor criteria and/or explicitly retained parent scope. This
checks structural coverage, not semantic correctness; reviewers assess whether
the new briefs preserve the requested work. Missing coverage is an invalid
partial split. `retain` requires a complete new parent goal/acceptance describing
the remainder; worker self-split instead requires that supplied parent brief to
equal its unchanged original full scope, while children are mapped decomposition.
`cancel` requires all scope assigned to successors and explicit
parent scope exclusion. No implicit deletion or requirement rewrite.

The owner serial transaction must:

1. Authenticate current read scope and exact operation digest; replay an existing
   receipt before current mutation/lease expiry fences. Reusing the ID with a
   changed payload conflicts; revoked read scope never regains access via replay.
2. Check current coordinator/device authority, source/requirements/work revisions,
   affected-node revisions, publication state and checkpoint/drain preconditions.
   Apply cancellation's active-holder and merge restrictions. A reviewer race or
   owner offline condition produces no partial successors or Hub fallback.
   Alternatively admit the exact current worker self-split capability only for
   the retain-parent subset above. Its verified checkpoint ends the old lease/
   input generation atomically; keep the old attempt and consumed input receipts
   immutable. The retained parent must obtain a fresh claim/input generation
   after children succeed, under normal budget rules, not resume its retired
   lease or rewrite already captured inputs. This is the only bounded exception
   to the no-started-consumer rewrite rule: the caller's own source parent gains
   child prerequisites. All other started consumers still cause full rollback.
   Release the source work lease at this checkpoint; do not leave a waiting parent
   consuming a lease while its same-fleet children need it. Enqueue the exact-child
   stop/drain and preserve physical capacity until acknowledged, then allow the
   ordinary scheduler to run children. An unavailable child may delay progress,
   but no false capacity release or reserved-parent/child dependency deadlock is
   permitted. Same-operation replay cannot retire the lease or allocate twice.
3. Validate the complete combined DAG, all briefs/inputs/review gates and scope;
   only then create successor IDs and immutable parent↔successor provenance with
   original brief, attempt/commit/checkpoint and operation references. Retain full
   history; required artifact facets must resolve before publication.
4. Copy explicit incoming prerequisites and pinned input generations to successors.
   For `cancel`, replace **every outgoing prerequisite edge** from the parent to
   the specified successor set before parent cancellation becomes visible. For
   `retain`, leave external dependents on the parent and make its remainder depend
   on the successors. Explicit internal successor edges are allowed if acyclic.
   Reject self-links, cross-chain moves, omitted affected edges and dangling refs.
5. Rewrite only unstarted, unconsumed manual task or whole-workflow-run consumers;
   refuse started/terminal consumers, captured input generations or private
   generated-stage DAG edits. Never rewrite historical dependency/input receipts.
   The narrowly authorized source-parent generation replacement in step 2 is
   explicit; it preserves old receipts and does not authorize other started nodes.
   A conflict rolls back the whole split; partial rewiring is not offered.
6. Append native graph/scope/requirements/provenance changes, update the parent
   according to the explicit disposition, advance work revision and atomically
   record events/receipt/publication/stop intents. `retain` resets affected parent
   review admission for its new requirements; old approvals remain evidence only.
   Preserve any pre-existing hold; report that explicit `task release` is needed
   to resume the retained parent. Splitting cannot silently clear an operator hold.
   Publish only after commit. A crash or lost reply returns the exact same
   successor IDs, graph and result on authorized replay.

Use append-only provenance and existing graph/tombstone/receipt machinery. Add
only the missing split relation/atomic mutation storage and required physical-
drain tracking if current execution journals cannot represent it. At this base
schema is 27; choose the next unused migration when implementing, with genuine
upgrade/rollback tests. Do not renumber another worker's migration.

## Proposed implementation tickets

These are briefs for the coordinator to publish **after plan approval**. Every
ticket gets named independent review; normal user/named gates on product tasks
remain. No ticket carries a configured verification command. Workers choose and
report meaningful checks. No implementation starts from this planning lease.

**CS1 — Owner-authorized cancellation and safe drain.** Goal: agent coordinator
and exact owning worker can cancel a manual task through immutable owner authority.
Inputs: this approved plan; source baseline above; existing cancellation/control/
execution tests. Paths: `src/contracts/{owner_local,owner_schema}.odin`, its tests/fixtures;
`src/lib/owner_local/{store,controls,lifecycle_agent,operational_metadata,leases,execution,execution_child,completions}.odin`;
`src/bridge/{owner_local_leases,owner_local_controls,executor_child}.odin` and
focused tests; proposed new `src/lib/owner_local/task_control_agent.odin` and
`task_control_agent_test.odin`, `src/bridge/owner_local_task_controls.odin` and
its tests; additive owner migration/schema files only if needed.
Acceptance: actor matrix rejects wrong chain/child/lease/coordinator revocation;
the owner-issued self-split grant has explicit count/budget/scope restrictions
and is never implied by membership or ordinary work-lease possession;
verified checkpoint precedes cancellation; workflow/merge restrictions hold;
history/review gates survive; repeat/lost-reply conflicts follow receipt rules;
stop-pending never releases physical capacity and stale stop cannot kill a new
child. Existing human cancellation shares the same safe transition helper.

**CS2 — Atomic split and provenance.** Depends on CS1. Goal: one owner transaction
creates valid successor work and rewires future graph/scope without lost history.
Paths: `src/contracts/{owner_local,owner_schema}.odin`, shared fixtures;
`src/lib/owner_local/{store,work_publication,work_graph,brief_refs,controls,attempts,lifecycle,review_roles,migrations}.odin`,
`src/lib/owner_local/schema.sql`,
new `src/lib/owner_local/task_split.odin`, `task_split_test.odin` and next
available migration.
Acceptance: explicit retain/cancel cases, inherited/strengthened gates and pinned
input provenance; empty/incomplete/cyclic/partial/consumed/workflow-stage cases
refused; rollback leaves no successors or edges; concurrent revision changes
conflict; exact replay after restart/lost response returns identical IDs/history.
Include self-split source-generation retirement, checkpoint preservation,
no parent lease while waiting, same-fleet child scheduling after verified drain,
parent resumption under fresh admission, and denial of external rewiring,
held/budget-blocked sources, gate/assignment changes or excess child budget.

**CS3 — Agent CLI and normal UI convergence.** Depends on CS1/CS2. Goal: supported
cancel/split actions are usable from real agent CLI and existing UI with identical
owner semantics and no compulsory human UI step for authorized agents.
Paths: `src/ctl/{agent_mode,taskv2_cmds,tasks,help}.odin` and CLI wire tests;
`src/bridge/{agent_api,wrapper_endpoint,owner_local_leases,executor_child}.odin`;
`src/hub/transport/http/{owner_local_handlers,taskchain_handlers}.odin` and
`src/hub/service/taskchain/taskchain_service.odin` only for routing/explicit legacy
boundary; `src/ui/api/{ownerLocal,ownerLocalClient,ownerWork}.ts`,
`src/ui/api/endpoints/tasks.ts`,
`src/ui/components/tasks/{RequirementsEditorModal,TaskCard,TicketView,BoardTicketCard}.tsx`,
`src/ui/components/tasks/{useTaskActions,taskActions}.ts`.
Acceptance: real CLI manifest/dry-run/failure exits/stable request IDs work;
unauthorized and owner-offline calls cannot mutate via Hub; existing Replace UI
uses the atomic operation; selected parent disposition/dependency effects and
checkpoint/stop-pending errors remain visible; drafts survive conflicts.
Demonstrate a grant-authorized worker self-split through child completion and
parent resumption without a coordinator/UI round-trip, plus an ungranted denial.

**CS4 — Canonical documentation, managed delivery and acceptance evidence.**
Depends on CS3. Goal: agents learn the exact supported scope/commands and a real
disposable owner/executor exercise demonstrates CLI/UI convergence. Paths:
`src/prompts/skills/{ham-ctl-reference,coordinator-task-management,worker-task-management}/SKILL.md`,
`src/prompts/bootstrap_agents.md`, `src/ctl/agent_mode.odin` help,
`src/templates/{coordinator,worker,reviewer,soloist}.md`,
`src/hub/domain/builtin_templates.odin`,
`docs/reference/heimdall_memory_system_and_bootstrap.md`, relevant task lifecycle
and architecture docs, `docs/README.md`; source delivery in
`src/hub/service/agent/{static_skills_gen,static_skills_test,agent_service}.odin`,
`src/bridge/{bootstrap_service,bootstrap_template_engine_test,bootstrap_prespawn_test}.odin`;
new targeted CLI/UI integration evidence under `tests/`/`docs/`.
Extend `tests/ui_owner_controls_test.ts`,
`tests/e2e/owner_local_controls_flow.ts`,
`tests/e2e/owner_local_work_graph_flow.ts`, and add the disposable convergence
scenario `tests/e2e/owner_local_task_cancel_split_flow.ts` as needed.
Acceptance: canonical skills/templates and help agree on authorization, split
manifest, exact replay, checkpoint/drain, cancelled-prerequisite/scope semantics
and workflow restrictions; rendered bootstrap material contains these rules;
existing managed-copy refresh/relaunch requirements documented; independent real
CLI/UI evidence covers happy path plus interrupted/unauthorized/offline cases.

## Documentation and verification strategy

`src/prompts/skills` and `bootstrap_agents.md` are the maintained sources.
`static_skills_gen.odin` is generated by `tools/gen_static_skills`; existing
entries use compile-time `#load`, so changing skill content needs the ordinary
build/bootstrap delivery, not editing installed copies. Regenerate the index
only if skill membership changes. `agent_service.odin` renders the template and
skill manifest; `bootstrap_service.odin` writes provider-specific managed files,
and prespawn cleanup replaces stale material. Confirm supported refresh behavior
in those paths; never promise current sessions update merely because a source
file changed. A live rollout/restart remains a separate authorized action.
Do not edit this instance's `.codex/skills`, `AGENTS.md` or historic SQL migrations
as the product documentation source. Built-in role instructions are compiled
from `src/templates/*.md` through `src/hub/domain/builtin_templates.odin`;
migration 078 removed stale seeded built-in rows from migration 032. Update the
Markdown sources and test their rendered roles, not those historical SQL copies.
Inspect custom durable role/template overrides for contradictory UI-only rules;
report refresh/migration needs explicitly, preserving human customizations.

Verification should include owner contract/golden parsing; table-driven actor
admission; genuine current-schema upgrade/rollback; owner transaction failure
injection at receipt/provenance/edge/outbox boundaries; reopen and replay with a
lost reply; concurrent claim/requirements/review/dependency edits; local and
remote exact-child stop retries and capacity accounting; real CLI nonzero error
behavior; rendered UI replacement and bootstrap skill tests. Use the repository's
pinned Odin/Nix toolchain and unique disposable worktrees/outputs. Test observable
effects and failure recovery, not parser mocks alone. No live M3 service, token,
provider configuration or production chain mutation is part of these checks.

This planning task ran read-only targeted source searches and current CLI help;
no runtime mutation/demo or implementation suite is claimed. Validate this
document's source paths, examples and requirement coverage, commit it, and submit
the existing named-plus-user review gate. Approval is recorded through that
task's review UI/verdict, never inferred from silence, a chat option or this plan.

| Planning requirement | Covered by | Implementation evidence |
| --- | --- | --- |
| REQ-CS-P1 | Baseline, commands/actor matrix, checkpoint/drain and receipt rules | CS1 and CS3 authorization, stale-child, lost-reply and owner-offline cases |
| REQ-CS-P2 | Split manifest, parent disposition, atomic graph/provenance and review rules | CS2 rollback/concurrency/generation/gate cases; CS3 rendered replacement |
| REQ-CS-P3 | CS1–CS4 briefs, canonical/generated sources and pre-coding review gate | Named review per ticket, explicit approval of this planning task before coding |
