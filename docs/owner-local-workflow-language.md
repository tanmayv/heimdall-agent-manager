# Owner-local workflow.v1 language

This extends the explicit static DAG transport described in
[owner-local-workflows.md](owner-local-workflows.md). The original language is
kept as a document inside a separate exact wrapper; the static `stages`
wrapper is not reinterpreted as workflow.v1. The source parser is
`src/hub/service/taskv2/workflow.odin:120`; the authority-free language adapter
is `src/lib/workflow_v1/language.odin:1`, with its strict owner boundary in
`src/lib/workflow_v1/boundary.odin:71`.

## Compatibility matrix

The original source column identifies the authoritative behavior. Local
equivalents use the same stage and placeholder vocabulary. All definitions,
inputs, tasks and outputs remain in the owning Bridge database.

| Construct | Original source | Owner-local equivalent |
| --- | --- | --- |
| `schema: workflow.v1` / `kind: workflow`, `version` / `v`, `name` / `id`, title and description | `workflow.odin:120` | Original spec bytes pinned by immutable definition ID/version; `language_definition` in `src/lib/owner_local/workflow_language.odin:13`. |
| Input array declarations, object declarations, shorthand types, required/type/description annotations and raw defaults | `workflow.odin:564` | Original input parser and immutable input snapshot; `src/lib/workflow_v1/plan.odin:26`. Missing/null fan-out inputs fall back to a non-null declared default. |
| Stage `key` / `id`, `depends_on` / `needs`, arbitrary DAG order, unknown/self/cyclic references | `workflow.odin:120` | Original graph validation, followed by lazy readiness reconciliation; `language_refresh_pass` in `src/lib/owner_local/workflow_language.odin`. |
| Task and gate stages; stage title, description and brief | `workflow.odin:74`, `workflow.odin:916` | Rendered task requirements, immutable original-stage/index provenance, and explicit gate tasks; `plan_stage` in `src/lib/workflow_v1/plan.odin:38`. |
| `parallel`, stage/default/item priority, `max_parallel` | `workflow.odin:916` | Deterministic indexed copies, preserved effective priority, and live-lease stage concurrency admission in `language_claim_ready`. Manual child assignment remains the current execution model. |
| Input fan-out `inputs.name` / `workflow.input.name`; object and scalar items; default/positional item keys | `workflow.odin:378`, `workflow.odin:437` | Original item resolution and fallback rendering; plan first, persist all indexed tasks in one transaction. |
| Stage output fan-out `s.output.field`, `s.outputs[0].field`, `s.outputs[].field`, and their `stage.s` forms | `workflow.odin:492`, `workflow.odin:916` | Current execution/current successful attempt outputs only; aggregate form flattens outputs in stage-index order. |
| Empty lists, item ordering and fan-out size | `workflow.odin:371`, `workflow.odin:916` | Zero-item expansion marker counts as success; deterministic indexes; cap 256 per stage; dependencies retain transitive ancestors through empty stages. |
| `inputs.*`, `workflow.input.*`, `stage.key/index/count`, `item`, `item.*`, upstream output fields and supported array lengths | `workflow.odin:1268` | Original scalar/raw rendering and item title/key fallbacks; JSON escaping when rendering briefs. Unknown/malformed template expressions reject at the owner boundary. |
| Brief/stage output declarations; `inline`, required-field aliases, `task_list.v1`, `findings.v1` | `workflow.odin:630`, `workflow.odin:649` | Structured submission payload, original contract validation, immutable attempt output row, exact historical read and search rebuild. |
| Brief acceptance, inputs, assignee, reviewers, review roles and budget metadata | `src/hub/service/taskv2/brief_schema.odin:16` | Brief fields retained in requirements rather than reduced to goal/acceptance. Explicit assignee and required reviewer/role bindings are checked before claim and approval. Rich aggregate graph/budget bookkeeping is the C1 successor; automatic matching is M3. |
| Gate prompt/approver aliases and explicit user approval | `workflow.odin:120`, `gate.odin:31` | Signed human `workflow.gate`; explicit `user` and `requires_user_approval` never accept coordinator authority. |
| `user_or_coordinator` | `gate.odin:31` | Either signed human verdict or a signed, versioned durable coordinator binding plus exact live child/capability. `src/lib/owner_local/workflow_coordinator.odin:9` and `:32`. |
| Definition/input snapshots and fresh retry executions | `workflow_execution.odin:324` | Terminal executions retry from the original pinned definition/input snapshot; old authority is revoked and old outputs stay historical. Generated tasks cannot reopen individually. |
| Pending merge and consumed-output retry guards | `workflow_execution.odin:324`, `workflow_execution.odin:542`, `verbs_m2.odin:553` | Retry/cancel fence unsettled Git effects; a started sibling permanently pins the source generation even after completion. |
| `brief.on_output.start_workflow` / `workflow`, default output-as-inputs, explicit input map and `{{output.*}}` / `{{output}}` binding | `workflow_execution.odin:391`, `workflow.odin:1654` | Same-chain local reference resolution, deterministic sibling identity per source task/attempt, pinned target definition/inputs, source-run dependency and consumption row. Output placeholders survive stage rendering until submission. Missing refs/invalid inputs produce a durable visible trigger failure. |
| Built-in templates | `workflow.odin:16` | Import the original `explore_plan_build`, `fix_flaky_tests`, and `security_audit` JSON documents as local definitions. No fallback to Hub execution or cross-owner lookup. |
| Removed verification commands and unknown behavioral fields | `src/hub/service/taskv2/verify_removed.odin:6` | Reject instead of silently dropping or executing them. The owner boundary retains its existing strict document-reader rules. |

