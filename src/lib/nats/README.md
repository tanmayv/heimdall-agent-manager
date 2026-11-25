# Synchronous JetStream binding

This package wraps the nats.c version/source/hash selected by `flake.lock`
(currently 3.13.0, Apache-2.0). `nix/nats.nix` builds the client and the private
`adapter.c` ABI adapter. JetStream config structs stay in C rather than mirroring
their version-sensitive layouts in Odin. There are no callbacks into Odin and
no asynchronous subscriptions.

The source pin is unchanged. Both the shared Nix derivation (native, static and
cross builds) and the Windows source builder apply the minimal leading-zero
fraction correction in `nix/patches/nats-encode-time-utc-leading-zeros.patch`.
Nine nanosecond digits are printed before the existing trailing-zero trim, so
62ms remains `.062Z`, rather than becoming `.62Z`. Patch context drift fails the
build; the Windows equivalent uses built-in PowerShell/.NET without requiring
Git or a patch executable. Version/archive hashes, TLS and static settings stay
with the existing pins.

## Build and verify

```bash
nix develop --command sh -c 'odin test src/lib/nats -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/nats-$$'
nix build .#checks.x86_64-linux.nats --no-link
nix build .#ham-hub .#release-ham-hub --no-link
```

The dev shell supplies `nats-server`, the adapter and client libraries.
The Nix check runs the real-server suite with Odin memory tracking, then on Linux
runs the same executable under Valgrind. A narrow suppression covers the pinned
Odin runtime's byte-builder resize padding reads; NATS/C diagnostics and all
definite/indirect leaks still fail the check. Valgrind also reports Odin's global
arguments and temporary arena as possibly lost (4,194,406 bytes); these runtime
allocations are not classified as task leaks. No existing server or credentials are
used. `src/lib/natstest` is the reusable fixture: the server chooses its own port,
writes a ports file, and owns an isolated temporary JetStream store. Always call
`natstest.destroy`, even when startup fails. `natstest.stop` supports outage tests.

The Linux Nix check requires writable existing tmpfs at `/dev/shm` with at least
256 MiB free. It selects a private mode-700 `TMPDIR`, prints its location and
capacity, and removes it on exit without replacing the builder's cleanup trap.
The real server still uses file-backed JetStream stores, including restart and
persistence assertions; request deadlines and leak checks are unchanged. This
isolates short-deadline fixtures from the host's shared disk. A matched diagnostic
passed on tmpfs and failed under Valgrind on disk, but did not establish the
cause of historical timeouts. macOS and direct dev-shell runs keep their existing
temporary-directory selection. Missing tmpfs fails clearly; it does not skip tests.

The time regression calls the actual linked client encoder for whole seconds,
leading-zero fractions down to 1ns, 10/60/62/80/81/90ms and 100/990ms controls.
Real consumer-info responses must record each exact cutoff and preserve filter,
ack and replay settings. A stored target's authoritative metadata supplies the
inclusive boundary and the one-nanosecond-later exclusion control; no publication
timing assumption, sleeps or retries are used. The test decodes fractional digits
independently of Odin's generic RFC3339 parser. It retains global shutdown and
the existing tracking allocator assertion. Windows's linked version/TLS smoke
also checks exact encoder output; `scripts/windows/test-build-nats.ps1` checks
patch parity and clear drift rejection without Visual Studio. Running that script
on Linux does not establish native Windows compilation or execution coverage.

TLS is **enabled**, with hostname verification and OpenSSL from the same package
set used by pinned curl. Libsodium, legacy NATS Streaming and examples are
disabled. nats.c's built-in NKey implementation supports credentials files.
Native builds link the client/adapter archives to native shared OpenSSL. The
Linux release hub uses the same archives built with `pkgsStatic`, musl and static
OpenSSL. `release-ham-hub` exercises `mkStaticLinuxOdin`. The app records the linked
client version without opening a connection; runtime configuration belongs to E0b.

## API and ownership

Every public procedure documents its ownership in source. All strings and byte
slices passed to operations are borrowed only for the call. Embedded NULs are
rejected. Timeouts are milliseconds; stream/consumer durations are nanoseconds.

1. `connect({url, creds_file, ca_file, timeout_ms})` returns a C-owned connection.
   `creds_file` is an optional chained JWT/seed credentials file. `ca_file` loads
   trust anchors and requires TLS; `tls://` URLs also select TLS through nats.c.
   Reconnect buffering is disabled so outages produce errors rather than silently
   accumulating unconfirmed publishes. nats.c may reconnect internally.
