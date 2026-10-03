# Codebase Audit: Direct JSON String Manipulation & Refactoring Roadmap

**Status**: Published / Final  
**Requirement IDs**: `REQ-AUDIT-JSON-1`, `REQ-AUDIT-JSON-2`, `REQ-AUDIT-JSON-3`, `REQ-AUDIT-JSON-4`  
**Reference Issue**: `iss_18dae94b8c41f918`  
**Reference Precedent**: `task_18dae95e5f113d42` (Typed Actor Ref Deserialization, commit `06d56152`)  
**Scope**: Entire Odin codebase across `src/hub/`, `src/bridge/`, `src/ctl/`, and `src/lib/`

---

## 1. Executive Summary

A comprehensive architectural audit was conducted across the `heimdall-agent-manager` Odin codebase to identify, categorize, and propose structural replacements for direct JSON string manipulation. Direct JSON string manipulation—defined as ad-hoc substring searching, manual string slicing, manual JSON serialization via string builders, and untyped DOM map lookups—has historically led to critical production failures.

Most notably, in `iss_18dae94b8c41f918`, `bind_agent_id_to_instance` used `strings.index` to find `"agent_id"` strictly after `"type"`. When an actor reference was serialized with keys in reverse order (`{"agent_id": "...", "type": "agent_id"}`), the search missed the key, silently failing to bind JIT-provisioned worker instances to tasks and rejecting subsequent worker calls with HTTP 403 Forbidden.

This audit reveals that similar anti-patterns remain pervasive throughout the codebase:
- Over **1,600 locations** construct JSON via manual string builder concatenation (`strings.write_string(&b, "{\"...")`).
- Over **420 locations** invoke single-key extraction helpers (`extract_json_string`, `extract_json_int`, `jsonx.extract_*`), often re-parsing the identical JSON document 10 to 15 times sequentially to read adjacent fields.
- Over **340 locations** perform manual `strings.index` or `strings.contains` operations on raw JSON strings, creating severe key-order, whitespace, and substring collision vulnerabilities.
- Critical daemon wire protocols, authentication resolution routines, and process supervision loops rely on hand-rolled, incomplete JSON scanners (such as `_inventory_value` in `shell_session_inventory.odin` and `json_key_value` in `auth_service.odin`).

This report categorizes all offenders into three risk tiers, provides concrete typed Odin struct definitions with `core:encoding/json` tags, and lays out an actionable phase-by-phase refactoring roadmap.

---

## 2. Quantitative Scan Results

A static and semantic AST scan across all non-test Odin source files (`*.odin` excluding `*_test.odin`) yielded the following distribution of direct JSON manipulation patterns:

| Anti-Pattern Category | Occurrences | Primary Affected Modules |
| :--- | :--- | :--- |
| **Manual JSON Construction** (`strings.write_string`, `fmt.sbprintf`, `json_write_string`) | 1,600 | `bridge/vcs_api.odin` (175), `hub/transport/http/taskchain_handlers.odin` (141), `hub/transport/http/bridge_handlers.odin` (125), `bridge/hub_runtime_client.odin` (116), `bridge/fs_management.odin` (102) |
| **Manual Escaping Helpers** (`json_write_string`, `bridge_runtime_write_json_string`) | 514 | `ctl/legacy/daemon_legacy.odin` (145), `bridge/vcs_api.odin` (95), `bridge/hub_runtime_client.odin` (83), `bridge/fs_management.odin` (62), `bridge/provider_store.odin` (33) |
| **Repetitive Extraction Helpers** (`extract_json_string`, `extract_json_int`, `extract_json_bool`) | 423 | `bridge/hub_runtime_client.odin` (178), `bridge/fs_management.odin` (51), `bridge/vcs_api.odin` (32), `bridge/wrapper_endpoint.odin` (26), `bridge/action_scheduler.odin` (23) |
| **Substring Searching & Slicing** (`strings.index`, `strings.contains`, index math) | 343 | `lib/http_client/http_client.odin` (22), `hub/service/agent/agent_service.odin` (17), `hub/transport/http/bridge_handlers.odin` (15), `ctl/tasks.odin` (14), `hub/service/auth/auth_service.odin` (13) |
| **Untyped DOM Tree Traversal** (`json.parse`, `json.Object`, `json.Array` type switches) | 90 | `lib/jsonx/jsonx.odin` (16), `hub/service/card/card_service.odin` (16), `ctl/shell_cmds.odin` (8), `ctl/agent_mode.odin` (7), `ctl/search.odin` (7), `bridge/agent_reconcile.odin` (3) |

---

## 3. Risk Ranking Methodology & Categorization

Offenders are categorized into three risk tiers based on three operational dimensions:
1. **Criticality & Blast Radius**: Impact on process supervision, cluster coordination, authentication integrity, or task chain FSM transitions.
2. **Memory Safety & Leak Potential**: Vulnerability to memory accumulation in persistent daemon loops or long-lived heap contexts vs bounded per-request virtual arenas.
3. **Fragility & Maintainability**: Susceptibility to key reordering, JSON formatting/whitespace variations, and string escaping bugs.

