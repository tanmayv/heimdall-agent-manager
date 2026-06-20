# Heimdall AI Manager migration

Heimdall AI Manager is the product name for the former Odin Test prototype. Runtime entrypoints now use `ham-*` names:

| New name | Legacy compatibility name |
| --- | --- |
| `ham-daemon` | `bc-odin-daemon` |
| `ham-wrapper` | `bc-agent-wrapper` |
| `ham-ctl` | `bc-odinctl` |
| `ham-test-agent` | `bc-test-agent` |
| `heimdall` | `odin-ui` |

The Nix packages/apps expose the new names as primary outputs. Legacy package aliases and binary symlinks remain for existing scripts during migration. Repo-local development checkouts also provide `./bin/ham-*` paths so starter prompts and examples work without extra PATH setup.

## Operator updates

- Use `./bin/ham-ctl --config ./config.toml ...` in prompts, scripts, and runbooks.
- Use `ham-daemon --config ./config.toml` to start the daemon.
- Use `ham-wrapper --config ./config.toml <agent_instance_id>` for direct wrapper launches.
- Use the Home Manager option namespace `programs.heimdall`; `programs.odin-test` remains as a legacy compatibility namespace.
- Default local state now lives under `~/.local/share/heimdall` and config under `~/.config/heimdall/config.toml`. Keep or copy existing legacy data if you need continuity from an older checkout.
- The local worktree directory was renamed from `/Users/tanmayvijay/odin-test` to `/Users/tanmayvijay/heimdall-ai-manager`. Update shell aliases, editor workspaces, run scripts, and service definitions that still point at the old path.

## Managed agent run directories and bootstrap files

Wrappers can now launch agents from managed per-project/per-agent run directories instead of the source checkout. Set `wrapper.agent_run_dir` to enable the layout `<agent_run_dir>/<safe-project>/<safe-agent-instance>`. Use `wrapper.project` or per-agent-cmd `project` to select loose project metadata and anchors for generated bootstrap context. Per-agent-cmd `run_dir` remains an exact cwd override for special cases.

Managed bootstrap generation is controlled per `[wrapper.agent-cmd.<name>]`:

- `bootstrap_enabled = true` enables generation.
- `bootstrap_profile = "pi" | "claude" | "codex"` selects provider defaults. Pi and Codex default to `AGENTS.md`; Claude defaults to `CLAUDE.md`.
- `bootstrap_files = ["..."]` overrides destination filenames.
- `bootstrap_sections = ["identity", "guidance", "project", "memory"]` optionally restricts generated content sections; omit it to include all sections.

Generated files include only approved active memory/template/project context. Pending, rejected, and archived memory is excluded, and proposal-only reason/evidence metadata is not written into runtime bootstrap files. Heimdall overwrites/removes only files carrying the managed bootstrap header and tracked by `.heimdall-bootstrap-manifest`; unmanaged user files are preserved.

## Startup blocked detection

Per-provider startup detection is configured under `[wrapper.agent-cmd.<name>.startup_detection]`. It is disabled unless `enabled = true` is set. Example Claude-style trust prompt detection:

```toml
[wrapper.agent-cmd.claude.startup_detection]
enabled = true
startup_probe_seconds = 20
capture_interval_ms = 500
ready_patterns = ["> ", "How can I help"]
blocked_patterns = ["Do you trust the files in this folder", "Claude needs your permission"]
probe_prompt = ""
probe_expect_echo = false
startup_unknown_is_blocked = false
sanitized_reason_mapping = ["trust=Claude directory trust prompt", "permission=Claude permission prompt"]
```

The wrapper uses bounded, in-memory tmux pane capture only during startup probing. The daemon and UI receive safe metadata (`startup_status`, `reason_code`, `safe_diagnostic`, provider, run directory, and tmux target metadata) and never raw pane transcripts. Operators should resolve `startup_blocked` states in the agent terminal, for example by approving provider trust prompts, then restart/retry the agent.

## Rollback / legacy compatibility

If an older automation still calls `bc-*` or `odin-ui`, it should continue to work through compatibility aliases. To roll back a copied prompt or script, replace `ham-ctl` with `bc-odinctl`, `ham-daemon` with `bc-odin-daemon`, `ham-wrapper` with `bc-agent-wrapper`, and `ham-test-agent` with `bc-test-agent` while staying on a build that still ships the shims.
