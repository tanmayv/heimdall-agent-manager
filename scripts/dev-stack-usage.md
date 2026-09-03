# Heimdall Dev Stack — Usage Reference

> **Living document.** When you discover something new, fix something wrong, or add a workflow, edit this file. Remove sections that become stale. Add sections as new parts of the stack are exercised. Date significant entries so it is clear when a section was last verified.
>
> Last verified: 2026-09-03 (BT-1..BT-2a bootstrap engine work + live BT-5 stack run).

---

## 0. How this document is used

This doc is a **running reference**, not a tutorial frozen at one point in time. The workflow:

1. You try something with the dev stack, hit a snag, or discover a non-obvious detail.
2. You add it here (or correct a wrong section) **before moving on**.
3. Future you (or another agent) reads this before touching the stack instead of rediscovering things from scratch.

Conventions:
- `PROXY` = dev-proxy URL, default `http://127.0.0.1:8080`. All user-facing API calls go here (auto-injects auth as user `tanmay`).
- `HUB` = hub URL, default `http://127.0.0.1:8081`. Usually you don't call it directly; use the proxy.
- `$BRIDGE_ID` / `$AGENT_ID` / etc = IDs returned by previous calls; substitute real values.
- All `curl` calls assume the proxy is running and authed as the default user.

---

## 1. Starting / stopping the stack

```bash
# One-time: build all nix binaries (result-hub, result-bridge, result-ctl, result-wrapper, result-devproxy)
scripts/dev-stack.sh build

# Start hub + dev-proxy + bridge (repairs bridge config automatically)
scripts/dev-stack.sh start

# Check what is running
scripts/dev-stack.sh status

# Stop local stack (does NOT touch the mundus/production bridge)
scripts/dev-stack.sh stop
```

**If the bridge reports `bridge is offline` after a hub.db reset** (token mismatch):
```bash
scripts/dev-stack.sh enroll    # mints a new bridge token for the current hub.db
scripts/dev-stack.sh start     # restarts with the fresh token
```

**Building without nix on PATH (agent / CI environment):**
```bash
ODIN=/nix/store/vchib3sshhfhmizi3cfv6hjwizmd0z03-odin-dev-2026-05/bin/odin
# ↑ use the 2026-05 build; the 2026-07a build errors on a pre-existing .Haiku OS enum
# in wrapper_endpoint.odin that is unrelated to the source under development.
$ODIN build src/hub    -collection:odin_test=src -out:/tmp/ham-hub
$ODIN build src/bridge -collection:odin_test=src -out:/tmp/ham-bridge
$ODIN build src/wrapper -collection:odin_test=src -out:/tmp/ham-wrapper
```

**Starting the stack manually (no nix):**
```bash
# Use the pre-built result-* symlinks OR the /tmp/ham-* binaries above.
# Hub:
result-hub/bin/ham-hub \
  --listen 127.0.0.1:8081 --db hub.db \
  --migrations-dir src/hub/repository/sqlite/migrations \
  --trusted-proxy-cidr 127.0.0.1/32

# Dev-proxy (auto-injects auth as user tanmay; /api/v1/* -> hub):
result-devproxy/bin/ham-dev-proxy \
  --listen 127.0.0.1:8080 --hub-url http://127.0.0.1:8081 --default-user tanmay

# Bridge (after enroll):
result-bridge/bin/ham-bridge \
  --hub http://127.0.0.1:8081 \
  --bridge-token "$(cat .run-logs/bridge/bridge-token)" \
  --bind-host 127.0.0.1 --port 49323 \
  --local-endpoint-port 49324 \
  --local-run-dir /tmp/heimdall-bridge-local
```

---

## 2. Authentication

All user-facing calls go through the dev-proxy (`http://127.0.0.1:8080`) which injects auth as user `tanmay`. No token header needed.

```bash
# Verify auth / get your user
curl -s http://127.0.0.1:8080/api/v1/me | python3 -m json.tool
```

Bridge calls (enrolling, direct hub bridge routes) use a bridge token:
```bash
BRIDGE_TOKEN=$(cat .run-logs/bridge/bridge-token)
curl -s -H "Authorization: Bearer $BRIDGE_TOKEN" http://127.0.0.1:8081/api/v1/...
```