```
+-----------------------------------------------------------------------------------+
| TIER 1: HIGH RISK (Control Plane, Process Supervision, Daemon Wire, Auth, Loops)   |
| - Hub-to-Bridge WebSocket Wire Protocol (hub_runtime_client.odin)                  |
| - Shell Session Persistence, Specs & Outbox (bridge_shell_session, outbox)        |
| - Process Inventory & Hand-Rolled Lexer (shell_session_inventory.odin)            |
| - Bridge Heartbeat & Agent Status Digest (bridge_handlers.odin)                   |
| - Request Authentication Identity Resolution (auth_service.odin)                  |
| - Agent Dispatch & Bridge Capability Matching (agent_service.odin)                |
+-----------------------------------------------------------------------------------+
                                         |
+-----------------------------------------------------------------------------------+
| TIER 2: MEDIUM RISK (Transport Endpoints, RPC Handlers, Subsystem APIs)           |
| - Bridge File System Command & Result Serialization (fs_management.odin)          |
| - Bridge Provider Store Profiles & Overrides (provider_store.odin)                |
| - Bridge VCS API Handlers & Log/Diff Serializers (vcs_api.odin)                   |
| - Hub Taskchain & Shell Session REST Handlers (taskchain_handlers, rest_handlers) |
| - Bridge Update Catalog Parsing (bridge_update_catalog.odin)                      |
| - Router Envelope Payloads (lib/router_envelope/payloads.odin)                    |
+-----------------------------------------------------------------------------------+
                                         |
+-----------------------------------------------------------------------------------+
| TIER 3: LOW RISK (CLI Formatting, Diagnostic Tooling, Legacy Components)          |
| - CLI Task Creation & Status Output (ctl/tasks.odin)                              |
| - CLI Ad-hoc JSON Object Builders (ctl/jsonx.odin)                                |
| - Legacy Daemon & Diagnostic Test Agents (ctl/legacy, test_agent)                 |
+-----------------------------------------------------------------------------------+
```

---

## 4. Detailed Component Audits & Offender Analysis

### Tier 1: High Risk Offenders

---

#### Offender 1.1: Hub-to-Bridge WebSocket Wire Protocol Dispatch
- **File**: `src/bridge/hub_runtime_client.odin`
- **Line Numbers**: 2628–2646, 2753–2768, 2828–2845, 2854–2876, 3402–3404, 3463–3468, 3599–3638, 3642–3646, 3767–3776, 3911–3912, 4118–4119
- **Existing Anti-Pattern**:
  Incoming WebSocket command payloads are deserialized by calling `extract_json_string` and `extract_json_int` up to 14 times in sequence on the same string:
  ```odin
  // Lines 2854-2876
  session_id  := extract_json_string(text, "session_id", "")
  command_id  := extract_json_string(text, "command_id", "")
  kind_str    := extract_json_string(text, "kind", "run")
  cmd         := extract_json_string(text, "cmd", "")
  cwd         := extract_json_string(text, "cwd", "")
  label       := extract_json_string(text, "label", "")
  project_id  := extract_json_string(text, "project_id", "")
  chain_id    := extract_json_string(text, "chain_id", "")
  agent_iid   := extract_json_string(text, "agent_instance_id", "")
  owner_uid   := extract_json_string(text, "owner_user_id", "")
  hub_started_at := extract_json_string(text, "started_at", "")
  server_port := extract_json_int(text, "server_port", 0)
  background := bridge_local_extract_json_bool(text, "background", false)
  run_seq := extract_json_int(text, "run_seq", 0)
  ```
  Outbound messages are built via manual builder calls:
  ```odin
  // Lines 2753-2768
  bridge_shell_exited_event_json :: proc(session_id: string, exit_code: int, exit_code_set: bool, status: string, run_seq: int) -> string {
      b := strings.builder_make()
      strings.write_string(&b, "{\"type\":\"shell_exited\",\"session_id\":\"")
      bridge_runtime_write_json_string(&b, session_id)
      strings.write_string(&b, "\",\"exit_code\":")
      ...
  ```
- **Architectural Risk & Blast Radius**:
  1. *O(N) Full AST Re-Parsing*: Each `extract_json_string` call invokes `json.parse_string`, allocates a DOM tree, searches for the key, and calls `json.destroy_value`. For `shell_start`, the bridge parses the JSON AST from scratch 14 consecutive times.
  2. *Escaping Bugs & WebSocket Drops*: Hand-rolled `bridge_runtime_write_json_string` (line 2628) only escapes `\\`, `"`, `\n`, `\r`, `\t` and formats controls `< 32`. Unescaped unicode or malformed surrogate pairs cause WebSocket frames to be invalid JSON, breaking the connection to the Hub.
  3. *Daemon Memory Accumulation*: `extract_json_string` clones strings onto `context.allocator`. If callers miss a `delete()`, memory accumulates across long-lived daemon connections.
- **Proposed Typed Structs**:
  ```odin
  Shell_Start_Command :: struct {
      type:              string `json:"type"`,
      command_id:        string `json:"command_id"`,
      session_id:        string `json:"session_id"`,
      kind:              string `json:"kind"`,
      cmd:               string `json:"cmd"`,
      cwd:               string `json:"cwd"`,
      label:             string `json:"label"`,
      project_id:        string `json:"project_id"`,
      chain_id:          string `json:"chain_id"`,
      agent_instance_id: string `json:"agent_instance_id"`,
      owner_user_id:     string `json:"owner_user_id"`,
      started_at:        string `json:"started_at"`,
      server_port:       int    `json:"server_port"`,
      background:        bool   `json:"background"`,
      run_seq:           int    `json:"run_seq"`,
  }

  Shell_Exited_Event :: struct {
      type:          string `json:"type"`,
      session_id:    string `json:"session_id"`,
      exit_code:     int    `json:"exit_code"`,
      exit_code_set: bool   `json:"exit_code_set"`,
      status:        string `json:"status"`,
      finished_at:   string `json:"finished_at"`,
      run_seq:       int    `json:"run_seq"`,
  }

  Shell_Error_Result :: struct {
      type:        string `json:"type"`,
      session_id:  string `json:"session_id"`,
      command_id:  string `json:"command_id"`,
      ok:          bool   `json:"ok"`,
      error:       string `json:"error"`,
      server_port: int    `json:"server_port,omitempty"`,
      pid:         int    `json:"pid,omitempty"`,
  }
  ```

