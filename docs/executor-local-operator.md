# Local agent launches (no operator configuration required)

Ordinary agent launches no longer need any host-operator configuration or
per-launch browser approval. A manual launch from the conversation page, a warm
wake, a task-dispatched worker or reviewer, and a managed provider test all
start directly on any enrolled, unlocked Bridge.

## Why this is safe enough

The launch command reaches the Bridge only over the trusted path: the Hub relays
it from the user's own trusted device (the launch payload is vault-encrypted for
the account), and for Bridge-owned chains it is the owner Bridge's own signed
dispatch. The earlier local launch guard (an operator-signed slot policy, an
operator-signed protected directory mapping and a browser "Prepare review" /
"Approve exact launch" step for every launch) is removed. Product decision:
encrypted launch payloads from a trusted device are sufficient authorization.

## What the Bridge still checks before starting a child

- The Bridge is enrolled to the account and its vault is unlocked; a locked
  vault refuses the launch.
- The project path, when present, is an existing directory inside the Bridge
  filesystem sandbox root (the same check as project path validation). A path
  outside the root is refused. It is re-canonicalized just before the child is
  spawned and must still be the directory the launch was staged with.
- The provider is enabled in the provider catalog and the selected provider
  profile is enabled and offers the requested model.
- The launch generation (`run_count`) is current. An older generation is
  refused as superseded; a generation that already ran is not started again.
- One exact live child per instance. A newer generation for an instance whose
  previous child is still alive waits (`instance_not_drained`) until that child
  is stopped or observed absent.

The Bridge still records each launch in its local journal: the generation's
random startup token, the exact Spawn digest, and the child's launch key. Stop,
restart reconciliation and exact absence tracking for warm children use that
record exactly as before.

## Existing installations

Upgrading migrates the local journal (schema 16) without deleting anything.
Existing policy, slot, directory, draft and approval rows are kept but no longer
consulted for local launches. A launch that was waiting for approval before the
upgrade is not revived: relaunch the agent to start a new generation.

## `ham-bridge executor sign|import|inspect`

These commands still work. Signed policy and directory records are only used by
the cross-Bridge owner/executor reservation protocol; they are not required, and
have no effect on, ordinary local launches. Do not configure them to make a
local launch work.
