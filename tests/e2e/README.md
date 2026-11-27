# Task 18 canonical E2E runner

`run_task18_canonical.py` is the single top-level runner for the canonical Teams v1 E2E surface required by `task-19f4b590d38`.

## Contract

- Uses an isolated daemon/data directory only.
- Default isolated daemon port is `49422`.
- Writes per-scenario transcripts under `tests/e2e/transcripts/<timestamp>/` unless `--artifacts-dir` is provided.
- Drives user-visible actions through a browser automation harness against `data-debug-id` selectors. The Electron app no longer ships a debug-control server (REQ-ELECTRON-NO-REMOTE-DEBUG-1).

### Validating memory edit/archive (supersede model)

Memory edit is a **supersede**, not an in-place mutation. Submitting an edit
proposal for `mem_A` and approving it creates a NEW active record `mem_B`
(`result.memory_id` from the propose response) and archives the original
`mem_A`. Archive marks the target record `status=archived` on approval. Both
edit and archive land as pending proposals that require approval before the
durable change applies.

To validate edit durably through the UI (Memory Management surface):

1. Select the record, choose `edit`, change the body, and `memory-form-submit-btn`.
   The success message now names the resulting record id (`supersedes into mem_B`).
2. Approve the pending proposal via `memory-pending-approve-<memoryId>`.
3. Verify durability: the resulting record (auto-selected) is `status=active` with
   the new body and an incremented `version`; the original is `status=archived`.
   Backend check: `POST /user-rpc {action: memory_show, memory_id: mem_B}` (or
   `memory_list include_all_statuses=true`).

Archive: choose `archive`, submit, approve via `memory-pending-approve-<memoryId>`,
then confirm the record is `status=archived` (version incremented).
- Uses CLI/HTTP helpers only for isolated setup/teardown, passive assertions, model/preflight checks, and transcript collection.
- Does **not** substitute synthetic agents for the required real `pi`/Codex scenario. Missing `pi`, Codex model mapping, display server, or Electron dependencies produce explicit preflight blockers.
- Uses a runner-owned isolated wrapper credentials path. Pass `--wrapper-credentials-path <file>` or set `HEIMDALL_E2E_WRAPPER_CREDENTIALS=<file>` to copy an existing provider credentials file into that isolated path; otherwise the runner creates an isolated empty credentials file and relies on provider config/environment.

## Run modes

Preflight only, suitable for machines that may not have external pi/Codex credentials:

```bash
python3 tests/e2e/run_task18_canonical.py --preflight --allow-external-blockers
```

Strict preflight, fails non-zero when external prerequisites are missing:

```bash
python3 tests/e2e/run_task18_canonical.py --preflight
```

Canonical run on a UI-capable machine with real pi/Codex credentials:

```bash
python3 tests/e2e/run_task18_canonical.py --scenario all
```

Run one scenario:

```bash
python3 tests/e2e/run_task18_canonical.py --scenario solo-user-proxy
```

## Canonical scenarios

1. `coding-two-teams-real-pi` — two coding teams on one git-backed project, real `pi` agents using Codex model mapping, clean merge, nudge/status evidence.
2. `solo-user-proxy` — solo `vcs_kind=none` chain with user-facing creation driven through UI and user_proxy/Needs-attention approval surface.
3. `research-report-memory-restart` — research/report scaffold with `Team_Project` memory surviving daemon restart.
4. `legacy-migration-copy` — legacy migration on a fresh copy of live `data_dir`; never against the live DB.
5. `idle-shutdown-auto-boot` — idle shutdown followed by auto-boot/nudge on first ready task with UI status correctness.
6. `redux-ui-freshness` — Redux-backed UI stays synchronized without manual refresh.
7. `coordinator-contact-invariants` — validates coordinator-only user contact invariants `BS-6`, `UI-5`, and `API-4`; structured `Needs attention` prompts remain allowed.

## Transcript outputs

Each run writes:

- `preflight.json` — local prerequisites and explicit blockers.
- `runner-transcript.json` — summary across selected scenarios.
- `<scenario-id>/transcript.json` — per-scenario steps, assertions, blockers, and artifact paths.
- optional `<scenario-id>/*.png` — UI evidence captured by the browser harness.

## External prerequisites for full canonical pass

- `npm ci` completed, so `node_modules/.bin/electron` exists.
- A display server is available (`DISPLAY` or `WAYLAND_DISPLAY`).
- `pi` is on `PATH`.
- Optional: `--wrapper-credentials-path <file>` or `HEIMDALL_E2E_WRAPPER_CREDENTIALS=<file>` points at provider credentials to copy into the isolated runner config. The canonical runner must not require or mutate `~/.local/share/heimdall/wrapper-credentials.json`.
- `config-test.toml` maps:
  - `cheap = openai-codex/gpt-5.3-codex-spark`
  - `normal = openai-codex/gpt-5.4`
  - `smart = openai-codex/gpt-5.5`
- Port `49422` is free.

## Live tab stream

`tabstream_live.mjs` starts an isolated Hub, NATS, Bridge and synthetic agent,
then drives real `ham-ctl` commands against an animated headless Chromium tab.
It verifies the owner route and ticketed WebSocket, non-owner denial, the
viewer page, measured transfer rates, CLI latency, last-viewer detach,
explicit stop, and tab close. It also drives Control for click, typing, drag
and scroll while an independent agent CDP connection acts on the same tab,
then switches to a second live stream. The audit checks SQLite, NATS traffic
and local logs for sampled stream data and a synthetic input marker verified
in the source tab. Viewer onboarding is stubbed. The stream
requests still use a real owner session from the fixture's mock OIDC provider.

From the repository root, with renderer dependencies already present:

```sh
STREAM_BIN_DIR=/path/to/ham-binaries \
STREAM_PTY_HOST=/path/to/ham-pty-host \
HEIMDALL_TEST_CHROMIUM=/path/to/chromium \
PUPPETEER_MODULE=/path/to/puppeteer-core.js \
node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/tabstream_live.mjs
```

The binary directory needs `ham-hub`, `ham-bridge`, `ham-ctl` and
`ham-dev-proxy` from this checkout. Use `HEIMDALL_E2E_NATS_BIN` if
`nats-server` is not on PATH. The binaries must run under the host user's
normal filesystem identity so the real browser profile ownership checks work.
If needed, set `STREAM_VIEWER_CHROMIUM` separately from the capture browser.

To exercise expiry without waiting for the default two hours, prepare a
second, isolated binary directory with the same binaries except for a Bridge
built against a temporary copy of the contracts with
`STREAM_EXPIRY_MS :: 15 * 1000`. Keep the Hub, CLI, and viewer unmodified.
Run the same command with that directory and `STREAM_E2E_EXPIRY=1`.
The short-TTL run checks live viewing before the deadline, actual expiry in
the viewer, rejection of fresh lookups and viewer upgrades, and that capture
stops. Do not deploy or use the short-TTL build outside the fixture.