---

#### Offender 1.2: Shell Session Specification Persistence & Loading
- **File**: `src/bridge/bridge_shell_session.odin`
- **Line Numbers**: 847–892, 927–965
- **Existing Anti-Pattern**:
  Writing session specs to disk uses 45 lines of string builder concatenation:
  ```odin
  // Lines 849-891
  strings.write_string(&b, "{\"session_id\":\"")
  bridge_local_write_json_string(&b, s.session_id)
  strings.write_string(&b, "\",\"kind\":\"")
  bridge_local_write_json_string(&b, bridge_shell_session_kind_str(s.kind))
  ...
  strings.write_string(&b, ",\"exit_code\":")
  bridge_agent_write_int(&b, s.exit_code)
  strings.write_string(&b, ",\"exit_code_set\":")
  strings.write_string(&b, s.exit_code_set ? "true" : "false")
  ```
  Reading session specs uses manual generic DOM parsing and repeated type-assertive map lookups:
  ```odin
  // Lines 927-965
  parsed, jerr := json.parse(raw)
  defer json.destroy_value(parsed)
  obj, is_obj := parsed.(json.Object)
  if v, ok := obj["session_id"].(json.String); ok do s.session_id = strings.clone(string(v), allocator)
  if v, ok := obj["kind"].(json.String); ok do s.kind = bridge_shell_session_kind_from_str(string(v))
  if v, ok := obj["pid"].(json.Float); ok do s.pid = int(v)
  if v, ok := obj["server_port"].(json.Float); ok do s.server_port = int(v)
  if v, ok := obj["exit_code_set"].(json.Boolean); ok do s.exit_code_set = bool(v)
  ```
- **Architectural Risk & Blast Radius**:
  1. *Odin Float-vs-Int JSON Ambiguity*: Odin's generic `json.parse` decodes all numbers as `json.Float` (f64). The manual loader casts `obj["pid"].(json.Float)` to `int`. If the JSON spec was written or edited with alternative encodings, casting fails silently, leaving `pid = 0`.
  2. *Disk Format Drift*: Spec serialization and deserialization are maintained manually in two separate places. Adding a new field to `Bridge_Shell_Session` requires modifying 30 lines in `bridge_shell_session_save_spec`, 20 lines in `bridge_shell_session_load_specs`, and 40 lines in `bridge_shell_session_write_json`.
- **Proposed Typed Structs**:
  ```odin
  Shell_Session_Spec :: struct {
      session_id:        string `json:"session_id"`,
      kind:              string `json:"kind"`,
      label:             string `json:"label"`,
      cmd:               string `json:"cmd"`,
      cwd:               string `json:"cwd"`,
      bridge_id:         string `json:"bridge_id"`,
      project_id:        string `json:"project_id"`,
      chain_id:          string `json:"chain_id"`,
      agent_instance_id: string `json:"agent_instance_id"`,
      owner_user_id:     string `json:"owner_user_id"`,
      pid:               int    `json:"pid"`,
      server_port:       int    `json:"server_port"`,
      run_seq:           int    `json:"run_seq"`,
      status:            string `json:"status"`,
      exit_code:         int    `json:"exit_code"`,
      exit_code_set:     bool   `json:"exit_code_set"`,
      started_at:        string `json:"started_at"`,
      finished_at:       string `json:"finished_at"`,
      shell_id:          string `json:"shell_id"`,
      background:        bool   `json:"background"`,
      pty_host:          bool   `json:"pty_host"`,
  }
  ```

---

#### Offender 1.3: Shell Session Outbox Persistence Across Restart
- **File**: `src/bridge/shell_exited_outbox.odin`
- **Line Numbers**: 131–144, 213–247
- **Existing Anti-Pattern**:
  Envelope write builds manual JSON:
  ```odin
  // Lines 133-144
  strings.write_string(&b, "{\"session_id\":\"")
  bridge_local_write_json_string(&b, session_id)
  strings.write_string(&b, "\",\"enqueued_at_ms\":")
  bridge_agent_write_int(&b, int(enqueued_at_ms))
  strings.write_string(&b, ",\"event\":\"")
  bridge_local_write_json_string(&b, event_json)
  strings.write_string(&b, "\"}")
  ```
  Envelope reload parses DOM manually:
  ```odin
  // Lines 213-240
  parsed, jerr := json.parse(raw)
  defer json.destroy_value(parsed)
  obj, is_obj := parsed.(json.Object)
  if v, ok := obj["session_id"].(json.String); ok do e.session_id = strings.clone(string(v))
  if v, ok := obj["event"].(json.String); ok do e.event_json = strings.clone(string(v))
  if v, ok := obj["enqueued_at_ms"].(json.Float); ok do e.enqueued_at_ms = i64(v)
  ```
- **Architectural Risk & Blast Radius**:
  The outbox stores the `event` as an escaped string literal inside an envelope. Escaping JSON inside JSON manually with `bridge_local_write_json_string` creates double-escaping hazards. If an exit event contains quotes or backslashes in process errors, manual unescaping bugs can corrupt the queued exit, causing the envelope to be discarded as "corrupt" on line 221 and stranding the session as "running" forever on the Hub.
- **Proposed Typed Structs**:
  ```odin
  Shell_Exited_Outbox_Envelope :: struct {
      session_id:     string `json:"session_id"`,
      enqueued_at_ms: i64    `json:"enqueued_at_ms"`,
      event:          string `json:"event"`,
  }
  ```

