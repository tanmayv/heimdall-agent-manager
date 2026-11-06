# Owner-local static workflows, review roles and source recovery

M2c requirements revision 2 delivers a bounded static same-chain DAG over the
existing owner Store. Full `workflow.v1` compatibility is mandatory successor
`task_18e56a0d15295083`, before aggregate parity and migration. This slice rejects
dynamic definitions instead of interpreting them as static work.

The implementation uses the same signed device commands, exact observed local
children, read-authorized receipt replay and SQLite transaction as the prior
[lifecycle](owner-local-lifecycle.md), [controls](owner-local-controls.md) and
[search](owner-local-search.md) slices. The additive V9 schema follows accepted V8 grants and retains earlier rows,
capabilities and operation identities. No Hub task/workflow authority is added.
See `src/lib/owner_local/migrations.odin:3`, `store.odin:115`, and
`migration_009.sql:54` in that package.

## Commands and setup

Use the owner panel's body field for the JSON documents below. Each button signs
the current expected chain revision, except **Edit dependency** and **Configure
required review roles**, which sign the task revision. Read the chain/runtime
first to obtain that revision. Export a signed request for the existing real CLI:

```bash
./bin/ham-ctl task-chain owner-local relay --request-file owner-local-request.json
```

The relay carries encrypted content. The CLI's transport token is not authority
to create a workflow, edit roles or record a source fact. Device commands retain
the existing chain grant and revocation checks (`src/contracts/owner_local.odin:202`).

| Button / method | Target and decoded body |
| --- | --- |
| Save workflow definition / `workflow.define` | Chain; immutable definition below. |
| Start workflow / `workflow.run` | Chain; `{"run_id":"run_example","workflow_id":"sequence","version":"1"}`. |
| Retry workflow / `workflow.retry` | Chain; `{"run_id":"run_example","execution":"1"}` naming the current generation. |
| Read workflows / `workflow.read` | Chain; existing read payload with cursor/limit. |
| Edit dependency / `dependency.edit` | Ordinary unstarted task and ordinary same-chain prerequisite; `{"prerequisite":"task_before","enabled":"1"}`. Use `"0"` to remove an edge. Generated stage edges remain private to their execution. |
| Configure required review roles / `review.roles` | Task; immutable next role configuration below. |
| Record source fact / `source.observe` | Chain; exact producer episode below. |
| Record source result / `source.consume` | Chain; exact source action below, bound to a current local capability digest. |
| Acknowledge source / `source.ack` | Chain; exact consumed source version/fence. |
| Retire source / `source.retire` | Chain; exact consumed source version/fence. |
| Escalate source / `source.escalate` | Chain; exact due, unresolved, unacknowledged and unretired episode. |
| Close resolved source card / `source.resolve` | Chain; exact producer-resolved episode/version. |
| Read pending sources / `source.read` | Chain; existing read payload with cursor/limit. |

Wire inventories are mirrored by `src/contracts/fixtures/owner-local-schema.json`
and `src/ui/api/ownerSchema.ts`. Nested definitions/facts/pairs use strict schemas:
unknown or duplicate fields reject. Counters are canonical decimal strings;
authority IDs and the current nested JSON format use the existing ASCII parser.
The entire decoded body must fit the existing 8192 UTF-8 byte / 16384 encoded
byte admission limits. This does not change Unicode support in ordinary task
comments or encrypted search queries (`src/contracts/owner_json.odin:52`).

## Static definition and execution

This JavaScript produces the definition JSON to paste into the body field:

```javascript
const stage = (key, depends_on) => ({
  key, title: key, body: "Implement the stage",
  brief: JSON.stringify({goal: key, acceptance: ["Focused checks pass"]}),
  depends_on: JSON.stringify(depends_on),
});
JSON.stringify({
  workflow_id: "sequence", version: "1", title: "Sequential implementation",
  stages: JSON.stringify([stage("first", []), stage("second", ["first"])]),
});
```

There are 1–32 uniquely keyed, topologically ordered stages. Each stage expands
once into one task. A dependency may name only an earlier stage in this
definition. Cycles, unknown prerequisites, duplicate keys and extra dynamic
fields reject before expansion. `inputs`, `for_each`, dynamic output fan-out,
templates (`{{...}}`) and product gate stages are unsupported here. Expansion,
initial requirements revision 1, stage/task identities, dependency edges,
append-only workflow event, source episode, receipt and protected-title
publication intents commit together (`src/lib/owner_local/workflows.odin:10`,
`:43`, `:134`).

Read workflows to obtain generated task IDs. For each task, assign an already
running local worker, configure the named independent reviewer/merge policy and
optionally add required review roles. Requirements revision 1 is already
installed; the worker must present and explicitly ACK it. Existing claim,
heartbeat, submit and review CLI files from the lifecycle guide apply unchanged.
There is no automatic launch or fleet scheduler in this slice.

