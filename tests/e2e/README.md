# Task 18 canonical E2E runner

`run_task18_canonical.py` is the single top-level runner for the canonical Teams v1 E2E surface required by `task-19f4b590d38`.

## Contract

- Uses an isolated daemon/data directory only.
- Default isolated daemon port is `49422`.
- Writes per-scenario transcripts under `tests/e2e/transcripts/<timestamp>/` unless `--artifacts-dir` is provided.
- Drives user-visible actions through the Electron debug UI endpoints (`/click`, `/type`, `/select`, `/state`, `/elements`, `/screenshot`, `/upload-file`).

### Driving artifact upload without a native file chooser

The debug harness cannot open the OS file chooser or deliver a clipboard paste, so
UI artifact create/upload is exercised via `POST /upload-file`, which injects a
synthetic `File` into a real artifact upload `<input type="file">` and dispatches a
genuine `change` event (running the production upload path end-to-end).

```bash
# Open a conversation thread and its Artifacts side panel first (via /click), then:
curl -s -X POST "http://127.0.0.1:<debug-port>/upload-file" \
  -d '{"debug_id":"conversation-thread-artifacts-upload-input","file_name":"harness.png","mime":"image/png"}'
# Optional: pass base64 bytes with "content_base64"; omitted content defaults to a 1x1 PNG.
# The new artifact then appears in the right-sidebar Artifacts list and via `ham-ctl artifacts list`.
```
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
- optional `<scenario-id>/*.png`, `redux-state.json`, `elements.json` — UI evidence collected from the Electron debug server.

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
