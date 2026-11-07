# Native migration observations

The executor V11 additions are private storage foundations for the migration
adoption decision. They do not expose a migration endpoint or authorize drain,
import, cutover or task execution. Ordinary migration routes remain disabled.

`executor_legacy_observations` records a validated wake request's exact original
parent and entry digests, original entry index, parsed instance/task/lease/chain,
transformed native request digest and referenced immutable local draft. The
Bridge writes the association before retrying draft consent. Later requests can
refer to the same draft without overwriting its first material. The native
request digest describes the incoming proposal; the referenced draft retains
the actual selected configuration and startup material. This row is not a
receipt that the requested action executed. No raw token or command body is
included in the observation record or a public projection.

Exact observation retries return the retained identity without mutation;
altered evidence under the same parent/index/native-request/draft identity
conflicts. Storage or quota failures refuse the retry before applying consent.
A failed new association may leave an inert pending draft; it does not add
consent. Original material and all observations remain immutable across restart.

`executor_native_journal` maintains a transactionally incremented sequence for
mutations of retained executor tables. The sequence and incarnation form a
database snapshot CAS. The internal barrier installation can compare an
optional captured snapshot under its write transaction; stale snapshots refuse
a new installation. Exact already-installed barrier replay is read-only and
does not require a still-current snapshot. Existing trusted internal callers
without a snapshot do not acquire verified-observation authority.

The sequence covers database changes, not dispatcher queues, physical children,
filesystem users or startup registry memory. Its immutable
`prior_coverage_unknown=1` explicitly preserves uncertainty about pre-upgrade
work, even at source generation zero. First-wake draft observations do not
cover wake-existing nudges, stops, merges or alternate launch producers. The
signed complete inventory, independent physical observation, device adoption,
source binding, complete resource barrier and exhaustive drain protocol remain
required before migration can proceed. Never use observation counts, handler
returns or a matching database sequence as proof of physical absence.

The V10-to-V11 upgrade rebuilds the versioned runtime header and recreates its
retained dependent triggers in the same opening transaction as the new tables.
Collision and deferred-COMMIT tests verify rollback and recovery while retaining
native material and prepared reservation identity.

## Dispatcher memory currentness

The private Bridge dispatcher snapshot captures queued and running claims, exact
received-byte digests, connection generation and a monotonic memory revision.
It also hashes the actual queue bytes and rejects missing, duplicate or
inconsistent claim evidence. Taking a job changes its claim to running under
the dispatcher lock, before the worker copies its current command identity;
the transfer interval cannot appear idle. Admission, take, finish, stale queue
drop and reconnect invalidate older snapshots. Revision saturation refuses
further valid observations rather than allowing an ABA.

The snapshot is local process memory, not durable packet history or a complete
migration inventory. Returned jobs may leave live children. Inline handlers,
startup specs, protected filesystem users, old admissions and daemon children
require separate union evidence. A matching snapshot does not imply any of
those are absent. No signed receiver consumes this snapshot yet. A future CAS
consumer must retain the dispatcher lock through the guarded operation and
combine it with the established physical/startup/database gates. Snapshot
digests use the caller temporary arena and must be copied for retention.

## Durable worker-boundary observations (V12)

V12 adds private received-action occurrences, separate from invocation receipts.
Each occurrence has its original optional command ID and chain claim, actual
selected command kind, raw packet digest, native incarnation and monotonic
journal identity. Identical packets get independent occurrences. Raw bodies,
tokens and payloads are not retained in this table. Identity fields cannot be
rewritten or deleted; journal and state changes commit atomically.

States are `received -> prepared -> running -> returned`, or
`received/prepared -> discarded`. `prepared` is an observation reservation before
the handler, **not** evidence that the packet entered a durable dispatcher queue.
Only the last exact transition can replay read-only. Changed transition inputs
conflict, and old incarnations cannot newly finish unresolved records. Historical
start replay cannot run another handler. A returned handler may leave children,
merges or resource users alive; a discarded occurrence says nothing about other
occurrences of the same packet.

The worker records relevant paired actions before invoking the handler and
refuses the handler on persistence failure. Initial required families are Agent,
Filesystem, VCS, Shell and LSP. This is not exhaustive effect classification:
MCP, provider, setup and nested work may affect protected resources and remain
unknown unless relevance is independently excluded or inventoried. Diagnostic
compatibility confers no migration coverage. Only no configured Bridge identity
permits pre-enrollment compatibility; a configured but unavailable identity or
account journal refuses relevant work. A job admitted while paired cannot
silently lose that requirement while waiting. Enrollment after unpaired queue
ingress requires a fresh worker observation and preserves the unknown interval.

Journal I/O stays off the WebSocket reader and outside the dispatcher mutex.
The reader only captures the paired-observation requirement in memory; the
worker opens/rechecks the journal under the executor application mutex before
handler I/O. No database transaction spans a physical handler. This checkpoint
does **not** provide durable queue ingress: crashes/reconnect drops/deadlines
before worker admission may have no action row, and their earlier coverage stays
unknown. There is no signed completeness receiver or barrier consumer for these
records. Native target/draft/child associations, inline/startup/alternate
producers and the full physical/resource union remain required.

V11-to-V12 rebuilds the runtime header transactionally while recreating retained
runtime references, preserving the native journal sequence and immutable
`prior_coverage_unknown=1`. Historical fixtures remove newer tables before
reconstruction. Name collision and deferred COMMIT tests retain native draft
material and reservation identity across failed upgrades and recovery.

## Selected native draft associations (V13)

V13 links a current running receive occurrence to a selected immutable native
draft. The row keeps the exact original entry index/digest and the incoming
transformed-request digest separately from the selected configuration/material
digests. Instance and directory identities are derived from the retained draft
configuration. The draft retains its original material and eventual launch link;
association rows cannot provide consent, a task grant or a child launch receipt.

The worker carries its occurrence alongside runtime invocation arguments.
Neither `Executor_Local_Material` nor its serialized origin gains a field, so
existing material and local consent identity stay unchanged. Ordinary launch,
provider-test and fresh/retry wake staging pass this metadata. Scoped and idless
wake entries retain separate occurrences; empty original IDs and chain claims
stay empty. V11 scoped observation checks remain unchanged. Alternate producers
that carry no occurrence remain unknown.

A whole-packet association must match its retained parent digest; batched wake
handlers use the original raw entry spans and indexes. An exact association
replay is read-only after handler return or restart, while changed entry evidence
or incarnation conflicts. New associations require the current running
occurrence. Native selected identity comes from immutable stored configuration,
not from the packet's claimed chain or a supplied target label. Later incoming
proposals may associate with an earlier selected draft without overwriting it or
claiming that the new proposal executed.

This still excludes wake-existing nudges, exact stop/merge target associations,
inline/startup/alternate producers, complete durable queue ingress and physical
resource/child absence. All remain required for the signed complete union and
migration-only device adoption. No inventory/binding/drain/cutover route is enabled.

V12-to-V13 upgrade failure tests preserve running occurrences, native draft
material and reservation state across name collision and deferred COMMIT failure.
Retained triggers are recreated around the runtime-header rebuild; the native
journal and immutable unknown-coverage marker are preserved.
