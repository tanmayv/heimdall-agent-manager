# End-to-End Bootstrap Audit

Test executed via daemon RPCs against a fresh project, template, and all six
memory types. Captures what the wrapper actually renders into the agent's
`run_dir`, and what is missing relative to user expectations.

## Setup (created via API)

| Resource | Value |
|---|---|
| Project | `project_1782036151674` "E2E Bootstrap Audit", description "Verify bootstrap embeds template+memories of all types", anchor `directory:/tmp/e2e-audit` |
| Template | `e2e-analyst` "E2E Analyst", role_hint `assignee`, default_provider_profile `pi`, instructions "E2E test template — verifies analyst-flavored bootstrap.", memory_templates `["e2e-team-policy"]` |
| Agent | `e2e-analyst-audit@project-1782036151674`, provider `pi`, tier `cheap` |
| Memories (all approved) | `template:e2e-team-policy`, `expertise:e2e-analyst-expertise`, `habit:e2e-analyst-habit`, `fact:e2e-analyst-fact`, `episode:e2e-analyst-episode`, `skill:e2e-analyst-skill` |

## Run-dir contents

```
agent-runs/project-1781933146508/e2e-analyst-audit-project-1782036151674/
├── AGENTS.md
└── .heimdall-bootstrap-manifest
```

**Only one bootstrap file rendered** — no `MEMORY.md`, no `skills/` directory.

## What IS referenced in AGENTS.md

| Section | Source | Notes |
|---|---|---|
| Identity (display name, instance id, provider/profile, daemon URL, FIRST RUN command) | Agent record + wrapper | Correct, uses absolute `ham-ctl` path now |
| Heimdall Tooling guidance | Hardcoded in `bootstrap_profile_guidance` | Profile-specific (pi/claude/codex) |
| Ham-ctl CLI Reference (~80 lines of examples) | Hardcoded in `build_agents_md` | Same for every agent |
| Project Context: name, ID, description, anchors | Project store via `project_bootstrap_context` | Correct, full anchor list rendered |
| **Active Approved Memory** — `expertise`, `habit`, `fact`, `episode` | Memory provider via `render_memory_for_agents_md` | Inlined as bullet list under one section |

## What is NOT referenced

### Template metadata (not surfaced anywhere)
- `template_id` (`e2e-analyst`) — no mention in AGENTS.md
- Template `display_name` ("E2E Analyst") — no mention
- Template `instructions` ("E2E test template — verifies…") — **not piped into bootstrap at all** despite being a per-template field meant for this purpose
- Template `role_hint` (`assignee`) — no mention
- Template `parent_template_id` — no mention
- Template `memory_templates` list (`e2e-team-policy`) — the list is consulted to fetch template memories, but the **template memory itself does not appear** in AGENTS.md (see below)

### Configuration metadata
- `model_tier` (`cheap`) — no mention in AGENTS.md

### Memory routing not matching the user spec
User spec: `habit/expertise` → AGENTS.md, `fact/episode` → MEMORY.md, `skill` → `skills/` directory.

Observed for **pi provider**:
- `habit`, `expertise` → AGENTS.md ✅
- `fact`, `episode` → **AGENTS.md** (inline, not in MEMORY.md) ❌
- `skill` → **missing entirely**; no `skills/` directory created ❌
- `template:e2e-team-policy` → **missing entirely** despite being approved and matching the template's `memory_templates` list ❌

Root cause: `config.toml` only enables `AGENTS_MD` for the `pi` provider:
```toml
[wrapper.agent-cmd.pi.bootstrap]
enabled_features = ["AGENTS_MD"]
```
Compare to `claude` which has `["AGENTS_MD", "MEMORY_MD", "SKILLS"]`. When
`MEMORY_MD` isn't enabled, the wrapper inlines fact/episode bodies into
AGENTS.md (see `render_memory_for_agents_md`, `has_memory_md` branch). When
`SKILLS` isn't enabled, skill memories are silently dropped.