---

## 3. Agents

### 3.1 Create an agent

```bash
PROXY=http://127.0.0.1:8080

# Minimal (no template, no instructions)
curl -s -X POST $PROXY/api/v1/agents \
  -H 'Content-Type: application/json' \
  -d '{"name":"My Agent","provider":"claude"}' | python3 -m json.tool

# With template + own instructions
curl -s -X POST $PROXY/api/v1/agents \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"My Agent\",\"template_id\":\"$TMPL_ID\",\"instructions\":\"Prefer small diffs.\",\"provider\":\"claude\"}"
```

**Fields:** `name` (required), `provider` (`claude`/`codex`/…), `tier` (`smart`/`fast`), `template_id`, `instructions`.

**Note:** `provider` on the agent is a default hint; the actual provider used at launch time is what the instance gets.

### 3.2 Update an agent

```bash
curl -s -X PATCH $PROXY/api/v1/agents/$AGENT_ID \
  -H 'Content-Type: application/json' \
  -d '{"template_id":"tmpl_...", "instructions":"updated"}'
```

### 3.3 List agents

```bash
curl -s $PROXY/api/v1/agents | python3 -c "import sys,json;[print(a['agent_id'],a['name']) for a in json.load(sys.stdin)['data']]"
```

---

## 4. Templates (agent personas)

Templates carry `persona` + `instructions` that are injected into every agent's bootstrap `AGENTS.md` that uses the template (via the BT-2a identity variable flow: `{template_persona}` / `{template_instructions}` in the single template).

### 4.1 Create a template

```bash
curl -s -X POST $PROXY/api/v1/templates \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "systems-engineer",
    "description": "Meticulous Odin-style engineer",
    "persona": "You are a meticulous systems engineer named Odin.",
    "instructions": "Follow the house style. Write tests before code. Prefer small, reviewed diffs."
  }' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['template_id'])"
```

### 4.2 List / update / delete templates

```bash
curl -s $PROXY/api/v1/templates | python3 -m json.tool
curl -s -X PATCH $PROXY/api/v1/templates/$TMPL_ID \
  -H 'Content-Type: application/json' -d '{"persona":"updated persona"}'
curl -s -X DELETE $PROXY/api/v1/templates/$TMPL_ID
```

**Important:** Templates are seeded by users/agents via the API — the daemon does NOT seed them. Template persona/instructions survive daemon removal (BT-6). Agents reference templates by `template_id`; the hub fetches them at manifest-render time via `content_get_template`.

---

## 5. Projects

```bash
# Create
curl -s -X POST $PROXY/api/v1/projects \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Heimdall",
    "default_path": "~/heimdall-hub-rewrite",
    "repo_url": "git@github.com:tanmayv/heimdall-agent-manager.git",
    "vcs_kind": "git",
    "description": "Enterprise multi-agent orchestrator."
  }' | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['project_id'])"

# ⚠️ Field is `default_path` not `path` — `path` is silently ignored (learned 2026-09-03)

# List
curl -s $PROXY/api/v1/projects | python3 -c "import sys,json;[print(p['project_id'],p['name']) for p in json.load(sys.stdin)['data']]"
```

---

## 6. Launching agent instances

An **agent instance** = one running agent process (a specific agent, on a specific bridge, optionally in a chain + project).

```bash
# Basic launch (worker, no chain, no project)
curl -s -X POST $PROXY/api/v1/agent-instances \
  -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"$AGENT_ID\",\"bridge_id\":\"$BRIDGE_ID\",\"provider\":\"claude\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['agent_instance_id'])"

# Launch in a chain + project (role is passed but coordinator must be set explicitly via chain members)
curl -s -X POST $PROXY/api/v1/agent-instances \
  -H 'Content-Type: application/json' \
  -d "{
    \"agent_id\":\"$AGENT_ID\",
    \"bridge_id\":\"$BRIDGE_ID\",
    \"project_id\":\"$PROJ_ID\",
    \"chain_id\":\"$CHAIN_ID\",
    \"provider\":\"claude\"
  }" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['agent_instance_id'])"
```

