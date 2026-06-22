# `ham-wrapper test` — blackbox refactor (already landed, do not override)

I made the following changes to `src/wrapper/test_command.odin` directly on
your in-progress branch. Built clean (`nix build .#ham-wrapper`) and verified
end-to-end (`claude/normal` PASS in 6.1s). **Please pull these into whatever
fix-up commits you are preparing for the review items I sent earlier; do not
revert.**

## What changed and why

The earlier implementation used `tmux send-keys` to deliver the test prompt
mid-session and `capture-pane` repeatedly in steps 3, 6, and 7 to verify
echo and marker output. That broke the blackbox contract: the test was
inspecting the agent TUI's internals to decide pass/fail, which is exactly
what made `scan_failure_patterns` so prone to false positives.

New contract: **the agent is a blackbox.** The test only knows that the
agent's process is running (`pane_exists`) and that the artifact it was
asked to produce appeared on disk. Pane text is read in exactly one place:
startup detection (step 5), which has to match `ready_patterns` against
the TUI.

## Concrete deltas

### 1. Combined test prompt is now passed as the agent's positional arg

`TEST_STARTER_PROMPT` is the single instruction the agent receives — it is
templated through `build_test_argv` as the final positional arg, exactly
the same way the production `starter_prompt` is for `pi`, `claude`, and
`codex`. No second prompt, no send-keys, no echo handshake.

```odin
TEST_STARTER_PROMPT :: "You are a test agent. Your only task: use your shell tool to run `touch test_file` in the current working directory. After the command succeeds, you may stop. Do not perform any other action, do not read files, do not write other files."
```

This honors the `prompt_flags` mechanism that already exists for each
agent-cmd in `config.toml` (`pi "prompt"`, `claude --dangerously-skip-permissions "prompt"`, etc.).

### 2. Step count reduced 7 → 6

| Old | New |
|---|---|
| 1. config parse | 1. config parse |
| 2. tmux available | 2. tmux available |
| 3. launch (no prompt) — stayed-up via capture | 3. launch — stayed-up via `pane_exists` only |
| 4. restart with starter prompt | 4. restart with combined starter+test prompt |
| 5. startup detection | 5. startup detection (unchanged — capture allowed here) |
| 6. echo handshake + send test prompt **(removed)** | — |
| 7. verify file + marker via capture | 6. verify `test_file` on disk via `os.is_file` poll |

### 3. `tmux.capture_pane_text` usage is now confined to step 5

- Step 3 stayed-up check: `pane_exists` only. No `capture_pane_text`, no last-output diagnostic.
- Step 6: `os.is_file` poll loop. No `capture_pane_text` at all. Pane is checked with `pane_exists` only to detect early agent-process death.
- Step 5 (`startup_probe_agent`): still uses `capture_pane_text` — required for `ready_patterns` matching. This is the one allowed exception.

### 4. Removed dead code

- `step6_echo_and_prompt` proc — gone.
- `step7_verify` proc — gone, replaced by smaller `step6_verify_file`.
- `snap_pane` proc — gone (pane snapshots violated blackbox; the keep-on-failure tmux session is preserved instead for manual `tmux attach` debugging).
- `pane-step-N.log` references in `print_failure_summary` — gone.
- `marker` / `HAM_TEST_MARKER_<run_id>` machinery — gone.
- `echo_consumed_len` field on `Test_State` — gone.

`capture_last_lines` is kept (still used inside step 5's `pane_exited` hard-fail diagnostic, which is within startup detection so allowed).

### 5. Failure output

When `--keep` preserves the session, the user is told to `tmux attach -t
<session>` to inspect manually. We no longer dump our own snapshots.

## Verification

```
$ nix build .#ham-wrapper                    # clean
$ ./result/bin/ham-wrapper test --config ./config.toml --provider claude --tier normal --keep never

ham-wrapper test  run_id=t-2026062019411295-75cf
              cwd=/tmp/ham-wrapper-test-t-2026062019411295-75cf
              tmux=ham-test-75cf:smoke

[1/6] config parse                                 OK    3 agent-cmds; tier=normal → sonnet; prompt=308 chars
[2/6] tmux available + functional                  OK    tmux 3.6a; session create/kill round-trip 11ms
[3/6] launch agent process                         OK    pane=%36 model=sonnet stayed-up 2.0s
[4/6] restart with combined starter+test prompt    OK    pane=%37 prompt=236 chars (passed as positional arg via agent_cmd.prompt_flags + final positional)
[5/6] startup detection                            OK    matched 'ready_0Welcome_back' after 1.0s
[6/6] verify test_file created on disk             OK    /tmp/ham-wrapper-test-t-2026062019411295-75cf/test_file (0 bytes) after 3.0s

PASS  total 6.1s
cleanup OK
```

End-to-end faster than before (6.1s vs ~12s) because there's no idle-detect
wait + second prompt round-trip.

## What you should still do from the review

The blackbox refactor closes review items B1 (false-positive failure
detection — `scan_failure_patterns` was already removed by you, the new
step 6 has no text-based fail detection at all), B3 (allocator leak — same,
the proc is gone), S1 (marker `>=2` fragility — gone), and S2 (tail-key
fragility — gone).

Still open from the review:
- **B2** — `test_startup_probe` is no longer a copy, you already extended
  the production `startup_probe_agent` to take `&g_test_abort`. Confirmed
  by reading `step5_startup` calling `startup_probe_agent(sd, state.pane_id, &g_test_abort)`. Looks done.
- **S3** — `local min` proc was removed (no longer referenced). Good.
- **S5** — RNG seeding for `generate_run_id`. Please add
  `rand.reset(u64(time.to_unix_nanoseconds(time.now())))` at the top of
  `run_test_command`.
- **S7** — atomic load/store on `g_test_abort` — you already did this.
- **S8** — `config.toml.testpatch` untracked artifact, please delete or
  fold into config.toml before commit.
- **Commit split** — `resolve_model_value` move (`config.odin` + `main.odin`)
  should still be a separate commit from `test_command.odin`.

## File list touched in this refactor

- `src/wrapper/test_command.odin` — proc reshuffle + dead code removal.

No other files. `tmux.odin`, `config.odin`, `main.odin` are untouched by
me in this round.
