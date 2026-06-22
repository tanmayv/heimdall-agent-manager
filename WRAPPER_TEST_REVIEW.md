# Review: `ham-wrapper test` implementation

Scope: staged changes — `src/wrapper/test_command.odin` (+627), `src/wrapper/main.odin` dispatch shim, `src/lib/tmux/tmux.odin` helpers, `src/lib/config/config.odin` (`resolve_model_value` move).

Verdict: solid pass on shape and step ordering. A few blockers around false-positive failure detection and a probe duplication that will drift; rest are polish.

---

## Blockers (fix before commit)

### B1. `scan_failure_patterns` will false-fail on conversational agent output

`test_command.odin:599`
```odin
patterns := []string{"cannot create", "permission denied", "error:", "i do not", "i don't", "i cannot"}
```

The agent prompt is conversational; claude/codex routinely emit lines like
- "I don't need to do anything else."
- "There were no errors:" (note trailing colon)
- "I cannot find any reason this would fail." — said as part of success narration.

Step 7 runs this scan once per second on the **entire pane scrollback**, and any single match aborts the run with `"agent error detected: …"`. A passing test will look like a failure.

Fix: drop the "i do not / i don't / i cannot" patterns entirely (they are the agent talking, not an error). For the shell-style ones, require a stronger signal — e.g. line begins with `bash:` / `error:` at column 0 / contains a real error glyph from claude's UI (`✗`, `Error:` with capital E and trailing text). Or — simplest — delete `scan_failure_patterns` and let step 7 time out naturally; the file+marker check is the source of truth.

### B2. `test_startup_probe` is a copy of `startup_probe_agent`

`test_command.odin:441-480`
```odin
// test_startup_probe is a copy of startup_probe_agent that also watches for pane exit and respects g_test_abort
test_startup_probe :: proc(...)
```

A self-acknowledged copy-paste. Production probe fixes won't reach the test path and vice versa. The only real differences are (a) the `g_test_abort` check inside the loop and (b) the explicit `pane_exited` branch.

Fix: extend the production `startup_probe_agent` to take an optional `abort_flag: ^bool` (nil-safe) and to surface `pane_exited` as a distinct reason_code. Delete the copy. If you don't want to touch the production probe in this PR, leave a TODO at the top of `test_startup_probe` referencing the production proc by file:line so the next person sees both at once.

### B3. Allocator leak in `scan_failure_patterns`

`test_command.odin:602`
```odin
lower, alloc_err := strings.to_lower(line)
if alloc_err != nil { continue }
```

`strings.to_lower` allocates from `context.allocator`. Never freed. Called ~60 times per run × N lines per call. Wrap with `context.temp_allocator` and `free_all(context.temp_allocator)` at the top of the scan, or `defer delete(lower)` inside the loop.