**Accepted fields:** `agent_id` (required), `bridge_id` (required), `provider`, `tier`, `project_id`, `chain_id`.

**Note on `role`:** The `role` field is NOT accepted in `create_agent_instance_handler` (`instance_input_from_body` in `agent_handlers.odin` does not extract it). Role is determined by the chain's `coordinator_agent_instance_id` at manifest render time. To make an instance the coordinator, set it via the chain member route AFTER launch (see §7.3).

### 6.1 Stop / restart an instance

```bash
curl -s -X POST $PROXY/api/v1/agent-instances/$INST_ID/stop   -H 'Content-Type: application/json' -d '{}'
curl -s -X POST $PROXY/api/v1/agent-instances/$INST_ID/restart -H 'Content-Type: application/json' -d '{}'
```

### 6.2 List running instances

```bash
curl -s $PROXY/api/v1/agent-instances | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
for i in d: print(i['agent_instance_id'], i['runtime_status'], i.get('chain_id',''))
"
```

---

## 7. Task chains

### 7.1 Create a chain

```bash
curl -s -X POST $PROXY/api/v1/task-chains \
  -H 'Content-Type: application/json' \
  -d '{"title":"My work","description":"# Goal\n\nDo the thing.\n"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['chain_id'])"
```

### 7.2 Publish a chain (makes it visible to agents)

```bash
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/publish \
  -H 'Content-Type: application/json' -d '{}'
```

### 7.3 Set a chain coordinator (add a member)

The coordinator line in `AGENTS.md` (`Coordinator: you (coordinator)` vs `Coordinator: <instance_id>`) is driven by `chain.coordinator_agent_instance_id`. To set it:

```bash
# Add an agent instance as coordinator
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/members \
  -H 'Content-Type: application/json' \
  -d "{\"agent_instance_id\":\"$COORD_INST_ID\",\"role\":\"coordinator\"}"

# Add a worker
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/members \
  -H 'Content-Type: application/json' \
  -d "{\"agent_instance_id\":\"$WORKER_INST_ID\",\"role\":\"worker\"}"
```

**⚠️ Learned 2026-09-03:** adding a member requires `agent_instance_id` (not `agent_id`). The instance must already be launched. `add_chain_member` requires the instance ID.

### 7.4 Create tasks

```bash
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks \
  -H 'Content-Type: application/json' \
  -d "{
    \"title\": \"Implement foo\",
    \"description\": \"Do REQ-1.\",
    \"assignee_agent_instance_id\": \"$WORKER_INST_ID\"
  }" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['task_id'])"

# Publish the task (makes it visible to agents)
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/publish \
  -H 'Content-Type: application/json' -d '{}'
```

### 7.5 Change task status

```bash
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/status \
  -H 'Content-Type: application/json' \
  -d '{"status":"in_progress"}'
# statuses: queued | assigned | in_progress | in_validation | completed | cancelled
```

### 7.6 Add comments, vote, nudge

```bash
# Comment
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/comments \
  -H 'Content-Type: application/json' -d '{"body":"Work started."}'

# Vote (reviewer only)
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/vote \
  -H 'Content-Type: application/json' -d '{"result":"lgtm","comment":"Looks good."}'

# Nudge
curl -s -X POST $PROXY/api/v1/task-chains/$CHAIN_ID/tasks/$TASK_ID/nudge \
  -H 'Content-Type: application/json' -d '{}'
```

### 7.7 List tasks in a chain

```bash
curl -s "$PROXY/api/v1/task-chains/$CHAIN_ID/tasks" | python3 -c "
import sys,json; tasks=json.load(sys.stdin)['data']
for t in tasks: print(t['task_id'], t['status'], t['title'][:50])
"
```

---

## 8. Reading bootstrapped content (AGENTS.md / skills)

After an agent instance is launched, the bridge materializes its bootstrap files. The wrapper (running as a tmux subprocess of the bridge) fetches the fileset from the bridge and writes it to the instance run dir.

### 8.1 Locate the run dir

Default bridge run dir is `/tmp/heimdall-bridge-local` (production) or whatever `--local-run-dir` was passed. Instance run dirs land at:

```
<bridge-run-dir>/instances/<agent_instance_id>/
```