---

#### Offender 1.4: Process Inventory Hand-Rolled Lexer & String Scanners
- **File**: `src/hub/service/shell_session/shell_session_inventory.odin`
- **Line Numbers**: 717–770 (`_inventory_objects`), 793–807 (`_inventory_str`), 810–822 (`_inventory_int`), 843–871 (`_inventory_value`)
- **Existing Anti-Pattern**:
  The entire file implements a custom, hand-rolled JSON parser to avoid calling `json.parse_string`:
  ```odin
  // Lines 722-766: Hand-rolled bracket/brace counter
  _inventory_objects :: proc(body: string) -> [][]u8 { ... }

  // Lines 793-806: Custom string extractor
  _inventory_str :: proc(obj: []u8, key: string) -> string {
      body := string(obj)
      value_start, ok := _inventory_value(body, key)
      if !ok do return ""
      rest := body[value_start:]
      if len(rest) == 0 || rest[0] != '"' do return ""
      escaped := false
      for i := 1; i < len(rest); i += 1 {
          ch := rest[i]
          if escaped { escaped = false; continue }
          if ch == '\\' { escaped = true; continue }
          if ch == '"' do return rest[1:i]
      }
      return ""
  }
  ```
  Line 776 explicitly documents:
  > *"IT RETURNS THE RAW, STILL-ESCAPED SPAN, and does not decode... A cmd the bridge wrote from `echo "hi"` therefore reads back as `echo \"hi\"`, with the backslashes."*
- **Architectural Risk & Blast Radius**:
  1. *Adoption Mismatches*: When the Hub adopts shell sessions from a restarted bridge, command lines with quotes or backslashes are read with verbatim escape characters. If the Hub compares the adopted command against expected commands, strings mismatch.
  2. *Orphan Reaping Disasters*: Inventory reconciliation reaps sessions by absence. If a malformed brace causes `_inventory_objects` to drop entries, live processes are incorrectly marked as terminated and orphans are reaped in error.
- **Proposed Typed Structs**:
  ```odin
  Bridge_Shell_Inventory_Item :: struct {
      session_id:        string `json:"session_id"`,
      kind:              string `json:"kind"`,
      label:             string `json:"label"`,
      cmd:               string `json:"cmd"`,
      cwd:               string `json:"cwd"`,
      bridge_id:         string `json:"bridge_id"`,
      project_id:        string `json:"project_id"`,
      chain_id:          string `json:"chain_id"`,
      agent_instance_id: string `json:"agent_instance_id"`,
      owner_user_id:     string `json:"owner_user_id"`,
      pid:               int    `json:"pid"`,
      server_port:       int    `json:"server_port"`,
      run_seq:           int    `json:"run_seq"`,
      status:            string `json:"status"`,
      started_at:        string `json:"started_at"`,
      finished_at:       string `json:"finished_at"`,
  }
  ```

---

#### Offender 1.5: Bridge Heartbeat & Agent Status Digest
- **File**: `src/hub/transport/http/bridge_handlers.odin`
- **Line Numbers**: 1723–1738
- **Existing Anti-Pattern**:
  The Hub parses periodic WebSocket heartbeat status reports from connected bridges using raw substring searching between `"agent_instance_id"` occurrences:
  ```odin
  // Lines 1723-1738
  bridge_apply_heartbeat_digest :: proc(h: ^Bridge_Handlers, bridge_id, text: string) -> []string {
      active := make([dynamic]string)
      search_from := 0
      for search_from < len(text) {
          rel := strings.index(text[search_from:], "\"agent_instance_id\"")
          if rel < 0 do break
          idx := search_from + rel
          next_rel := strings.index(text[idx + len("\"agent_instance_id\""):], "\"agent_instance_id\"")
          end := len(text)
          if next_rel >= 0 do end = idx + len("\"agent_instance_id\"") + next_rel
          entry := text[idx:end]
          instance_id := json_string(entry, "agent_instance_id")
          state_seq := json_int(entry, "state_seq", 0)
          runtime_status := json_string(entry, "runtime_status")
          activity_status := json_string(entry, "activity_status")
          ...
  ```
- **Architectural Risk & Blast Radius**:
  1. *Catastrophic Slicing on Field Reordering*: If the bridge serializes fields with `runtime_status` preceding `agent_instance_id`, `text[idx:end]` cuts off `runtime_status` entirely!
  2. *Substring Corruption*: If an agent's `activity_status` or display string happens to contain the literal phrase `"agent_instance_id"`, the loop slices in the middle of a string value, corrupting both the current entry and all subsequent entries in the heartbeat.
  3. *Liveness Loss*: Heartbeats run every 15 seconds per bridge. A corrupted digest causes the Hub to miss active agent updates, leading to false timeouts and agent lifecycle failures.
- **Proposed Typed Structs**:
  ```odin
  Bridge_Agent_Status_Report :: struct {
      agent_instance_id: string `json:"agent_instance_id"`,
      state_seq:         int    `json:"state_seq"`,
      runtime_status:    string `json:"runtime_status"`,
      activity_status:   string `json:"activity_status"`,
  }

  Bridge_Heartbeat_Payload :: struct {
      type:            string                       `json:"type"`,
      bridge_id:       string                       `json:"bridge_id"`,
      active_instances: []Bridge_Agent_Status_Report `json:"active_instances"`,
  }
  ```

---

