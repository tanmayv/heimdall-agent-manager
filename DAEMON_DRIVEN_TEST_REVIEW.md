# Review: daemon-driven `test-launch` implementation

Scope: staged + unstaged daemon, ctl, wrapper, and UI changes implementing
`POST /agents/test-launch`, `agt_test_*` token filtering, `ham-ctl
start-success`, the `test_start` / `test_done` WS events, and the
**Test Providers** tab.

Verdict: shape is right; HTTP routes, WS events, and UI wiring all hang
together. A handful of correctness bugs to fix before this is reliable
under realistic conditions, plus a few hygiene items.

---

## Blockers (fix before commit)

### B1. Startup sweep targets the wrong session prefix

`src/daemon/test_run.odin:382-398`
```odin
for line in lines {
    name := strings.trim_space(line)
    if !strings.has_prefix(name, "ham-test-") do continue
    kill_cmd := []string{"tmux", "kill-session", "-t", name}
    ...
}
```

`ham-test-*` is the prefix used by the **standalone wrapper** `test`
subcommand. Daemon-launched test agents go through `launch_wrapper_for_test`
→ the normal wrapper path → `tmux.ensure_agent_window`, which produces a
session named after the agent (e.g. `heimdall-test-claude-…` or whatever
`ensure_agent_window` decides) — **not** `ham-test-*`. So this sweep won't
catch a single orphan from a crashed daemon.

Fix options:
- Tag daemon-launched test agents with a `ham-daemon-test-*` (or similar) session prefix by forcing the session name in `launch_wrapper_for_test` (pass a `--session` flag if wrapper accepts one, else launch under `tmux new-session -d -s <name>` and let the wrapper attach into it).
- Or sweep by **agent_instance_id prefix `test-`** — list panes with `tmux list-panes -aF '#S #W'` and kill windows whose name starts with `test-`. More invasive but correct.

### B2. `launch_wrapper_for_test` leaks a Process handle

`src/daemon/test_run.odin:436-441`
```odin
process, err := os.process_start(...)
if err != nil { ... return false }
_ = process
return true
```

`os.process_start` returns a `Process` that owns OS resources (on Linux, a
pidfd / wait handle). Never closing it leaks an fd per test run. Over 32
runs that's 32 fds; over a daemon's lifetime it's unbounded.

Fix: `defer os.process_close(process)` immediately after the error check,
or call `os.process_close(process)` before returning. The `nohup … &` in
the shell command already detaches the actual wrapper, so closing the
parent-shell handle is harmless.

### B3. Ring-buffer overwrite leaks the previous slot's resources

`src/daemon/test_run.odin:71-77`
```odin
test_run_alloc :: proc(run: Test_Run) -> ^Test_Run {
    idx := test_run_head % MAX_TEST_RUNS
    test_runs[idx] = run
    test_run_head += 1
    ...
}
```

When `test_run_head` wraps past 32, the new run silently overwrites the
slot. If that slot still holds a non-terminal run (rare but possible: 32
concurrent timeouts) or a terminal run whose `run_dir` hasn't been swept
yet by the TTL janitor, we lose all references — the tmux pane and the
`/tmp/ham-daemon-test/<id>` dir stick around with nothing to clean them.

Fix: before overwriting, if the previous occupant has a non-empty
`test_run_id`, call `test_run_cleanup(idx)` and free its cloned strings.
String leak is small; the pane/dir leak is the real problem.

### B4. `pane_tail` may produce invalid JSON

`src/daemon/json.odin:154-171` only escapes `\\`, `\"`, `\n`, `\r`, `\t`.
`capture_test_pane_tail` returns raw tmux pane output, which contains ANSI
escape sequences starting with `0x1b` (ESC), plus other control chars
(`0x00-0x1f`). RFC 8259 requires all `0x00-0x1f` to be escaped as `\uXXXX`.

Browser `JSON.parse` accepts most of these in practice, but strict parsers
(some Go/Rust clients) will reject the `test_done` frame and the UI will
miss the result. Two paths:
- Strip control chars in `capture_test_pane_tail` (cheap, lossy on color), or
- Extend `json_write_string` to emit `\u00XX` for the `< 0x20` range.

Either is fine; the second is the durable fix and benefits other call
sites already passing through this proc.

### B5. Process handle from `os.process_exec` in `capture_test_pane_tail` / `test_run_cleanup`

`test_run.odin:107-108, 122-125, 387-397, 396-397`
```odin
_, _, _, _ = os.process_exec(...)
```