```bash
INST_RUN=/tmp/heimdall-bridge-local/instances/$INST_ID
# or for local dev stack:
INST_RUN=/tmp/hbt5-bridge-run/instances/$INST_ID   # if started with custom local-run-dir

ls $INST_RUN
# CLAUDE.md (or AGENTS.md for non-claude)  — the rendered bootstrap doc
# .pi/skills/<slug>/SKILL.md               — static skill files
# .heimdall/bin/ham-ctl                    — the ctl shim
# heimdall-bootstrap-manifest.json         — bridge-emitted manifest listing managed files
# .heimdall-wrapper-placed                 — wrapper-owned stale-prune record (added BT-4)
```

### 8.2 Read AGENTS.md / CLAUDE.md

```bash
cat $INST_RUN/CLAUDE.md   # claude profile
cat $INST_RUN/AGENTS.md   # other profiles
```

**New output format (single-template engine, post-BT-2a):**
```
# Agent bootstrap
Agent: <name>
Instance: <inst_id>
Task chain: <title> (<chain_id>)
Coordinator: you (coordinator)  ← or <coord_inst_id> for workers

## Agent Identity & Instructions
### Persona
<template.persona>
### Instructions
<template.instructions>
<agent.instructions>

## Project
...
## You are the COORDINATOR / WORKER / REVIEWER ...  ← role block
## Working with tasks (REQUIRED)
...
## Heimdall CLI        ← appended by bridge, always present
```

**Differences from the old fragment-concatenation model:**
- No `## Applicable Memories` section (memories are fetched separately).
- `### Persona` and `### Instructions` sub-headings always present (stray empty headings OK per design).
- `{{#is_reviewer}}` role block is new.
- Static skills no longer role-gated (all agents get the same set).

### 8.3 Inspect the bridge bootstrap cache

The bridge caches all blobs (template, variable values, skill files) by sha256 hash under:
```
<bridge-data-dir>/bootstrap/blobs/<hash>
```

```bash
# The manifest JSON includes all hashes; the template hash is the sha256 of bootstrap_agents.md:
python3 -c "
import json; d=json.load(open('$INST_RUN/heimdall-bootstrap-manifest.json'))
print('managed:', [f['relative_path'] for f in d['managed_files']])
"
```

### 8.4 Fetch the bootstrap manifest JSON from the hub

The hub serves the agent-keyed manifest at:
```
GET /api/v1/bridge/agents/<agent_id>/bootstrap-manifest?role=<role>&provider=<provider>&project=<project_id>
```

```bash
BRIDGE_TOKEN=$(cat .run-logs/bridge/bridge-token)
curl -s -H "Authorization: Bearer $BRIDGE_TOKEN" \
  "http://127.0.0.1:8081/api/v1/bridge/agents/$AGENT_ID/bootstrap-manifest?role=coordinator&provider=claude&project=$PROJ_ID" \
  | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
print('version:',d.get('version',''))
print('template hash:',d.get('template',{}).get('hash',''))
print('variables:',[v['name'] for v in d.get('variables',[])])
print('skills:',[s['name'] for s in d.get('skills',[])])
"
```

---

## 9. Memories

```bash
# Create a memory (fact type, project-scoped)
curl -s -X POST $PROXY/api/v1/memories \
  -H 'Content-Type: application/json' \
  -d "{\"type\":\"fact\",\"title\":\"Key fact\",\"body\":\"Always cite file:line.\",\"project_id\":\"$PROJ_ID\"}"

# List memories
curl -s $PROXY/api/v1/memories | python3 -c "
import sys,json; d=json.load(sys.stdin)['data']
for m in d: print(m['memory_id'], m['type'], m['status'], m['title'])
"

# Approve / activate a pending memory
curl -s -X POST $PROXY/api/v1/memories/$MEM_ID/activate \
  -H 'Content-Type: application/json' -d '{}'
```

---

## 10. Bridge enrollment (adding a new bridge)