#### Offender 1.6: Request Authentication & Token Resolution
- **File**: `src/hub/service/auth/auth_service.odin`
- **Line Numbers**: 110, 154, 185, 202–217
- **Existing Anti-Pattern**:
  Authentication resolution extracts `agent_instance_id` directly from raw request bodies using an ad-hoc substring scanner:
  ```odin
  // Lines 202-217
  json_key_value :: proc(body, key: string) -> string {
      if body == "" do return ""
      needle := strings.concatenate({"\"", key, "\""})
      defer delete(needle)
      idx := strings.index(body, needle)
      if idx < 0 do return ""
      rest := body[idx + len(needle):]
      colon := strings.index_byte(rest, ':')
      if colon < 0 do return ""
      rest = strings.trim_space(rest[colon + 1:])
      if len(rest) == 0 || rest[0] != '"' do return ""
      for i := 1; i < len(rest); i += 1 {
          if rest[i] == '"' do return rest[1:i]
      }
      return ""
  }
  ```
- **Architectural Risk & Blast Radius**:
  1. *Security Vulnerability (Identity Spoofing)*: If a user sends a payload containing `"agent_instance_id"` in a nested comment or message text before the root field:
     `{"message": "I mentioned \"agent_instance_id\": \"inst_victim\"", "agent_instance_id": "inst_attacker"}`
     `json_key_value` matches `inst_victim`!
  2. *Escaped Quote Truncation*: `if rest[i] == '"'` stops on `\"`. If an ID or value contains an escape sequence, it is truncated.
- **Proposed Typed Structs**:
  ```odin
  Auth_Instance_Assertion_Body :: struct {
      agent_instance_id: string `json:"agent_instance_id"`,
  }
  ```

---

#### Offender 1.7: Agent Bridge Capability Matching & Tier Selection
- **File**: `src/hub/service/agent/agent_service.odin`
- **Line Numbers**: 1244–1312, 1560–1592
- **Existing Anti-Pattern**:
  Bridge capabilities JSON (`bridge.capabilities_json`) is scanned using string searches for `"provider"` and `"tiers"`:
  ```odin
  // Lines 1248-1262
  search_from := 0
  for search_from < len(caps) {
      rel := strings.index(caps[search_from:], "\"provider\"")
      if rel < 0 do return false
      idx := search_from + rel
      value := json_value_at(caps, "provider", idx)
      if value == provider {
          if tier == "" do return true
          next_rel := strings.index(caps[idx + len("\"provider\""):], "\"provider\"")
          end := len(caps)
          if next_rel >= 0 do end = idx + len("\"provider\"") + next_rel
          return json_tiers_array_contains(caps[idx:end], tier)
      }
      search_from = idx + len("\"provider\"")
  }
  ```
  `json_tiers_array_contains` searches for `[` and `]`, then calls `strings.contains(body, "\"tier\"")`.
- **Architectural Risk & Blast Radius**:
  Directly affects all worker and coordinator task scheduling. If `capabilities_json` contains formatting variations or comments, capability checks fail, preventing agents from being provisioned on capable bridges.
- **Proposed Typed Structs**:
  ```odin
  Bridge_Provider_Capability :: struct {
      provider:     string   `json:"provider"`,
      tiers:        []string `json:"tiers"`,
      default_tier: string   `json:"default_tier"`,
  }
  ```

---

### Tier 2: Medium Risk Offenders

---

#### Offender 2.1: Bridge File System Management (Commands & Results)
- **File**: `src/bridge/fs_management.odin`
- **Line Numbers**: 1256–1468 (Command dispatch), 1392–1411 (`fs_batch_write`), 1516–1678 (Result serialization)
- **Existing Anti-Pattern**:
  - `fs_batch_write` parses JSON DOM, checks `json.Object`, `json.Array`, and extracts fields with type switches (`item_obj["path"].(json.String)`).
  - Result serialization uses dozens of builder functions:
    ```odin
    bridge_fs_read_file_result_json :: proc(command_id: string, r: Bridge_Fs_Read_File_Result) -> string {
        strings.write_string(&b, "{\"type\":\"fs_read_file_result\",\"command_id\":\""); json_write_string(&b, command_id)
        ...
    ```
- **Architectural Risk**:
  Fragile error-code and path formatting. File paths with special control characters or invalid UTF-8 can produce invalid JSON.
- **Proposed Typed Structs**:
  ```odin
  Fs_Batch_Write_Command :: struct {
      command_id: string               `json:"command_id"`,
      root:       string               `json:"root"`,
      files:      []Bridge_Fs_Write_Item `json:"files"`,
  }

  Fs_Read_Result :: struct {
      type:        string `json:"type"`,
      command_id:  string `json:"command_id"`,
      path:        string `json:"path"`,
      content:     string `json:"content,omitempty"`,
      encoding:    string `json:"encoding,omitempty"`,
      mime:        string `json:"mime"`,
      modified_at: string `json:"modified_at"`,
      error:       Fs_Error `json:"error,omitempty"`,
  }
  ```

---

#### Offender 2.2: Bridge Provider Store Overrides
- **File**: `src/bridge/provider_store.odin`
- **Line Numbers**: 520–620, 625–678
- **Existing Anti-Pattern**:
  `bridge_provider_override_from_json_with_name` invokes `bridge_provider_json_extract_*` over 30 times sequentially on the same JSON object, re-parsing the AST via `jsonx` on every call.
- **Architectural Risk**:
  Severe CPU and allocator churn during bridge startup and configuration reload.