2. `stream_add`, `stream_update`, `stream_info` return copied state. Config selects
   file storage with limits (default) or work-queue retention, supports multiple subjects, age, duplicate
   window, replicas and rollup. Update replaces configuration; it is not a patch.
3. `publish` waits for the JetStream PubAck and returns sequence plus duplicate
   flag (a C integer, nonzero means true). It supports arbitrary repeated headers.
   Its explicit message ID overrides an arbitrary `Nats-Msg-Id` header.
4. `consumer_add` creates an explicit-ack durable pull consumer with one or several
   subject filters, ack wait, maximum deliveries, optional `max_ack_pending`, and\n   `deliver_new` (false preserves delivery of stored history). `pull_bind` attaches to an
   existing consumer; `pull_destroy` frees only the local subscription and preserves
   the durable consumer. `consumer_delete` removes the server consumer explicitly.
5. `fetch` returns an owned batch, or nil on failure (including timeout). Messages,
   payload, subject and header views are borrowed from that batch; do not mutate
   or free them. Copy any data that must survive `batch_destroy`. Metadata is copied.
   `ack` waits for server confirmation. `nak` and `term` queue their protocol ack;
   they do not destroy the message or synchronously confirm server processing.
6. Destroy batches before pulls, then destroy the connection. Destructors accept
   nil; nonnil handles must be destroyed exactly once. Serialize access to a Pull.
   Do not destroy handles concurrently with any operation.
7. At process teardown, after all users and handles are gone, `shutdown` waits for
   nats.c's global threads. It must not race any call or run per connection.

`Error.status == 0` means success. Other values are nats.c status codes
(`error_text` returns a borrowed static explanation); `Error.jetstream` preserves
the server API code when available. Local argument rejection uses
`NATS_INVALID_ARG` (16). No C error-owned allocations escape.

The adapter pairs options, connection/context, publish message/PubAck, stream
info, consumer info, subscription, fetched list/messages and metadata with their
destructors on success and failure. Tests exercise real API failures as well as
successful calls, outage behavior, durable detach/rebind, timeout, NAK and ack-wait
redelivery, ack/term, multi-subject filters, dedupe, subject rollup, and TLS trust.

**Never call network operations from a SQLite transaction.** The transactional
outbox relay will publish after commit; this low-level package does not import
the repository or enforce its transaction guard.

## Schedules and delivery protocol

Scheduled definitions need **nats-server 2.14 or newer** for cron, @every and
@at. Enable Stream_Config.allow_msg_schedules and allow_msg_ttl on the same
stream that contains the definition and its target subject. These flags cannot
be disabled after enabling them. An in-place stream_update preserves data and
durable consumers. server_supports_schedules reads _nats.ver from stream
configuration metadata and fails closed on errors or unreadable versions;
version_at_least is the pure version predicate.

stream_purge_subject rejects wildcards and returns the server's exact purged
count, including zero for an empty subject. It uses the raw JetStream purge API:
nats.c 3.13's js_PurgeStream discards that count. stream_delete_message deletes
a stream sequence and returns deleted = false without error if it is absent.
subject_token validates one tenant/identifier subject token.

Metadata.timestamp_ns is the server stream timestamp in Unix nanoseconds.
ack_reply_async, nak_reply_delay, in_progress_reply, and term_reply accept
a persisted reply subject and perform plain protocol publishes without waiting
for a response. NAK delays are supplied in milliseconds and encoded in
nanoseconds (nonpositive means immediate). flush is an explicit server barrier;
these asynchronous calls do not flush implicitly. The existing ack_reply
continues to wait for confirmation. A delayed NAK retains its MaxAckPending
slot; +WPI resets AckWait. Acknowledged or terminated work-queue messages leave
the stream, while exhausted messages remain until deletion or expiry.

Real-server scenarios cover schedule headers and time zones, past @at, TTL,
purge counts, upgrades, delivery policy and timestamps, disjoint work-queue
consumers, ack limits, delayed NAK, progress, termination, async acknowledgement,
exhaustion advisories and repeated deletion. With the flake's nats-server
2.14.7, Nats-Schedule-TTL: 2s expires the fire while Nats-TTL: never preserves
the definition; the matcher does not need the fire-delete fallback.


long_pull_bind/long_pull_next keep one 30-second server request alive across
short local receive timeouts. A heartbeat or local timeout returns status 26
without issuing another pull; a completed/expired request allows the next call
to request up to its current limit. Only one thread may use the handle, and it
must be destroyed before its connection while no receive is running. Messages
are individually owned (message_destroy). Use reply-based acknowledgement and
termination functions: these core subscription messages do not carry the nats.c
JetStream subscription metadata required by ack(msg)/term(msg).