A task may claim or receive a switch only after its prerequisites are `done`
with ready controls. A successful review with no merge completes the stage;
a Git stage waits for exact durable merge settlement. The execution completes
only when every stage completes (`src/lib/owner_local/workflows.odin:110`, `:129`).

Retry advances the execution and creates fresh deterministic stage identities.
It preserves earlier tasks, immutable outputs, source episodes and event IDs;
retires old authority; invalidates old merge intents; and queues exact-child
checkpoint notices. A fresh old-generation command rejects. A read-authorized
retry of an already committed operation returns its historical result marked
as replay and grants no new authority (`src/lib/owner_local/workflows.odin:60`,
`leases.odin:69`, `lifecycle_agent.odin:49`).

Retry also resolves every obsolete generation task's canonical review producer
inside the retry transaction. It preserves any pending card for explicit exact
closure, and records no synthetic verdict, consumption, ACK or retirement.

Read pages carry `kind: "workflow"`, `runs`, `tasks`, `events`, `revision` and
`next_cursor`. Rows are respectively run summary, stage identity and immutable
event identity. The panel exposes **Next workflow records**. A concurrent owner
commit invalidates a cursor; restart the read from the first page. History is
paginated rather than silently truncated (`src/lib/owner_local/workflows.odin:155`).

## Required review pairs

After lifecycle configuration, the task body for `review.roles` is:

```json
{
  "configuration_revision": "1",
  "requires_user_approval": "0",
  "pairs": "[{\"role\":\"safety\",\"agent_id\":\"agt_auditor\",\"instance_id\":\"inst_auditor\"}]"
}
```

This is a separate, monotonically advancing role-configuration revision. Each
of the 1–16 required `(role, durable agent)` pairs binds an actually running
local child. Duplicate pairs and the author agent reject. Reconfiguration
retires old capabilities/sessions and returns work for a new submission; while
held, its resume state becomes ready. It never reuses an earlier attempt's
approvals (`src/lib/owner_local/review_roles.odin:13`).

The original named independent reviewer remains required. Each additional pair
uses the same agent lifecycle CLI, with methods `review.role.open` and
`review.role.post`. Its payload is the existing review payload plus `role`:

```json
{"requirements_revision":"1","attempt":"1","head":"","verdict":"approve","summary":"Independent findings","role":"safety"}
```

Opening returns a scoped review capability. Post with that exact capability,
submission lease/head/requirements binding, and current task revision. Separate
children retain separate sessions; one child may hold several configured roles.
Every required pair and the original independent reviewer must approve. A
request for changes wins and returns work to ready. Device approval is required
only when explicitly configured with `requires_user_approval: "1"`; otherwise
it is optional and never replaces agent approval. Storage-read failure cannot
waive an owed role (`src/lib/owner_local/review_roles.odin:48`, `:64`).

## Episodes, exact results and cold recovery

Device-attested local source facts use this body:

```json
{"origin_kind":"attention","origin_id":"origin","episode_id":"episode_1","source_version":"7","resolved":"0","deadline_ms":"0","body":"Work awaiting a response"}
```

Updating that same episode requires a greater version. Once resolved, an episode
cannot reopen; recurrence creates a different episode ID. `local.review` and
`local.workflow` are reserved canonical producers, co-committed with new local
submissions/review results/workflow decisions. They cannot be forged through
`source.observe` (`src/lib/owner_local/sources.odin:11`, `:78`).

Source actions name the exact row/version:

```json
{"origin_kind":"attention","origin_id":"origin","episode_id":"episode_1","source_version":"7","consumer_fence_hash":"REPLACE_WITH_SHA256_OF_EXACT_CAPABILITY_JSON","result":"Exact consumer outcome"}
```

Consumption records one result for the exact episode/version/current local
execution-capability digest. Review results automatically consume their exact
producer version in the same transaction as the verdict and receipt. The local
inbox intent is co-committed; replay cannot consume a second time. Human device
facts/results do not claim to authenticate an external producer or remote child.

ACK and retirement may name an exact retained consumption at an earlier version
than the current producer, including after producer resolution. A matching
episode/version/fence consumption is still required, and a future producer
version rejects. Consumption, escalation and card closure continue to require
the exact current producer version.

These facts stay distinct:

| Fact | Meaning |
| --- | --- |
| Consumed | One exact fenced result was committed. |
| Producer resolved | The producer declared that episode complete. |
| Delivered floor | Its durable local inbox projection was materialized and the fenced intent result settled. This is not proof of a human read or native PTY interrupt. |
| ACK floor | An explicit signed acknowledgement of the exact consumed version. |
| Retired floor | An explicit signed retirement of the exact consumed version. |
| Card closed | The owner closed a card for that exact resolved episode. |