The bare source filenames above are under `src/hub/service/taskv2/`.
The language tests import all three original templates and cover the original
fan-out/template/output forms in `src/lib/workflow_v1/language_test.odin:12`.
The signed storage regressions are in
`src/lib/owner_local/workflow_language_test.odin`.

## Transport and execution

The existing encrypted `workflow.define` body accepts this exact new shape:

```json
{"workflow_id":"my_definition","version":"1","title":"My workflow","spec":"<original workflow.v1 JSON>"}
```

Start it with an immutable input snapshot:

```json
{"run_id":"my_run","workflow_id":"my_definition","version":"1","inputs":"{\"goal\":\"Implement the change\"}"}
```

An agent submits an output as a JSON document string alongside the ordinary
summary, requirements revision and head. Existing summary-only submissions
remain valid when no output contract requires a result.

```json
{"requirements_revision":"1","head":"","summary":"Completed","output":"{\"summary\":\"Checked\"}"}
```

A human gate body binds the exact execution and original stage key:

```json
{"run_id":"my_run","execution":"1","stage_key":"approve","verdict":"approve","summary":"Proceed"}
```

Bind a coordinator with `workflow.coordinator`, using an existing durable agent
and its actual running instance:

```json
{"configuration_revision":"1","agent_id":"agt_existing","instance_id":"inst_running"}
```

The Bridge observes the exact launch epoch, run count and token generation under
the existing child/token locks. The signed capability returned in the receipt
allows only `workflow.gate.post` for that chain and binding for 15 minutes.
Renewal/replacement requires the next configuration revision. A coordinator
uses the existing owner-local lifecycle request-file path, with the actual gate
task ID, binding revision and returned capability. Replacement bindings revoke
old access even to old receipts; successful exact replay under the current
binding precedes mutation expiry/generation checks. User-only gates still reject
it. No coordinator identity is inferred from a name or caller assertion
(`src/bridge/owner_local_leases.odin:16`;
`src/lib/owner_local/workflow_coordinator.odin:32`).

Dynamic runs require terminal state before retry. To cancel a running execution,
use `workflow.cancel` with
`{"run_id":"my_run","execution":"1","reason":"Retry the original snapshot"}`.
The existing retry body remains
`{"run_id":"my_run","execution":"1"}`. Historical outputs are available through
`submission.read`'s explicit attempt and `output` field.

The local slice bounds definitions to 32 stages, fixed parallel copies to 50,
fan-out to 256 items per stage, runs to 128 per chain, and total generated-task
and dependency retention to the existing account quota. Existing encrypted-body
and rendered-field limits still apply. A failed expansion publishes no partial
stage. A zero-item expansion persists an explicit marker.

Schema V11 adds the language after accepted V8 grants, V9 static workflows and V10 context compaction. V12 preserves V11 evidence while allowing a null run/execution pair for ordinary task-attempt output prerequisites. Runtime
expansion and source/capability/receipt/dependency changes share the owner UoW.
Registry preparation is a durable intent: it freezes exact encrypted/signed
registry bytes locally before network delivery. Recovered claims reuse those
bytes (`src/lib/owner_local/workflow_language.odin:219`). Neither parsing,
planning nor an owner transaction invokes Hub workflow authority.

## Verification

The real disposable demo is `tests/e2e/owner_local_language_flow.ts`, enabled
with `HEIMDALL_E2E_OWNER_LANGUAGE=1` in the existing enrollment harness. It imports
the three templates, then executes dynamic source output, fan-out, exact-child
coordinator approval, human-only denial, independent results, a consumed sibling,
explicit gate retry, cold restart, search and the rendered production panel.
It can run together with the retained lifecycle/controls/static workflow demo.
No live service restart or deployment is involved.

Commands and final outcomes are recorded in the task's submit summary. Focused
checks include the pure language suite, owner store suite, shared contracts,
original workflow regressions, retained UI tests, typecheck, affected binary
builds and that complete real demo.

Ordinary tasks can set the same strict `output` and `on_output` fields through
`requirements.edit`; static workflow task briefs also retain them. Trigger
identity binds the immutable submitted task attempt, requirements and output.
An ordinary producer gates its sibling on that exact completed attempt;
a static or language producer gates its sibling on the entire source execution.
Once the sibling starts, reopening the ordinary source or retrying its source
workflow is rejected. Superseded execution prerequisites cannot start a sibling.

At the exact 128-run chain budget, automatic follow-ups record one durable
`workflow_budget` trigger outcome per source attempt. Workflow inventory exposes
that outcome for ordinary and generated producers, including after restart;
it never silently reports a follow-up as executed. Missing-reference and invalid
input outcomes use the same bounded, immutable failure ledger.

Explicit `requires_user_approval: true` in an ordinary or static producer's
immutable submitted brief is an additional completion gate. Independent agent
approval and coordinator capabilities cannot satisfy it; the signed human
verdict is required before completion, merge intent creation, or sibling release.
Stage and separately configured role approval requirements remain additive.