```bash
# 1. Create enrollment via dev-proxy (no auth header needed with dev-proxy)
ENROLL=$(curl -s -X POST $PROXY/api/v1/bridge-enrollments \
  -H 'Content-Type: application/json' -d '{"label":"my-bridge"}')
TOKEN=$(echo $ENROLL | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['enrollment_token'])")

# 2. Exchange for a durable bridge token
result-bridge/bin/ham-bridge enroll \
  --hub http://127.0.0.1:8081 \
  --enrollment-token $TOKEN \
  --bridge-token-file /tmp/my-bridge-token
```

---

## 11. Checking logs

```bash
tail -f .run-logs/hub.log
tail -f .run-logs/bridge.log
tail -f .run-logs/dev-proxy.log

# Filter for bootstrap-related lines in bridge log
grep -i "bootstrap\|manifest\|template\|placed\|rendered\|persona" .run-logs/bridge.log | tail -30

# Filter for errors
grep -iE "error|FAIL|panic" .run-logs/hub.log | tail -20
```

---

## 12. Running tests

```bash
ODIN=/nix/store/vchib3sshhfhmizi3cfv6hjwizmd0z03-odin-dev-2026-05/bin/odin

# Hub unit tests + golden test (fragment rendering, BT-2/BT-2a variables)
$ODIN build tests/hub_bootstrap_golden_test -collection:odin_test=src -out:/tmp/gt && /tmp/gt

# Bridge @(test) suite (includes BT-3 substitution/role-conditional engine)
$ODIN test src/bridge -collection:odin_test=src -out:/tmp/bridge_test
# ⚠️ The pre-existing permission_relay_integration_test is flaky under the parallel
# runner (passes in isolation). It is unrelated to bootstrap/template code.
# Run a specific test: -define:ODIN_TEST_NAMES=main.bt3_e2e_real_template_coordinator

# Wrapper @(test) suite (includes BT-4 placement + prune)
$ODIN test src/wrapper -collection:odin_test=src -out:/tmp/wrapper_test

# Via flake (if nix on PATH):
nix build .#ham-bootstrap-golden-test && ./result/bin/ham-bootstrap-golden-test

# Regenerate goldens intentionally (do only for deliberate output changes):
HEIMDALL_GOLDEN_UPDATE=1 /tmp/gt
```

---

## 13. Known gotchas & discoveries

| When | Discovery |
|---|---|
| 2026-09-03 | **Odin toolchain:** use `odin-dev-2026-05` from `/nix/store`; the `2026-07a` build errors on `.Haiku` OS enum in `wrapper_endpoint.odin`. |
| 2026-09-03 | **Project creation:** field is `default_path`, not `path`. |
| 2026-09-03 | **Chain coordinator:** `role` is NOT a field in `POST /api/v1/agent-instances`. Set coordinator post-launch via `POST /api/v1/task-chains/<id>/members` with `{"agent_instance_id":"...", "role":"coordinator"}`. |
| 2026-09-03 | **Chain member add:** requires `agent_instance_id` (not `agent_id`). |
| 2026-09-03 | **Standalone launch auto-creates a chain:** if you launch an agent without a `chain_id`, the hub creates a personal chain automatically and assigns the instance as coordinator. |
| 2026-09-03 | **`Coordinator:` line empty:** if no member is set as coordinator on a chain, `chain.coordinator_agent_instance_id` is empty → the bridge renders `Coordinator: ` (empty). Not a bug in the template engine. |
| 2026-09-03 | **Template identity:** `template_persona`/`template_instructions` only appear in the bootstrap if the agent has a `template_id` that resolves via `content_get_template`. Daemon deletion (BT-6) does NOT remove the template API path — templates are seeded via `POST /api/v1/templates` + `ham-ctl agent templates create`. |
| 2026-09-03 | **Bridge run dir layout:** `<bridge-run-dir>/instances/<inst_id>/` contains `CLAUDE.md`/`AGENTS.md`, `.pi/skills/*/SKILL.md`, `.heimdall/bin/ham-ctl`, `heimdall-bootstrap-manifest.json`, `.heimdall-wrapper-placed`. |
| 2026-09-03 | **`wrapper.bootstrap.list` RPC:** the bridge local endpoint is a unix socket (`<bridge-run-dir>/bridge.sock`), not an HTTP port. The wrapper calls it over the socket; you can't curl it directly from outside the bridge process. |