- **Proposed Typed Structs**:
  ```odin
  Provider_Override_Config :: struct {
      name:                 string                         `json:"name"`,
      enabled:              bool                           `json:"enabled"`,
      command:              []string                       `json:"command"`,
      yolo_flags:           []string                       `json:"yolo_flags"`,
      prompt_flags:         []string                       `json:"prompt_flags"`,
      starter_prompt:       string                         `json:"starter_prompt"`,
      prompt_delivery:      string                         `json:"prompt_delivery"`,
      prompt_tmux_delay_ms: int                            `json:"prompt_tmux_delay_ms"`,
      agent_run_dir:        string                         `json:"agent_run_dir"`,
      models:               cfg_lib.Model_Tiers_Config     `json:"models"`,
      startup_detection:    cfg_lib.Startup_Detection_Config `json:"startup_detection"`,
  }
  ```

---

#### Offender 2.3: Bridge VCS API Command Handlers & Serializers
- **File**: `src/bridge/vcs_api.odin`
- **Line Numbers**: 40–100, 600–650
- **Existing Anti-Pattern**:
  15 separate command handlers parse parameters via `extract_json_string` and write results using `json_write_string` and string builder loops (175 manual serialization occurrences).
- **Architectural Risk**:
  Commit log subjects, author names, and diff hunks containing special characters or unescaped bytes can cause client UI errors.
- **Proposed Typed Structs**:
  ```odin
  Vcs_Log_Entry :: struct {
      hash:          string `json:"hash"`,
      short_hash:    string `json:"short_hash"`,
      subject:       string `json:"subject"`,
      author:        string `json:"author"`,
      date:          string `json:"date"`,
      cl_number:     string `json:"cl_number,omitempty"`,
      review_status: string `json:"review_status,omitempty"`,
  }

  Vcs_Log_Result :: struct {
      type:        string          `json:"type"`,
      command_id:  string          `json:"command_id"`,
      ok:          bool            `json:"ok"`,
      provider:    string          `json:"provider"`,
      has_more:    bool            `json:"has_more"`,
      next_cursor: string          `json:"next_cursor,omitempty"`,
      entries:     []Vcs_Log_Entry `json:"entries"`,
      error:       Vcs_Error       `json:"error,omitempty"`,
  }
  ```

---

#### Offender 2.4: Hub Taskchain HTTP Handlers
- **File**: `src/hub/transport/http/taskchain_handlers.odin`
- **Line Numbers**: 496–540, 2070
- **Existing Anti-Pattern**:
  - `write_chain_list_item_json` serializes chain list records field by field.
  - `task_matches_query` runs `strings.contains(task.assignee_ref_json, assignee)`.
- **Architectural Risk**:
  `strings.contains` creates false positive matches when one ID is a prefix or substring of another (e.g. `inst_1` matches `inst_10`).
- **Proposed Typed Structs**:
  ```odin
  Chain_List_Item_Wire :: struct {
      chain_id:                      string `json:"chain_id"`,
      title:                         string `json:"title"`,
      status:                        string `json:"status"`,
      updated_at:                    string `json:"updated_at"`,
      coordinator_agent_instance_id: string `json:"coordinator_agent_instance_id"`,
      project_id:                    string `json:"project_id"`,
      project_name:                  string `json:"project_name"`,
      pinned_at:                     string `json:"pinned_at,omitempty"`,
  }
  ```

---

#### Offender 2.5: Bridge Update Catalog Resolver
- **File**: `src/hub/service/bridge/bridge_update_catalog.odin`
- **Line Numbers**: 111–137
- **Existing Anti-Pattern**:
  `catalog_json_string` and `catalog_target_info` manually search for targets using `strings.index` and slice at `strings.index_byte(rest, '}')`.
- **Architectural Risk**:
  Any nested JSON structure in catalog files breaks at the first `}`, dropping download URLs and sha256 checksums.
- **Proposed Typed Structs**:
  ```odin
  Bridge_Target_Manifest :: struct {
      tarball_url: string `json:"tarball_url"`,
      sha256:      string `json:"sha256"`,
  }

  Bridge_Update_Catalog_Data :: struct {
      version: string                            `json:"version"`,
      targets: map[string]Bridge_Target_Manifest `json:"targets"`,
  }
  ```

---

#### Offender 2.6: Router Envelope Message Payloads
- **File**: `src/lib/router_envelope/payloads.odin`
- **Line Numbers**: 16–33
- **Existing Anti-Pattern**:
  The structs `Message_Send_Payload` and `Message_Read_Payload` exist, but their parse procs call `extract_json_string` repeatedly instead of `json.unmarshal`.
- **Proposed Structs with Tags**:
  ```odin
  Message_Send_Payload :: struct {
      from_agent_instance_id:   string `json:"from_agent_instance_id"`,
      target_agent_instance_id: string `json:"target_agent_instance_id"`,
      body:                     string `json:"body"`,
  }

  Message_Read_Payload :: struct {
      conversation_id:           string `json:"conversation_id"`,
      message_id:                string `json:"message_id"`,
      read_by_agent_instance_id: string `json:"read_by_agent_instance_id"`,
      read_unix_ms:              i64    `json:"read_unix_ms"`,
  }
  ```

---

### Tier 3: Low Risk Offenders

---

#### Offender 3.1: CLI Task Creation Output Parser
- **File**: `src/ctl/tasks.odin`
- **Line Numbers**: 652–682
- **Existing Anti-Pattern**:
  ```odin
  aref_idx := strings.index(resp_str, "\"assignee_ref\":")
  maybe_id := extract_json_string_unescaped(resp_str[aref_idx:], "agent_instance_id", "")
  deps_idx := strings.index(resp_str, "\"depends_on\":[")
  end_idx := strings.index(resp_str[deps_idx:], "]")
  deps_str = resp_str[deps_idx+13 : deps_idx+end_idx+1]
  ```