`source.read` discovers unresolved **or pending-card** episodes directly from
SQLite, without an origins cache. A resolved old episode with a pending card
survives cold restart. A newer same-origin recurrence cannot block closure of
that old episode. Pending cards cannot be pruned as merely resolved, and their
related receipt bodies remain pinned after delivery. Reads never imply ACK,
consumption, retirement or closure (`src/lib/owner_local/sources.odin:134`,
`retention.odin:23`, `migration_009.sql`).

Source reads are bounded, carry a continuation cursor, and the panel exposes
**Next pending sources**. Cursor invalidation requires a fresh first-page read.
Source prose and workflow definitions index in the owner transaction and rebuild
from canonical rows on restart. Submission and handoff prose retain their
original canonical search documents rather than being copied into source bodies
(`src/lib/owner_local/search.odin:79`).

## M2 command-matrix reconciliation

This is slice completion, not whole-product migration or CLI parity approval.

| Original M2 area | Delivered owner-local behavior | Explicit remaining gate |
| --- | --- | --- |
| Content/edit/delete/search | Chain/task/comment, requirements, immutable submission attempts, handoff/control prose; scoped grants and durable FTS rebuild. | General aggregate/field/ordinary CLI parity: `task_18e569e48d6b5532`. |
| Controls/assignment | Hold/release/cancel/reopen/resolve, exact-child handoff/block/checkpoint/switch and unchanged merge retry. | General auto-launch/provider scheduling and remote reservations remain M3. |
| Workflow definitions/runs/executions/dependencies | Static same-chain DAG, atomic stage expansion, unique identities/events, fresh retry generation, stale-result rejection and paged history. | Full `workflow.v1` language, dynamic input/output fan-out, templates and gate stages: mandatory `task_18e56a0d15295083`. |
| Required review-role sets | Named independent reviewer plus every configured exact agent-role pair; explicit optional user gate and request-changes precedence. | Rich workflow-generated role/template policies follow full language/parity. |
| Source episodes/results/recovery | Canonical local review/workflow producers, signed device facts, exact result/intent commit, distinct resolution/delivery/ACK/retirement/card closure; both R2C regressions. | Authenticated external producer and canonical linked-content/envelope integration: `task_18e569e4a29a0fbe`. Existing V7 history is retained, not automatically converted into source episodes. |
| Grants/listing/owner registry | Existing signed grants and protected titles/access/routing only; no second writer. | Registry fixes `task_18e569e455cd82bb`; grant/replacement lifecycle `task_18e569e4750fe9fd`. |
| Artifacts and migration/recovery | No artifact extractor or replacement authority introduced. | Artifact-content indexing remains deferred; canonical linked bodies are covered by C3. M4 still requires ordinary new/migrated client convergence and restore/resource/platform validation. |

## Reproduction

From the managed task checkout, use unique outputs under `$HOME`:

```bash
nix develop --command odin test src/lib/owner_local \
  -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/workflow-store-verified
nix build -L .#ham-hub .#ham-bridge .#ham-ctl .#ham-pty-host \
  -o "$HOME/.cache/heimdall-tests/workflow-final-build"
nix develop --command odin build tools/owner_local_test_identity \
  -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/workflow-identity
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN="$HOME/.cache/heimdall-tests/workflow-final-build/bin/ham-hub" \
  HEIMDALL_E2E_BRIDGE_BIN="$HOME/.cache/heimdall-tests/workflow-final-build-1/bin/ham-bridge" \
  HEIMDALL_E2E_CTL_BIN="$HOME/.cache/heimdall-tests/workflow-final-build-2/bin/ham-ctl" \
  HEIMDALL_E2E_PTY_BIN="$HOME/.cache/heimdall-tests/workflow-final-build-3/bin/ham-pty-host" \
  HEIMDALL_E2E_IDENTITY_BIN="$HOME/.cache/heimdall-tests/workflow-identity" \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_CONTROLS=1 \
  HEIMDALL_E2E_OWNER_WORKFLOWS=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs
```

The disposable demo retains prior actual CLI/UI/Git cases and adds workflow
retry/restart, old-generation rejection, sequential required-role review,
source cold recovery/recurrence, protected-only Hub database/log checks, search
rebuild and rendered workflow/source panels. It does not restart production.
Focused evidence is beside the implementation in `workflows_test.odin`,
`review_roles_test.odin` and `sources_test.odin`. The latter preserves the two
reviewer scenarios from R2C without importing the rejected Hub-authority branch.


## Original workflow.v1 language successor

The original-language transport, dynamic fan-out/templates, structured outputs,
on_output siblings and explicit coordinator/user gate paths are documented in
[owner-local-workflow-language.md](owner-local-workflow-language.md). The static
wrapper in this document remains a separate supported transport.
