# Owner-local single-device leases

This slice extends the create/task/comment/read demo with a signed assignment of
one task to an already-running local instance, an exact-child lease claim, and
heartbeat renewal. [Requirements, submission and independent review](owner-local-lifecycle.md)
extend this same path. Workflows, remote reservations, provider launch scheduling,
and migration remain separate tasks.

## Try it

Open **Task chains → Owner-local** and select the enrolled online owner Bridge.
Create a chain and task, or select an existing local task and **Read task**.
Enter a running instance ID, a positive configuration revision, and the task's
current revision. **Assign local instance** signs the fleet edit with the human
device key. **Read runtime** observes that task's assignment and live lease
through the same encrypted owner relay. The Hub stores no fleet or lease fields.

From that instance's own managed CLI, write a private request file:

```json
{
  "protocol_version": "1",
  "chain_id": "chain_example",
  "task_id": "task_example",
  "lease_id": "lease_unique",
  "configuration_revision": "1",
  "expected_revision": "2",
  "operation_id": "op_unique",
  "method": "lease.claim",
  "request_expires_ms": "REPLACE_WITH_CURRENT_UNIX_MS_PLUS_300000",
  "capability": ""
}
```

```bash
./bin/ham-ctl task-chain owner-local lease --request-file lease.json
```

Use the current task revision returned by the fleet edit; the example assumes a
new task at revision 1 followed by its first fleet edit. IDs and expiry are
explicit so the file can be retried byte-for-byte after a lost response.
The CLI exits nonzero for rejected owner operations.

A successful response's `data.body` is JSON containing `lease_id`,
`capability` (a signed JSON string), `deadline_version`, and task `revision`.
For a heartbeat, retain the lease/config/task identities, set a **new**
`operation_id`, change `method` to `lease.heartbeat`, copy the entire most recent
capability string, and use a fresh request expiry. Retry the exact same file to
recover an uncertain outcome; do not mint a new operation ID for a retry.
A replay is historical evidence, never permission to launch or resume work.

### Ordinary verbs (R4a)

The hand-built request file above is the low-level path and keeps working. On a
chain its own Bridge owns, an agent can instead use the ordinary verbs with no
lease JSON, capability or owner document:

```bash
./bin/ham-ctl lease next                       # claim; creates the Workdir, writes TASK.md
./bin/ham-ctl lease heartbeat --lease <id> --acknowledge-requirements-revision <n>
./bin/ham-ctl lease submit --summary "<checks and outcomes>"   # Workdir must be committed
./bin/ham-ctl review post --task <id> --verdict approve        # the configured reviewer
```

The Bridge proves the exact live child from the instance token, and one policy
(`src/lib/owner_local/agent_authority.odin`) authorizes the verb: a worker only
on its fleet-bound task, the configured reviewer, and the chain's enabled
coordinator member for `task create|update|comment|show`, `task-chain show|
summary set|propose|publish` and `review post --on-behalf-of user`. The owner
key then signs the command. A claim creates `<repo>/.heimdall/worktrees/<task>`
on `heimdall/<task>` from the configured base. Chains the Bridge does not own
go to the Hub, which answers writes on an owner-held chain with a typed
`owner_authority` error naming the owner Bridge
(`src/bridge/owner_agent_routing.odin`, `src/hub/transport/http/owner_authority.odin`).

## Authority and local persistence

The owner verifies the current human device directory and local read/mutation
grant before changing fleet configuration. The fleet row retains the original
signed command and exact payload, its configuration revision, and the locally
observed instance/run/launch/token binding. Configuration revisions must increase;
live reassignment now retires old authority and records exact-child checkpoint
intents plus immutable signed assignment history. See
[owner-local-controls.md](owner-local-controls.md).

The Bridge verifies the agent token again under the token mutex and asks the
actual PTY daemon for that instance's exact launch key. A running status flag,
content key, copied old capability, or a caller-supplied instance ID cannot
replace this proof. Initial Hub-created instances have no migration launch epoch;
their unique persisted local launch-key digest supplies a stable
`local_<digest>` epoch. Explicit migration epochs remain unchanged. Token rotation
changes the token generation and invalidates the old binding.