- **Architectural Risk**:
  Breaks CLI display formatting if the Hub alters JSON whitespace or field ordering.

#### Offender 3.2: CLI Ad-Hoc JSON Object Helpers
- **File**: `src/ctl/jsonx.odin`
- **Line Numbers**: 30–58
- **Existing Anti-Pattern**:
  `json_kv`, `json_kv_raw`, and `json_object` concatenate string slices.
- **Architectural Risk**:
  Low risk for CLI parameters, but vulnerable to quotes in string arguments.

---

## 5. Architectural Anti-Patterns & Root Causes

### 5.1 The "One-More-Parser" Trap
When developers encountered bugs with simple string scanning, the historical pattern was to write an incrementally more sophisticated ad-hoc parser rather than switching to `core:encoding/json`.
In `src/hub/service/shell_session/shell_session_inventory.odin:839-841`, the author explicitly commented:
> *"One string-aware key scan serves the package — three subtly different ones is how this bug class keeps reappearing, each author writing a more careful parser rather than fixing the one they found."*
Yet this proc (`_inventory_value`) still missed unicode decoding and multi-level escape handling.

### 5.2 The O(N) AST Parse Trap
Helpers like `extract_json_string` and `jsonx.extract_*` appear safe and convenient on the surface. However, each call parses the entire JSON payload into a full DOM AST and immediately destroys it. Calling `extract_json_string` 14 times on an incoming message results in 14 full parse-and-destroy cycles per message, generating avoidable allocator churn.

### 5.3 The Substring Collision Trap
Using `strings.contains` or `strings.index` on raw JSON blobs assumes that key names and values are unique throughout the text. In practice:
- A user comment mentioning `"agent_instance_id": "inst_123"` satisfies `strings.index` before the authentic top-level key.
- Checking `strings.contains(reviewer_refs, "inst_1")` falsely matches `"inst_10"`, `"inst_11"`, or `"inst_100"`.

---

## 6. Memory Allocation Discipline & Safety Architecture

To prevent memory leaks and allocator corruption during refactoring, all JSON operations must adhere to strict memory allocation rules:

### 6.1 Temporary Allocator for Request-Scoped Operations
In HTTP request handlers, WebSocket message dispatchers, and background reconcile passes, JSON unmarshaling must use `context.temp_allocator`:
```odin
cmd: Shell_Start_Command
err := json.unmarshal(transmute([]byte)text, &cmd, allocator = context.temp_allocator)
if err != nil {
    // Handle unmarshal error cleanly
    return
}
// Any fields needing long-term retention beyond the current turn MUST be cloned:
long_lived_session_id = strings.clone(cmd.session_id, persistent_allocator)
```
Using `context.temp_allocator` guarantees that intermediate parse nodes, strings, and container arrays are automatically reclaimed when the turn or request completes.

### 6.2 Eliminating Double-Free and Bad-Free Hazards
`core:encoding/json` allocates dynamic memory for strings and arrays inside decoded structs.
- If a struct is unmarshaled with `context.temp_allocator`, callers must **NEVER** call `delete()` on individual struct fields.
- If a struct is unmarshaled with `context.allocator`, developers must define a companion `destroy_proc` (e.g. `shell_start_command_destroy`) that systematically deletes dynamic fields.

---

## 7. Actionable Phase-by-Phase Refactoring Roadmap

```
+-------------------------------------------------------------------------------+
| PHASE 1: High-Risk Control Plane & Background Loops                           |
| Tasks:                                                                        |
| 1.1 Migrate Hub-Bridge WebSocket wire commands to typed structs               |
| 1.2 Replace shell session spec and outbox disk serialization with json.marshal|
| 1.3 Replace inventory hand-rolled lexer with typed struct unmarshaling        |
| 1.4 Refactor bridge heartbeat digest to typed struct unmarshaling             |
| 1.5 Secure auth_service token resolution against body substring spoofing      |
| 1.6 Unify agent provider/tier capability matching with typed structs          |
+-------------------------------------------------------------------------------+
                                       |
+-------------------------------------------------------------------------------+
| PHASE 2: Transport & RPC Boundary Layers                                      |
| Tasks:                                                                        |
| 2.1 Refactor Bridge FS management commands and result builders                |
| 2.2 Migrate Provider Store overrides to typed struct serialization            |
| 2.3 Convert Bridge VCS API commands and log/diff serializers                  |
| 2.4 Unify Taskchain HTTP wire handlers and eliminate substring filters       |
| 2.5 Refactor Bridge update catalog parsing to typed manifest struct           |
| 2.6 Migrate router_envelope payloads to json.unmarshal                        |
+-------------------------------------------------------------------------------+
                                       |
+-------------------------------------------------------------------------------+
| PHASE 3: CLI & Tooling Cleanup                                                |
| Tasks:                                                                        |
| 3.1 Refactor ctl/tasks.odin HTTP response parsing to typed struct             |
| 3.2 Deprecate manual string concatenation helpers in ctl/jsonx.odin           |
| 3.3 Clean up legacy daemon and test agent JSON parsing                        |
+-------------------------------------------------------------------------------+
```

### Phase 1: High-Risk Control Plane & Background Loops (P0)

1. **Phase 1.1: Hub-Bridge WebSocket Protocol Refactor**
   - **Target**: `src/bridge/hub_runtime_client.odin`, `src/hub/service/shell_session/shell_session_service.odin`.
   - **Action**: Define typed wire structs (`Shell_Start_Command`, `Shell_Exited_Event`, `Shell_Error_Result`). Replace repetitive `extract_json_*` and `strings.write_string` builders with `json.unmarshal` and `json.marshal`.
   - **Verification**: Run `odin test src/bridge` and verify zero tracking allocator leaks.

