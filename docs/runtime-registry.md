# Hub runtime registry lifecycle

The Hub keeps connection-scoped runtime state in dynamic maps. Capacity depends on live connections, active instances, and bounded terminal history rather than the number of IDs seen since startup. Durable agent status and history remain in the database.

## Connection ownership

Each accepted Bridge connection owns a writer mutex and an instance map. Its identity consists of the authenticated Bridge ID and a process-wide increasing connection generation. Removing a connection does not reset the generation counter, so reconnecting an old Bridge ID cannot reuse an earlier generation in the same Hub process.

Readers and writers acquire references to the connection. Disconnect or replacement immediately removes lookup visibility, shuts down the socket, drains outstanding writes, releases active-instance accounting, and clears observations for that generation. The writer object is freed after the last reference is released. Every reader exit passes the same socket shutdown and writer-drain barrier before the server closes its descriptor; another thread never closes the reader's socket.

Connections for different Bridges have independent writer and state mutexes. Global locks cover brief map bookkeeping, quota accounting, and command-result cache access, and do not cover network writes. Hub-to-Bridge sockets have a five-second send timeout so a stalled writer cannot prevent cleanup indefinitely.

## Instance lifecycle

An instance is identified by Bridge ID, connection generation, and agent instance ID. An active entry stores its latest sequence, runtime status, activity, and last-seen timestamp. Duplicate or older sequences do not replace current state.

Agent creation, relaunch, and provider-test launch reserve active quota before dispatch. A failed dispatch cancels the reservation; an unconfirmed reservation expires after one minute. A confirming status report replaces the reservation without consuming a second slot. Reservations and terminal entries are cleaned by the existing background reaper, and periodically during state ingestion.

Stopped, failed, and unreachable entries release active quota and become terminal tombstones. By default a connection keeps at most 256 tombstones. They expire after five minutes and are removed on the next sweep. Older tombstones can be evicted earlier when that budget is exhausted. Tombstone removal does not delete durable records. Status ingestion first validates the instance's Bridge ownership and durable sequence, so an expired tombstone does not permit an older report to overwrite final database state.

Heartbeat inventory reconciliation only affects the reporting Bridge generation. Disconnect clears that generation's transient state; replacement starts with a fresh map and accepts the new Bridge's own sequence baseline. An old connection cannot update the new map or repopulate retired command observations.

## Configurable admission limits

The existing tenancy boundary is the durable owner user ID. Per-owner limits cover that user's active instances across their connected Bridges, not each Bridge independently. Limits count connected activity; they are not a license quota or a guarantee that processes on disconnected remote machines have stopped.

| Hub flag | Default | Counts |
| --- | --- | --- |
| `--runtime-max-live-bridges` | 1024 | Live connections across the Hub |
| `--runtime-max-live-bridges-per-owner` | 256 | Live connections for one owner |
| `--runtime-max-active-instances` | 16384 | Active entries and pending launch reservations across the Hub |
| `--runtime-max-active-instances-per-owner` | 2048 | Active entries and reservations across one owner's Bridges |
| `--runtime-terminal-entries-per-bridge` | 256 | Retained terminal entries on one live connection |
| `--runtime-terminal-retention-seconds` | 300 | Maximum terminal retention before the next sweep |

Flags require positive integer values. Omitted settings use these defaults. Admission failure returns `Bridge_Busy` instead of falsely accepting a connection or silently exhausting a fixed array. Stopping instances and retiring connections release capacity for later work. Limits are operational budgets, not measured throughput guarantees.

These changes do not alter Bridge or UI wire protocols and require no database migration. Deploy the updated Hub to activate them. Binary pane transport, slow-viewer isolation, and bounded terminal-output queues remain separate work described in the [binary pane streaming plan](plans/binary-pane-streaming-plan.md).
