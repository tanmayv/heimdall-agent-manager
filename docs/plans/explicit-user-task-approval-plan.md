# Explicit User Task Approval Plan

**Status:** Implemented; focused validation complete, manual UI smoke pending
**Requirement IDs:** `REQ-UAPP-1` through `REQ-UAPP-9`
**Target subsystems:** task contracts/service, Hub HTTP/RPC, `ham-ctl`, UI task creation/editing,
reviewer rendering, bootstrap guidance, tests and checked-in fixtures

## 1. Goal

Make user review an explicit task approval gate rather than a magic reviewer identifier.

Operators and agents should be able to say that a task requires approval from the authenticated
task owner with one obvious CLI flag or UI control. Reviewer lists must show the real authenticated
username, and no runtime path may depend on a hard-coded local-operator pseudo-identity.

## 2. Locked contract

### 2.1 One durable source of truth

Do not add a second database column for user approval. The existing typed reviewer reference remains
the durable source of truth:

```json
{"type":"user","user_id":"<task-owner-user-id>"}
```

The Hub derives `requires_user_approval` from the presence of that exact owner-user reference. This
keeps quorum, cards, task replay and reviewer routing on one representation and avoids drift between
a boolean column and `reviewer_refs_json`.

### 2.2 Mutation API

Task create and update accept an optional boolean:

```json
{"requires_user_approval":true}
```

- Omitted on create: preserve existing default-reviewer inheritance.
- `true`: add the task owner's typed user ref if absent; preserve and de-duplicate agent reviewers.
- `false`: remove only the task owner's user ref; preserve every agent reviewer.
- Omitted on update: leave the approval gate unchanged.
- The Hub resolves the user from the owned chain/task. Callers never submit a username for this field.
- Supplying both `reviewer_refs` and `requires_user_approval` is valid: normalize agent reviewers
  first, then apply the boolean deterministically.
- Caller-supplied `reviewer_refs` entries of type `user` are rejected at public mutation boundaries.
  The explicit boolean is the only supported way to change the user gate.

All task summary/detail responses include canonical `requires_user_approval: bool`. User reviewer
entries returned for presentation include `username` (the authenticated `user_id`) and, when
available, `display_name`; these presentation fields are derived and are not persisted in the actor
ref blob.

### 2.3 CLI

`ham-ctl tasks create` and both user/agent transport modes gain:

```text
--require-user-approval
```

`ham-ctl tasks update` gains:

```text
--require-user-approval
--no-require-user-approval
```

The two update flags are mutually exclusive. The positive flag sends
`"requires_user_approval":true`; the negative flag sends `false`; neither flag omits the field.
`--reviewer` remains for agent IDs/instances only. Legacy pseudo-user values must fail with a clear
message directing callers to the approval flag rather than being serialized as agent IDs.

### 2.4 UI

Task creation and the task-chain inline creation form gain a checkbox:

```text
Require approval from You (@<username>)
```

The task reviewer editor gets the same control, initialized from `requires_user_approval`. Saving it
on or off sends the boolean independently from the agent reviewer list. The current free-form user
ID reviewer mode is removed; agent reviewer add/remove remains unchanged.

Reviewer chips and compact task rows render the owner-user reviewer as `You (@<username>)`. They
must never collapse it to only `User`, a placeholder, or a hard-coded ID. Username comes from the
authenticated `/api/v1/me` result and must match the server-derived reviewer username. If identity
has not loaded, task mutation controls remain disabled instead of inventing a fallback identity.

## 3. Requirements

| ID | Requirement |
|---|---|
| `REQ-UAPP-1` | Add the create/update CLI flags in direct-user and agent-relay modes, including help text and mutual-exclusion validation. |
| `REQ-UAPP-2` | Add the optional task mutation field and canonical response field across HTTP, agent RPC and UI TypeScript contracts. |
| `REQ-UAPP-3` | Server-side add/remove helpers mutate only the owner-user reviewer ref, preserve agent reviewers and are idempotent. |
| `REQ-UAPP-4` | Derive the approval gate from durable typed reviewer refs; do not add duplicated persisted state. |
| `REQ-UAPP-5` | User LGTM/NGTM authorization and quorum require the owner-user ref when the gate is enabled; an unrelated authenticated user cannot satisfy it. |
| `REQ-UAPP-6` | Add create/edit UI controls that set and unset the gate without a free-form user-ID input. |
| `REQ-UAPP-7` | Reviewer lists show `You (@username)` using authenticated identity, including compact cards and edit chips. |
| `REQ-UAPP-8` | Remove legacy reviewer aliases and every hard-coded local-operator pseudo-ID from active code, prompts, tests and checked-in fixtures. |
| `REQ-UAPP-9` | Update generated bootstrap guidance/goldens and add contract, service, CLI, UI and end-to-end regression coverage. |

## 4. Implementation order

1. **Contract helpers and service behavior (`REQ-UAPP-2`–`5`).**
   Add typed helper functions to detect, add and remove the owner-user ref. Apply the optional boolean
   after reviewer-ref parsing on create/update. Emit the derived response field and reviewer username.
   Tighten user vote authorization so a user vote counts only for their own required user ref.