2. **Phase 1.2: Shell Session Specs & Outbox Refactor**
   - **Target**: `src/bridge/bridge_shell_session.odin`, `src/bridge/shell_exited_outbox.odin`.
   - **Action**: Define `Shell_Session_Spec` and `Shell_Exited_Outbox_Envelope`. Replace DOM type assertions and manual builders with typed struct marshaling.
   - **Verification**: Run `odin test src/bridge -test-name:shell_session`.

3. **Phase 1.3: Shell Session Inventory Lexer Replacement**
   - **Target**: `src/hub/service/shell_session/shell_session_inventory.odin`.
   - **Action**: Remove `_inventory_objects`, `_inventory_str`, `_inventory_value`. Decode inventory reports directly into `[]Bridge_Shell_Inventory_Item` using `json.unmarshal(..., allocator = context.temp_allocator)`.
   - **Verification**: Run `odin test src/hub/service/shell_session`.

4. **Phase 1.4: Heartbeat Status Digest Refactor**
   - **Target**: `src/hub/transport/http/bridge_handlers.odin`.
   - **Action**: Unmarshal heartbeat digests into `Bridge_Heartbeat_Payload` using `context.temp_allocator`. Eliminate `"agent_instance_id"` text slicing.
   - **Verification**: Run `odin test src/hub/transport/http -test-name:heartbeat`.

5. **Phase 1.5: Auth Token Resolution Security Hardening**
   - **Target**: `src/hub/service/auth/auth_service.odin`.
   - **Action**: Replace `json_key_value` with top-level `Auth_Instance_Assertion_Body` unmarshaling. Ensure nested or comment occurrences cannot spoof identities.
   - **Verification**: Run `odin test src/hub/service/auth`.

6. **Phase 1.6: Agent Capability Matching Refactor**
   - **Target**: `src/hub/service/agent/agent_service.odin`.
   - **Action**: Parse `bridge.capabilities_json` into `[]Bridge_Provider_Capability` on `context.temp_allocator`. Eliminate `json_tiers_array_contains` and `json_value`.
   - **Verification**: Run `odin test src/hub/service/agent`.

---

### Phase 2: Transport & RPC Boundary Layers (P1)

1. **Phase 2.1: File System Command & Result Modernization**
   - **Target**: `src/bridge/fs_management.odin`.
   - **Action**: Define typed structs for `fs_read_file`, `fs_batch_write`, `fs_list_dir`. Marshal results directly with `json.marshal`.
   - **Verification**: Run `odin test src/bridge -test-name:fs_management`.

2. **Phase 2.2: Provider Store Profile Migration**
   - **Target**: `src/bridge/provider_store.odin`.
   - **Action**: Replace 30+ `bridge_provider_json_extract_*` calls with single `json.unmarshal` into `Provider_Override_Config`.
   - **Verification**: Run `odin test src/bridge -test-name:provider_store`.

3. **Phase 2.3: Bridge VCS API Command Refactoring**
   - **Target**: `src/bridge/vcs_api.odin`.
   - **Action**: Unify 15 VCS command handlers with typed parameter and result structs.
   - **Verification**: Run `odin test src/bridge -test-name:vcs_api`.

4. **Phase 2.4: Hub Taskchain Wire Handlers & Query Matching**
   - **Target**: `src/hub/transport/http/taskchain_handlers.odin`.
   - **Action**: Use typed `Chain_List_Item_Wire` structs. Parse `assignee_ref_json` into `Actor_Ref` before checking query filters.
   - **Verification**: Run `odin test src/hub/transport/http -test-name:taskchain`.

5. **Phase 2.5: Bridge Update Catalog Manifest**
   - **Target**: `src/hub/service/bridge/bridge_update_catalog.odin`.
   - **Action**: Parse catalog JSON into `Bridge_Update_Catalog_Data`.
   - **Verification**: Run `odin test src/hub/service/bridge`.

6. **Phase 2.6: Router Envelope Payloads**
   - **Target**: `src/lib/router_envelope/payloads.odin`.
   - **Action**: Add `json:"..."` tags to `Message_Send_Payload` and use `json.unmarshal`.
   - **Verification**: Run `odin test src/lib/router_envelope`.

---

### Phase 3: CLI & Tooling Cleanup (P2)

1. **Phase 3.1: CLI Task Creation Output Parser**
   - **Target**: `src/ctl/tasks.odin`.
   - **Action**: Unmarshal task creation responses into a typed `Task_Created_Response` struct, removing hardcoded offset slicing.
   - **Verification**: Run `odin test src/ctl`.

2. **Phase 3.2: CLI Ad-Hoc Builder Deprecation**
   - **Target**: `src/ctl/jsonx.odin`.
   - **Action**: Deprecate `json_kv` and `json_object` in favor of typed request structs.
   - **Verification**: Run `odin build src/ctl`.

---

## 8. Conclusion

Direct JSON string manipulation in Odin was originally adopted as a perceived optimization to avoid DOM allocation overhead. However, the resulting codebase ended up paying higher performance and reliability penalties:
- Multiple repeated parsing passes per message via ad-hoc helpers.
- Critical production bugs like JIT assignment failures caused by key-order sensitivity.
- Potential security vulnerabilities in authentication extraction.
- Hand-rolled lexers that compromise data fidelity.

By following the roadmap outlined above and leveraging `core:encoding/json` with `context.temp_allocator`, Heimdall can eliminate this entire class of bugs, improve throughput, and guarantee clean memory semantics.