Even with the right features enabled, the template memory (`e2e-team-policy`)
not surfacing is a **separate bug**: `parse_into_memory_records` matches
template memories against `memory_templates` strings, but the matching path in
`format_active_memory_bootstrap` relies on
`memory_template_matches(object, memory_templates)` which does substring
matching on the raw JSON object — needs investigation.

## Bugs discovered during this test (in priority order)

1. **Template `instructions` field is silently ignored.** Operators put
   template-specific guidance into `instructions`, expecting it to appear in
   the bootstrapped agent's context. Today it goes into agent_store and
   nowhere else. Either render it in AGENTS.md or document it as
   admin-only metadata.

2. **`template_id`, `role_hint`, `model_tier` not surfaced.** The agent has no
   way to know what role it was instantiated as without calling back to the
   daemon. These are stable identity facts that should be in the IDENTITY
   block.

3. **`run_dir` uses `config.toml` default project, not `--project-id`.** The
   agent for project `project_1782036151674` actually lives under
   `agent-runs/project-1781933146508/...`. The wrapper applies the
   `--project-id` override only inside the bootstrap-context branch, after
   `resolve_agent_run_dir` has already chosen the directory. Both should use
   the same source.

4. **Template memories matched by raw substring on JSON.** The current matcher
   walks the JSON response with `strings.contains` on the templates list,
   which can both false-match unrelated text and false-miss when the title
   contains characters that need escaping. Use a structured match on the
   `title` field.

5. **`pi` provider bootstrap is missing MEMORY_MD / SKILLS by default.** This
   may be intentional (pi may not consume MEMORY.md the way Claude Code
   does), but the user's mental model is provider-agnostic. Either enable
   them by default for pi too, or document that fact/episode/skill memories
   render differently per provider.

6. **`/agents/stop` doesn't kill the tmux window.** Stop sends an in-pane
   message and waits for `stop_done`, but the pane survives. Restarting the
   agent then hits the "tmux window already exists; abort" path. The stop
   path should either kill the window or the start path should overwrite a
   stale window for the same instance.

## Reproduction commands

```bash
D=http://127.0.0.1:49322
CT=<uct_…>; CINST=e2e-audit-client
AUTH="\"client_token\":\"$CT\",\"client_instance_id\":\"$CINST\""

# 1. Project
curl -X POST $D/user-rpc -d "{$AUTH,\"action\":\"project_create\",\"name\":\"E2E Bootstrap Audit\",\"description\":\"…\",\"anchors\":[…]}"

# 2. Template
curl -X POST $D/agents/templates/create -d \
  '{"template_id":"e2e-analyst","display_name":"E2E Analyst","role_hint":"assignee","default_provider_profile":"pi","instructions":"…","memory_templates":["e2e-team-policy"]}'

# 3. Start agent (creates record + spawns wrapper, which writes AGENTS.md)
curl -X POST $D/agents/start -d \
  '{"template_id":"e2e-analyst","project_id":"project_…","provider_profile":"pi","display_name":"e2e-analyst-audit","model_tier":"cheap"}'

# 4. Propose+approve each memory type with subject_agent=<that agent>
for t in template expertise habit fact episode skill; do
  PROP=$(curl -s -X POST $D/memory/propose/new -d "{$AUTH,\"type\":\"$t\",\"title\":\"…\",\"body\":\"…\",\"subject_agent\":\"…\",\"reason\":\"…\",\"evidence\":\"…\"}")
  curl -s -X POST $D/memory/decide -d "{$AUTH,\"proposal_id\":\"$(echo $PROP|jq -r .proposal_id)\",\"decision\":\"approve\"}"
done

# 5. Kill window, restart agent so bootstrap re-runs with memories
tmux kill-window -t "ham-agents:agent-<instance-id>"
curl -X POST $D/agents/start -d '{…same body as step 3, plus agent_instance_id…}'

# 6. Read AGENTS.md / MEMORY.md / skills/
ls -la <run_dir>/
cat <run_dir>/AGENTS.md
```
