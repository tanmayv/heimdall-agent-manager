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