`os.process_exec` may also need explicit cleanup of its returned `stdout`
/ `stderr` byte slices (they're allocated from `context.allocator`). The
discard with `_, _, _, _` means we never `delete()` them. Over many test
runs + janitor ticks this is real memory growth.

Fix: capture `stdout` and `stderr`, `defer delete(stdout)` / `delete(stderr)`
on the branches that use them. For the cleanup-only call sites that ignore
output, pipe to a small wrapper that delete()s.

---

## Smaller issues

### S1. `test_run_find_by_token` and `_by_id` scan all 32 slots including stale empty ones

Not a perf issue at N=32 but the comparison
`test_runs[i].test_run_id != ""` is doubled (the empty-string string
compare is cheap but still). Cleaner: early-exit when `test_run_id == ""`.
Optional.

### S2. `agent_instance_id` collision under burst load

`test_run.odin:220-222`
```odin
short_id := test_run_id[len(test_run_id)-4:]
agent_instance_id := fmt.tprintf("test-%s-%s", provider, short_id)
```

`short_id` is 4 hex chars (16 bits). Two `test-launch` calls in the same
wallclock second with the same provider have ~1/65536 collision odds. If
they collide, `registry_add_pending_agent_token` is called with a
duplicate `agent_instance_id` and the registry will resolve to whichever
record was last upserted. Cheap fix: use 8 hex chars or include the full
`test_run_id` suffix (10 chars after the timestamp).

### S3. `rand.reset` called on every launch

`test_run.odin:218`
```odin
rand.reset(u64(time.to_unix_nanoseconds(time.now())))
test_run_id := generate_test_run_id()
```

Reseeding the global RNG on every request defeats sequence quality and
could even produce identical IDs if two requests arrive in the same
nanosecond (unlikely but the determinism is bad form). Seed once at
`run_server` startup. The wrapper has the same issue per S5 of the
previous review; pick one canonical place.

### S4. `test_run_on_lifecycle` never transitions from `starting` → anything

`test_run.odin:346-355` advances `launching → starting` but never sets
`connected` or any further state. That's OK as long as the contract is
"final state is success / failed / timed_out" — but the UI may want to
show `connected` (i.e. ready-pattern matched) so the user sees progress
between launch and the start-success RPC. Currently the UI sees `starting`
for the full window, which can be 30-60s on slow providers.

Optional: also map `connection_state == "connected"` → `status = "ready"`
or similar, and emit an interim `test_progress` event. Or live with the
two-state UX.

### S5. `test_run_cleanup` doesn't free string allocations

`test_run.odin:101-114` kills the pane and rmdirs, but the cloned strings
in the slot (`test_run_id`, `provider`, etc.) are still allocated until
the slot is overwritten (B3). The TTL janitor only sets
`run.test_run_id = ""` — it doesn't `delete()` the previous backing memory.

Fix: in the TTL reap branch (`test_run.odin:365-367`) and at slot reuse,
`delete(run.test_run_id); delete(run.provider); ...` for each cloned
field. Or accept the bounded leak (32 slots × ~10 short strings = ~3KB
high-water mark) and document it.

### S6. `pending_agent_token` not cleared on test failure

`test_run.odin:248` calls `registry_add_pending_agent_token` but on the
`launch_wrapper_for_test` failure branch at lines 253-263 we never remove
it. The token stays in the pending list indefinitely. Add a corresponding
`registry_remove_pending_agent_token` call (if one exists) or `_clear` in
the failure path and inside `test_run_cleanup`.

### S7. `test_run_startup_sweep` `read_directory_by_path` error path

`test_run.odin:401-402`
```odin
infos, read_err := os.read_directory_by_path("/tmp/ham-daemon-test", -1, context.allocator)
if read_err != nil do return
```

When the dir doesn't exist (fresh install, first daemon start), `read_err`
fires and we return without an issue — fine. But the function returns
without ever attempting tmux sweep cleanup in that branch — actually no,
tmux sweep is *above* the dir read. OK, ignore. Worth a comment to make
that explicit.

Also: `infos` allocation is leaked. Should `defer delete(infos)`.

### S8. `handle_start_success` doesn't validate that the token's run is actually `starting`

`test_run.odin:311-344` accepts start-success against a slot in `launching`
state too. That means an extremely fast agent could call start-success
before the lifecycle transition happened. Probably benign (we still
record success), but worth deciding: do we want start-success to be
gated on "agent has registered first"? If not, document the relaxed
contract. If yes, return 425 Too Early.

### S9. `TEST_AGENT_STARTER_PROMPT` template parsing

`src/wrapper/main.odin` line ~14
```odin
TEST_AGENT_STARTER_PROMPT :: "You are a Heimdall test agent. ... Run exactly this shell command:\n{ctl_bin} --daemon-url {daemon_url} --token {token} start-success\n..."
```

Verify `template_string` actually substitutes `{ctl_bin}` — the existing
substitutions used in `build_agent_command` are `{daemon_url}`,
`{agent_instance_id}`, `{display_name}`, `{conversation_id}`, `{token}`.
`{ctl_bin}` is new. Either add it to `template_string`, or hardcode the
ctl path resolution into the prompt at build time.

(If you grep `template_string` and `{ctl_bin}` isn't there, the test
agent will literally see the placeholder and try to exec `{ctl_bin}` as a
binary. This will fail loudly — but with a confusing error.)

### S10. WS event JSON written to builder but builder isn't freed

`emit_test_start` / `emit_test_done` at `test_run.odin:128-160` use
`strings.builder_make()` without `defer strings.builder_destroy(&builder)`.
Same pattern as elsewhere in the daemon, but worth tracking — these fire
on every test launch and every completion, so leak grows linearly with
test traffic.

### S11. UI: `setTestRuns` clobbers in-flight state

`src/ui/components/AgentsPage.tsx:91-95` reloads history on tab open,
which dispatches `setTestRuns` and **replaces** the whole array. If a
test was launched in another tab and is still in-flight, its in-memory
status update from `testStartReceived` is lost between the WS event and
the history fetch arriving (the history fetch will include the row but
might not reflect the most recent WS transition). Race window is small
but real on slow daemons.

Fix: merge by `testRunId` instead of replacing, or order: fetch history
first, then attach WS listener. Or just live with it — the user reloading
the tab gets eventually-consistent state.

### S12. UI: tier color in test panel doesn't match agent badge

`AgentsPage.tsx` test-tab tier buttons use `bg-sky-500` for `normal`, but
the agent-list `modelTier` badge uses `border border-[var(--fd-hairline)]
text-[#666]` for `normal`. Minor inconsistency.

---

## Nits

- N1. `test_run_json` writes `completed_unix_ms` even when the run isn't
  complete (value will be 0). Consider omitting or making it nullable —
  some JSON parsers in TS land treat `0` as a valid timestamp and render
  "Jan 1 1970". Currently the UI guards with `run.elapsedMs ?` so OK.
- N2. `handle_agents_test_history` iterates `test_run_head - 1` down to
  `test_run_head - MAX_TEST_RUNS` but stops at `i >= 0`. On a freshly
  booted daemon with `test_run_head < MAX_TEST_RUNS`, this is correct;
  after wrap, the lower bound prevents reading negative indices. OK but
  the modulo dance is worth a one-line comment.
- N3. The `test_run` status string set is duplicated in both daemon
  (`"launching" | "starting" | "success" | "failed" | "timed_out"`) and
  UI (`AgentsPage.tsx` and `chatSlice.ts`). Consider a shared constants
  file or at least a comment block tying them together — drift here will
  silently break the UI's color/dot logic.
- N4. `TEST_RUN_ORPHAN_SESSION_AGE_SECONDS = 300` declared but unused
  (the sweep kills *all* `ham-test-*` sessions regardless of age — and
  even that prefix is wrong per B1).
- N5. `tests/` directory now exists untracked at repo root — same hygiene
  point as `config.toml.testpatch` from the wrapper review. Either commit
  it, .gitignore it, or delete it before merging.
- N6. The unrelated tmux change in `src/lib/tmux/tmux.odin:90-95` (300ms
  sleep between send-keys text and Enter) is a real fix but doesn't
  belong in this commit. Split into its own commit with a referenced
  symptom.
- N7. UI: `createAgent` was added to `daemonApi.ts` but I don't see a
  caller. If it's unused, drop it; if it's for the new "Start" button on
  offline agents, that path uses `startAgent` not `createAgent`.

---

## Suggested commit shape

This change is logically three commits:
1. **daemon test-launch + ctl start-success** — `test_run.odin`,
   `server.odin` route additions, `agent_rpc.odin` action, `ctl/main.odin`
   `start-success`, wrapper `is_test_token` guards and
   `TEST_AGENT_STARTER_PROMPT`, lifecycle/janitor `is_test_token` skips,
   `server_agent_cmd_configs` addition.
2. **UI Test Providers tab + WS event wiring** — `chatSlice.ts`
   reducers/actions, `App.tsx` WS dispatch, `AgentsPage.tsx` tab + panel,
   `daemonApi.ts` `testLaunch/testStatus/testHistory`. The unrelated
   `modelTier` + `stopAgent` / `startAgent` agent-list additions are a
   different feature — split if scope review will be tight.
3. **tmux 300ms send-keys delay** — `lib/tmux/tmux.odin` standalone fix.

The `model_tier` + agent start/stop UI additions are bigger than they
look — they touched `chatSlice` merge logic (`daemonReachable` gating)
and added the "Start"/"Stop" buttons. If those weren't asked for as part
of this PR, factor them out.

---

## Verification I did NOT run

I didn't `nix build .#ham-daemon` or end-to-end exercise
`POST /agents/test-launch`. Recommend a run with:
- happy path (claude/normal) — expect WS `test_start` then `test_done status=success`
- bogus provider — expect 400 from `handle_agents_test_launch`
- bogus tier — expect 400
- kill the test agent's tmux pane mid-flight — expect timeout janitor to
  set `timed_out` after 90s and emit `test_done`
- daemon restart with `/tmp/ham-daemon-test/<dir>` from prior run present
  — expect startup sweep to remove it (will fail today per S5/B1).