The Bridge signs the exact command, including operation ID, payload/capability
digest, account/owner/chain/task/lease, child identity, configuration revision,
task revision, and request expiry. The local store verifies this attestation and
the pinned fleet binding. The returned owner-signed capability additionally
binds requirements revision (initially 1), allowed methods, expiry and hard cap.
It is usable only with the same currently authenticated local child.

Current read scope precedes receipt lookup. Matching commands replay before
request expiry, task revision, live capability/deadline checks, and mutation
admission; changed canonical input conflicts and tombstones reject. Renewals
replace the current capability. Replaying a prior renewal returns its historical
result without making an older capability current again. Device fleet receipts
remain readable after their target child exits. Agent replay requires the
currently authorized child and enabled assignment. A new configuration revision
for the same still-authorized child does not suppress historical receipts;
live misses require the current configuration revision.

Migration 3 adds local fleet snapshots, exact lease fences and receipt pins.
Unique partial indexes permit one live task lease and one live holder across all
chains in the profile. Claim/renewal, signed capability, receipt, pins and change
sequence share one transaction; no IPC or network call occurs inside it.
Current configuration receipts remain pinned, and every active lease pins its
claim, renewal and configuration receipts against compaction.

A lease lasts 15 minutes; renewals stop at the original one-hour hard deadline.
The persisted deadlines survive owner restart. A Bridge worker runs every
30 seconds, independently of requests and Hub availability, retires expired
leases atomically, and retries the durable registry outbox. Backward clocks latch
clock uncertainty and deny timed mutations. Expiry is a separate decision;
receipt replay itself neither retires nor renews leases. Token replacement
requires a fresh signed assignment after the old lease retires.

## Validation boundary

The real enrollment harness can add the single-device lease leg:

```bash
nix develop --command env \
  HEIMDALL_E2E_HUB_BIN=<built-hub> \
  HEIMDALL_E2E_BRIDGE_BIN=<built-bridge> \
  HEIMDALL_E2E_CTL_BIN=<built-ctl> \
  HEIMDALL_E2E_PTY_BIN=<built-pty-host> \
  HEIMDALL_E2E_IDENTITY_BIN=<owner-local-test-identity> \
  HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1 \
  node --import ./tests/helpers/vaultEndpointHarness.ts \
    tests/e2e/bridge_real_enroll_e2e.mjs
```

Add `HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_TRANSPARENT_ONLY=1` to run
only the ordinary-verb leg (`tests/e2e/owner_transparent_flow.ts`): lease next,
ACK, submit, coordinator verbs, refusals, review and merge through plain ham-ctl.

This uses disposable OIDC accounts, enrollment and key delivery, real Hub/Bridge/
CLI binaries, a real PTY daemon and an actual synthetic provider process. It
checks fleet edit through the UI client/Hub relay, agent claim/replay/heartbeat,
human runtime observation, and rejection after child stop. It does not establish
support for any native provider's interrupt profile or for other operating
systems. The original V1 relay/pagination/offline cases remain in the run.

The storage probe separately uses real SIGKILL before and after lease COMMIT,
then restarts and replays the lost grant reply after durable expiry. Unit tests
exercise signature tampering, stale children and capabilities, cross-task holder
uniqueness, revision/clock/deadline checks, deferred-FK COMMIT failure, migrations,
receipt pins and compaction.

## Source entrypoints

| Boundary | Source |
| --- | --- |
| Mirrored wire inventory | `src/contracts/fixtures/owner-local-schema.json:15` |
| Human fleet edit | `src/lib/owner_local/store.odin:196` |
| Exact-child and live daemon authentication | `src/bridge/owner_local_leases.odin:16` |
| Atomic lease admission and historical replay | `src/lib/owner_local/leases.odin:41` |
| Periodic expiry/publication | `src/bridge/owner_local_leases.odin:78`, `src/lib/owner_local/leases.odin:131` |
| Retention pins | `src/lib/owner_local/retention.odin:18` |
| Agent CLI | `src/ctl/taskv2_cmds.odin:1336` |
