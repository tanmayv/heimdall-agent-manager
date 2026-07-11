# Model Tier Selection Plan

## Goal

Each agent has a persistent **model tier** — `cheap`, `normal`, or `smart` — that picks which underlying LLM the provider CLI runs with. Heimdall abstracts the per-provider flag name and model string, so the user just picks a tier when **creating or editing** an agent.

Default for every agent: `normal`.

Concrete mappings (configurable):
- claude: cheap=haiku, normal=sonnet, smart=opus
- codex: cheap=gpt-5-mini, normal=gpt-5, smart=gpt-5-pro
- pi: per pi's CLI conventions

---

## Where tier lives

The tier is a **property of the agent record** stored in the daemon's agent store. It is not a launch-time decision.

- Set when the agent is created (required field; defaults to `normal` in the form).
- Editable on the edit-agent form.
- Read by the daemon when starting the agent; passed as `--tier <value>` to the spawned wrapper.

Starting and restarting an agent never asks the user about tier — the choice was made at create/edit time and persists on the record.

---

## User-facing surface

### Agent create form (Electron UI, AgentsPage)
Adds a single tier selector:
```
Model tier:  ( ) Cheap   (•) Normal   ( ) Smart
```
Default selection: Normal.

### Agent edit form
Same selector, pre-filled with the agent's current tier. Saving the form updates the daemon record. **No restart required for the value to be stored** — but the new tier only takes effect on the agent's next start.

### ham-ctl
```
ham-ctl agents create --name <id> --agent claude --tier smart
ham-ctl agents update --id <id> --tier cheap
```
Both flags optional; omit for default behavior.

### ham-wrapper
The wrapper accepts `--tier <cheap|normal|smart>`. This is how the daemon hands the stored tier to the wrapper process on spawn — not a user-facing flag.

---

## Config shape (provider mapping)

Per-agent-cmd block stays the same — this is the "vocabulary" each provider speaks:

```toml
[wrapper.agent-cmd.claude.models]
flag = "--model"
cheap = "haiku"
normal = "sonnet"
smart = "opus"

[wrapper.agent-cmd.codex.models]
flag = "-m"
cheap = "gpt-5-mini"
normal = "gpt-5"
smart = "gpt-5-pro"

[wrapper.agent-cmd.pi.models]
flag = "--model"
cheap = "haiku"
normal = "sonnet"
smart = "opus"
```

**No `default` field on this block** — the only default is `normal`, baked in. A provider must define all three tiers; if a tier is empty in config, that's a config error (logged at wrapper start; provider's built-in default is used and the agent still launches).

A provider without a `[…models]` block cannot use tiers — the UI selector is disabled for that provider.

---

## Odin structs

`src/lib/config/config.odin`:
```odin
Model_Tiers_Config :: struct {
    flag:   string,
    cheap:  string,
    normal: string,
    smart:  string,
}
```
`Agent_Command_Config` gains `models: Model_Tiers_Config`.

`src/daemon/agent_store.odin` (agent record):
```odin
Agent :: struct {
    // ...existing fields...
    model_tier: string,   // "cheap" | "normal" | "smart"
}
```

The daemon validates `model_tier ∈ {cheap, normal, smart}` on every create/update — invalid values are rejected with an error, not silently normalized. Records created without a tier (none exist yet — fresh schema) would store `"normal"`.

---

## TOML parser

New section header: `[wrapper.agent-cmd.<name>.models]`
`Section` enum gains `Wrapper_Agent_Models`; new `parse_models_key` proc.
Match logic mirrors the existing `startup_detection` suffix dispatch.

---

## Daemon changes

### Agent store
- Add `model_tier` column / field to the persisted agent record. Default for missing values: `"normal"`.
- Existing agents on first read get `"normal"`; no migration needed.

### RPCs
- `agents create`: requires `model_tier` (UI form always sends one; default `normal`). Validate ∈ {cheap, normal, smart}.
- `agents update`: accepts `model_tier`; same validation.
- `agents start`: reads `model_tier` from the record; appends `--tier <value>` to the wrapper argv.
- `agents list` / `agents show`: include `model_tier` in responses so the UI can render it.

No one-off override at start time — if you want to run smart for one session, edit the agent first. Keeps the model state predictable.

---

## Wrapper changes (`src/wrapper/main.odin`)

1. Parse `--tier <value>` from `os.args`. If absent, default to `"normal"`.
2. In `build_agent_command`, after `yolo_flags` and `prompt_flags` and before the starter prompt:
   - Look up `model_value := resolve_model_value(agent_cmd.models, tier)`.
   - If `models.flag != ""` and `model_value != ""`, append `[models.flag, model_value]`.
   - Otherwise log `model_tier_skipped` with the reason and append nothing.
3. Print `model_tier` and `model_value` in the startup log block.

```odin
resolve_model_value :: proc(m: cfg_lib.Model_Tiers_Config, tier: string) -> string {
    switch tier {
    case "cheap":  return m.cheap
    case "normal": return m.normal
    case "smart":  return m.smart
    }
    return ""
}
```

---

## UI changes

### `AgentsPage` create form
Add a radio group / segmented control: `Cheap | Normal | Smart` (default Normal). Posts `model_tier` in the create payload.

### `AgentsPage` edit form (`AgentListItem` inline editor)
Same control, pre-populated from the agent's stored tier. Save sends `model_tier` in the update payload. Show a small note: *"Takes effect on next start"*.

### `AgentSidebar` / list rendering
Show the tier as a small badge on each agent row (e.g. `[NORMAL]`, color-coded). Lets the user see at a glance which agents are running expensive models.

### Disable when unsupported
If the selected agent command has no `[…models]` block in config (or `flag == ""`), the selector is disabled with tooltip: *"Model tier not configured for this provider"*.

---

## Validation rules

- Daemon: rejects create/update with `model_tier` outside `{cheap, normal, smart}`.
- Wrapper: if `--tier` is missing or invalid, hard error and exit (this would mean the daemon-wrapper contract is broken).
- Wrapper: if the tier is valid but the mapped value in config is empty, log `model_tier_unavailable` and skip the flag (agent still starts on the provider's default).
- Wrapper: if `flag == ""` in config, log `model_flag_missing` and skip.

---

## Implementation order

1. **Config**: add `Model_Tiers_Config`, `Section.Wrapper_Agent_Models`, `parse_models_key`.
2. **Wrapper**: parse `--tier`, append `[flag, value]` to argv, log resolution.
3. **config.toml**: add `[…models]` blocks for `pi`, `claude`, `codex`.
4. **Daemon agent store**: add `model_tier` field; default on read.
5. **Daemon RPCs**: accept `model_tier` on create/update; include in list/show responses; pass `--tier` to wrapper on start.
6. **ham-ctl**: add `--tier` to `agents create` and `agents update`.
7. **UI**: add tier selector to create form, edit form, and badge to list view.
8. **Verify**: `nix build`, create agents at each tier, start them, inspect tmux pane to see the launched command includes the right `--model …` flag.

---

## Out of scope (possible follow-ups)

- **Tier-aware task routing** — auto-route tasks to agents of a particular tier based on task complexity.
- **Per-task tier override** — currently the agent runs at one tier for its whole session; switching mid-session requires restart.
- **Cost telemetry** — tracking spend by tier.