(Becomes moot if you take B1's simplification and delete this proc.)

---

## Smaller issues

### S1. `marker` echo-count assumption is fragile

`test_command.odin:417`
```odin
// Need >=2 occurrences: one from echo in step 6, one from agent response
marker_ok := strings.count(text, marker) >= 2
```

Step 6 returns the moment marker appears *once*. If the agent answers in <250ms (step-6 poll interval), step 6 may already see the agent's reply included with the echo, and step 7's `>=2` becomes flaky on fast providers. Inverse risk too: capture is 500 lines, both occurrences could scroll off on a chatty agent.

Fix: in step 6, after `marker` is seen, record the byte-offset (or strip everything up to and including the echo line) into `state`. Step 7 then only needs to find marker **once** in the post-echo tail. Cleaner contract: "agent emitted the marker," not "marker appears twice."

### S2. Step 7's tail-watcher tail-key is brittle

`test_command.odin:402-409`
```odin
if len(prev_text) > 10 {
    tail_key := prev_text[len(prev_text)-min(50, len(prev_text)):]
    idx := strings.last_index(text, tail_key)
    if idx >= 0 { new_text = text[idx:] } else { new_text = text }
}
```

When the pane has scrolled past `prev_text`'s tail (scrollback eviction beyond the 500-line cap, or just rapid output), `last_index` returns -1 and the whole pane is re-scanned for failures. Same error line gets re-reported each iteration; a transient warning early in the run keeps killing later iterations.

Fix: track a monotonically-growing "lines already scanned" counter, or store `last_scan_offset` and trim with substring math (capture returns left-to-right). Or — again — delete failure scanning per B1.

### S3. Local `min` shadows the builtin

`test_command.odin:624`
```odin
min :: proc(a, b: int) -> int {
    if a < b { return a }
    return b
}
```

Odin has a built-in `min`/`max`. If you defined this to dodge a compiler complaint, it was probably the wrong type — fix the call site (`min(50, len(prev_text))` should already work with the builtin since both are `int`). Drop the proc.

### S4. `option_value`/`has_flag`/`template_string` are wrapper-private — confirm visibility

`test_command.odin` is in `package main` and uses `option_value`, `has_flag`, `template_string` defined in `main.odin`. Since both files are the same package this compiles fine — but please verify `nix build .#ham-wrapper` from a clean tree to make sure no `private` modifier was added in main.odin. (If it builds for you, ignore.)

### S5. `generate_run_id` RNG seeding

`test_command.odin:502`
```odin
rng := rand.uint32()
```

Odin's `core:math/rand` global is seeded per-thread with a fixed default unless you call `rand.reset(...)`. Two `ham-wrapper test` invocations starting within the same wallclock-second-with-same-`cc`-centiseconds will collide on `run_id`. Add `rand.reset(u64(time.to_unix_nanoseconds(time.now())))` at the top of `run_test_command`. Cheap insurance.

### S6. `available` list when no agent commands configured

`test_command.odin:204`
```odin
available := strings.join(names[:], ", ")
failure = fmt.tprintf("provider '%s' not found; available: %s", provider, available)
```

If `cfg.agent_commands` is empty, user sees `available: ` (trailing colon, blank). Guard: `if len(names) == 0 { available = "(none configured)" }`.

### S7. `posix.signal` handler atomicity

`test_command.odin:19`
```odin
_test_sig_handler :: proc "c" (sig: posix.Signal) {
    g_test_abort = true
}
```

Single-byte write is practically safe on x86 but technically a data race. Use `intrinsics.atomic_store(&g_test_abort, true)` and `intrinsics.atomic_load(&g_test_abort)` at the read sites if you want to be lint-clean.

### S8. `config.toml.testpatch` is untracked

That file at repo root looks like a dev artifact from this work. Either delete it, `.gitignore` it, or fold its contents into `config.toml`. Don't let it ride along into the commit.

---

## Nits

- N1. `step1_config` returns 6 values; consider a `Step1_Result` struct for readability — call sites already destructure into long lines.
- N2. `print_step_line`'s `spaces` literal is fixed-width; an `agent_cmd` label longer than 46 chars would panic on slice. Current labels are short; document the assumption or compute pad dynamically.
- N3. `test_abort_cleanup`'s "interrupted" message goes to stderr; the PASS/FAIL summary to stdout. Consistent stream choice helps when piping to a logfile.
- N4. The `_ = tmux.kill_session(probe_name)` in step 2 swallows failure silently — fine for a probe, but worth a verbose-mode hint if it returns false.

---

## Compile + run check

If `nix build .#ham-wrapper` is clean and the end-to-end runs you reported all behave the way you described (PASS in ~12s; codex failure caught at step 3 with snapshot; --dry-run exits at step 2; --provider doesnotexist exits 1 at step 1), then the blockers above are mostly correctness-under-edge-cases, not "it's broken." Take B1 + B3 seriously; B2 can be deferred with a TODO if scope is tight; the rest are polish.

## Suggested commit shape

One commit for `test_command.odin` + the new tmux helpers + the main dispatch. **Separate** commit for the `resolve_model_value` move (`main.odin` + `config.odin`) — it's a refactor unrelated to the test command and would make `git blame` cleaner. The bundled-commit feedback from the last round (commit `ac7da58`) was about exactly this kind of mixing.
