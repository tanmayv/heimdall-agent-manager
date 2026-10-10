# Bounded pane transport

Phase 1 retains JSON/Base64 transport and bounds the production Bridge → Hub → UI path. Binary envelopes, epochs/sequences, atomic binary snapshot assembly, proxy canaries, and fleet capacity testing remain in phases 2–5 of the [binary streaming plan](plans/binary-pane-streaming-plan.md).

## Wire contract

Streamed input, output, and screen frames carry one `data_b64` payload and a required boolean `is_encrypted`. An encrypted payload contains Base64 of the existing 12-byte nonce, 16-byte authentication tag, and ciphertext. It has no `vault:v1:` prefix or duplicate `enc_b64`. Input and output preserve arbitrary bytes; encryption failures never fall back to plaintext.

The Hub formats plaintext capture snapshots into VT repaint chunks. It relays encrypted captures unchanged with cursor coordinates; the UI decrypts and then formats the captured grid. Both UI panes serialize plaintext and encrypted delivery so a capture cannot overtake pending decryption. A Bridge catch-up repaint uses output frames with `is_snapshot: true`, retaining its VT bytes.

## Bounds and recovery

| Resource | Bound |
| --- | --- |
| Live viewer writers | 4,096 per Hub; 256 per Bridge |
| Incremental output per viewer | 256 KiB, including the in-flight frame |
| Snapshot delivery per viewer | 2 MiB of encoded frames; source captures limited to 1 MiB |
| Viewer control reserve | 16 KiB / 8 queued frames; 256 queued data frames |
| Aggregate viewer delivery per Bridge | 8 MiB plus 64 KiB control reserve |
| Bridge pane queue | 8 MiB / 1,024 frames; small recovery markers may use reserved bytes |
| Per-stream Bridge queue | 256 KiB incremental; 2 MiB encoded snapshot |
| Bridge pane drain | Four records per control-loop turn; raw output split at 8 KiB before encryption |
| Command completion drain | Four responses per control-loop turn |
| Chunk reassembly | 16 MiB reserved bytes per connection across at most 64 messages; 256-byte IDs |
| Retained Hub command results | 8 MiB per Bridge; 64 MiB total; existing entry quotas also apply |
| PTY daemon reply queue | 1 MiB / 256 records per client, counting the in-flight record |
| PTY raw-output channel | 64 × at most 8 KiB chunks (512 KiB) |
| Streamed input | 64 KiB encoded frame; UI pastes split into at most 8,192 UTF-16 code units without splitting surrogate pairs |
| UI delivery queue | 4 MiB of estimated string storage / 256 waiting frames |
| Total frame write deadline | Five seconds for TCP and TLS subprocess pipes; Bridge chunk groups share one deadline |

Queue overflow shuts down a slow viewer or detaches an overflowing Bridge stream. A `pane_resync_required` control record closes only that stream's viewers; their reconnect obtains a fresh capture. If the Bridge cannot reserve a recovery record, it reconnects the Hub connection. Lost incremental bytes are never replayed into an apparently continuous terminal stream. Screen recovery restores the current visible screen; it does not reconstruct missed scrollback.

Unexpected PTY stream EOF requests recovery rather than reporting a process exit. Explicit process lifecycle frames retain their meaning. PTY reply overflow shuts down only that client, leaving the PTY and other clients running.

Writers own queued buffers. HTTP readers own socket close and join their viewer writer before returning. Other threads use shutdown to wake the reader. Sequencing-lock leases keep snapshot chunks contiguous in each viewer queue and are reclaimed after the last detach. TCP and TLS writers share deadline handling; pong frames use the same writer as pane data.

These bounds cover application buffers. Kernel socket buffers, thread stacks, active PTY models, and durable repository allocations add to process/resource usage. Viewer writers remain one thread per admitted connection; this phase does not establish a production fleet capacity claim or implement replica routing.

## Verification and deployment

`npm run test:pane-transport` builds an isolated production Hub queue/capture fixture and verifies real wire frames through UI AES-GCM decoding and xterm. It covers chunked plaintext capture, encrypted output/capture, Unicode, ordering, and overload recovery. Set `ODIN_BIN` and `ODIN_EXTRA_LINKER_FLAGS` when the local toolchain requires them. Native tests cover slow-viewer isolation, ten Bridges under repeated output, writer churn, scoped recovery, command-result byte budgets, and TCP/TLS framing. Rust tests cover reply budgets, socket wakeup, and existing PTY behavior.

Deploy matching **Hub, Bridge/ham-pty-host, and UI** builds together. Old pane payloads are intentionally unsupported. No database migration or ham-ctl update is required for these transport changes. Enable the existing terminal streaming experiment to exercise the streaming path; ordinary HTTP polling remains available.