2. **CLI (`REQ-UAPP-1`, `REQ-UAPP-8`).**
   Update argument recognition, direct-user request builders, agent-relay request builders, usage and
   examples. Reject legacy pseudo-user inputs to `--reviewer` rather than interpreting them as agents.

3. **UI API/types (`REQ-UAPP-2`, `REQ-UAPP-7`).**
   Normalize `requires_user_approval`, carry authenticated username into task surfaces, and remove
   hard-coded user-reviewer sets/default IDs. Use typed helpers instead of loose string comparisons.

4. **UI controls (`REQ-UAPP-6`, `REQ-UAPP-7`).**
   Replace free-form user reviewer entry in both creation surfaces with the approval checkbox. Split
   the edit modal into “User approval” and “Agent reviewers,” and render `You (@username)` everywhere.
   Add `data-debug-id` values for both toggles and their rendered reviewer chips.

5. **Guidance and repository cleanup (`REQ-UAPP-8`, `REQ-UAPP-9`).**
   Regenerate bootstrap goldens after updating coordinator guidance. Replace active tests with
   authenticated fixture usernames. Remove obsolete checked-in transcript fixtures containing the
   legacy pseudo-ID rather than hand-editing historical output. Completion requires a zero-result
   tracked-tree sweep for both removed aliases (use composed regexes so the plan itself does not
   preserve them verbatim).

## 5. UI details

Required debug IDs:

- `create-task-require-user-approval-checkbox`
- `taskchain-new-task-require-user-approval-checkbox`
- `taskchain-edit-reviewers-require-user-approval-checkbox`
- `taskchain-task-user-reviewer-${taskId}`
- `taskchain-edit-user-reviewer-chip`

The checkbox label always includes the username. The optional display name can appear as secondary
text, but must not replace `@username`. Turning the checkbox off removes only the current task
owner's approval gate and cannot remove agent reviewers selected in the same form.

## 6. Security and failure behavior

- Ignore no caller-supplied identity: reject user reviewer refs at public write boundaries.
- Derive the reviewer user exclusively from the owner-scoped task/chain loaded by the Hub.
- Reject conflicting CLI flags before sending a request.
- A stale UI cannot unset another user's reviewer ref; ownership checks happen before mutation.
- Missing `/me` identity disables the UI control; it never substitutes a local placeholder.
- User votes from non-designated or non-owner identities return `403` and do not enter quorum.
- Existing rows with a valid owner-user ref require no migration and immediately derive `true`.

## 7. Test plan

### Hub/service

- Create with `true`, `false` and omitted; cover inherited default reviewers.
- Update false removes only the owner-user ref and preserves multiple agent refs.
- Repeated true/false operations are idempotent and never duplicate refs.
- Public typed user-ref mutation is rejected; cross-owner identity is rejected.
- Response derivation survives repository replay/restart without a new column.
- Quorum waits for the required user vote; unrelated user and agent votes cannot satisfy that slot.

### CLI

- Positive create/update and negative update serialize the expected boolean in both transports.
- Conflicting flags and legacy pseudo-user reviewer values fail locally with actionable help.
- Agent reviewer CSV behavior and explicit reviewer clearing remain intact.
- Help/guidance contains the new flag and no removed alias.

### UI

- Create and inline-create toggles send true and false as intended.
- Edit toggle can set/unset the gate while preserving agent reviewer chips.
- Reviewer rows and modal chips show `You (@fixture-user)`.
- No identity loaded means disabled controls and no fabricated username.
- All new interactive elements expose their required debug IDs.

### End to end

Create a task with the CLI flag, observe the named user reviewer in the UI, submit it for review,
approve as that signed-in user, and verify quorum completion. Then create another task, unset approval
from the UI, verify agent reviewers remain, and confirm no user approval card is produced.

## 8. Completion gate

Implementation is complete only when:

- all `REQ-UAPP-*` tests pass;
- Hub, CLI and UI builds pass;
- bootstrap golden tests pass after regeneration;
- the tracked repository has no legacy reviewer-alias or local-operator pseudo-ID occurrences;
- a manual UI smoke confirms the authenticated username in both task rows and reviewer editing; and
- no compatibility shim silently accepts the removed aliases.

## 9. Validation record

- `npm run typecheck` — pass.
- `npm run build` — pass (existing Vite environment/chunk-size warnings only).
- `node --test tests/ui_user_approval_test.ts` — pass.
- `odin test src/ctl -collection:odin_test=src -define:ODIN_TEST_THREADS=1` — 151/151 pass.
- Bootstrap golden executable — all cases pass.
- `odin check src/hub -collection:odin_test=src` and `odin check src/ctl -collection:odin_test=src` — pass.
- `git diff --check` and the tracked-tree retired-identity sweep — pass.

The full taskchain and HTTP suites still contain unrelated pre-existing dynamic-fleet/JIT,
telemetry-frame, and provider-catalog failures. The new approval helpers, typed wire coverage, CLI
coverage, UI contract test, compilers, and builds pass. The remaining completion-gate item is a
manual authenticated UI create/edit/approve smoke test.
