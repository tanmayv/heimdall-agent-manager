# Exact-child PTY notification transport

This local IPC primitive does not grant task authority. Production mounting must
validate current signed immutable-owner authorization and the executor reservation
before any mutating request. The Bridge-to-Bridge request and result must remain
encrypted with the exact owner/executor/runtime identities in authenticated scope.
The current transport addition alone is not that production mounting.

## Binary request and reply

The existing length-prefixed daemon control stream reserves request tag `0x3C`
and reply tag `0xB3`, disjoint from executor renewal and local admission controls.
Request fields, in order: mode byte, ticket, instance, signed big-endian i32 PID,
launch key, launch epoch, positive decimal run count, operation ID, delivery ID,
interrupt byte, and remaining UTF-8 message bytes. Strings have big-endian u32
byte lengths; identities contain 1–256 printable ASCII bytes. The prepare ticket
is empty; dispatch/query require the saved opaque ticket. Interrupt is exactly
0 or 1. Message size is 1–16384 bytes; Unicode scalar text is accepted, with LF
and TAB the only permitted control characters. Invalid input writes nothing.

Modes are prepare=0, dispatch=1, query=2. Prepare allocates a random receipt ticket
without PTY I/O. The caller must durably retain immutable intent and ticket before
dispatch. Repeating the same delivery with different input conflicts. Query never
writes. A missing daemon journal requires recovery; it never permits reconstructing
a lost delivery by retyping. Completed IDs are retained for the child lifetime;
receipt capacity exhaustion fails closed instead of evicting replay protection.

The reply binds instance and delivery ID, then ticket, progress flags, message
byte offset, status, profile ID and retry delay. Status values are partial=0,
delivered=1, recovery_required=2 and child_mismatch=3. Kernel write offsets permit
resuming only an unwritten suffix. Delivered means PTY bytes accepted, not agent
acknowledgement, task completion, lease extension, or slot release.

## Physical write fences

The registry lock protects exact instance/PID/startup-key/epoch/run-count matching
through a write. Ambiguous duplicate runtime environment values fail closed.
Mutating prepare/dispatch also serialize against the inherited child deadline
and enforce absolute retirement before I/O, including the watcher polling gap.
Read-only query can recover receipts without renewing an expired child.

Literal messages use DEC2004 bracketed paste followed by Enter. The actual VT
must advertise bracketed paste; disabling/re-enabling it during a partial frame
requires recovery. Raw pane and startup writers cannot interleave with an active
partial notification. Interrupted and nonblocking writes have finite budgets.
A partial delimiter beyond its verified timeout requires recovery.

Interrupt delivery has no default provider profile. A trusted host configurator
must bind independently validated exact-child settings before prepare; notification
payloads cannot select a profile. The retained Readline profile is test evidence
for that runtime only, not evidence for Codex, Claude, or other provider CLIs.
Windows notification delivery fails closed as unsupported before any write.
Neither Linux tests nor Darwin compilation establish native provider support.

## Provenance and remaining gates

Selected runtime hunks originate from `b193d3d0` and `12b7f198`, as listed in
approved plan `1c83a464` section 6. Integrate additive hunks while preserving
current executor exact-key admission, signed renewal and absolute hard bounds.
Do not import old Hub notification permission or a second task authority.

Required before production completion: durable owner/executor intent/ticket and
encrypted exact results; current-fence checks before dispatch; lost-reply and
partial-write recovery through production routes; real provider/profile interrupt
and Unicode/paste on Linux and macOS; explicit native Windows availability and
unsupported gates. No live deployment or restart is authorized by this document.
