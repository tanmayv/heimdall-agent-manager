#!/usr/bin/env bash
# Integration tests for Feature X:
#   - role_hint-based agent filtering (GET /agents?role_hint=)
#   - role_hint wiring into task routing (agents_first_by_role_hint)
#   - inline agent update via POST /agents/update
#   - GET /agents/templates returns role_hint field on built-in templates
#
# Usage: ./tests/test_feature_x.sh [daemon_url]
# Requires: curl, a running ham-daemon

set -euo pipefail

DAEMON="${1:-http://127.0.0.1:49322}"
# Agent token for authenticated endpoints (projects/create, tasks/*, memory/*)
AGENT_TOKEN="${AGENT_TOKEN:-agt_dadbba5b331bad510f62f454ef61c9f3e8fdf5091752f66012e83a39b67adac8}"
PASS=0
FAIL=0
# Unique suffix per run to avoid 409 conflicts with still-connected agents
RUN_ID="$(date +%s)"
TEST_AGENT_ID="featurex${RUN_ID}@test-suite"

# --- helpers ---

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

get()      { curl -sf -X GET  "$DAEMON$1"; }
post()     { curl -sf -X POST "$DAEMON$1" -H "Content-Type: application/json" -d "$2"; }
# post_raw: like post but doesn't fail on HTTP 4xx/5xx (used when we expect a non-2xx but need the side-effect)
post_raw() { curl -s  -X POST "$DAEMON$1" -H "Content-Type: application/json" -d "$2"; }

assert_ok() {
  local label="$1" body="$2"
  if echo "$body" | grep -q '"ok":true'; then pass "$label"
  else fail "$label" "$body"; fi
}

assert_field() {
  local label="$1" body="$2" field="$3" want="$4"
  if echo "$body" | grep -q "\"$field\":\"$want\""; then pass "$label"
  else fail "$label" "expected $field=$want in: $body"; fi
}

assert_contains() {
  local label="$1" body="$2" needle="$3"
  if echo "$body" | grep -qF "$needle"; then pass "$label"
  else fail "$label" "expected '$needle' in: $body"; fi
}

assert_not_contains() {
  local label="$1" body="$2" needle="$3"
  if ! echo "$body" | grep -qF "$needle"; then pass "$label"
  else fail "$label" "did not expect '$needle' in: $body"; fi
}

# --- health check ---

HEALTH=$(get /health)
if ! echo "$HEALTH" | grep -q '"ok":true'; then
  echo "ERROR: daemon not reachable at $DAEMON"
  exit 1
fi
echo "daemon ok: $DAEMON"
echo ""

# --- pre-test cleanup (handles partial runs from previous invocations) ---
post /agents/templates/archive '{"template_id":"test-tester"}' >/dev/null 2>&1 || true
post /agents/templates/archive '{"template_id":"test-hint-check"}' >/dev/null 2>&1 || true

# ============================================================
# 1. GET /agents/templates — built-in templates carry role_hint
#    Built-ins appear as a fallback only when no persisted templates
#    exist. When templates are present, role_hint values are stored
#    per-record. We create a template to verify the field is persisted.
# ============================================================

TEMPLATES=$(get /agents/templates)
assert_ok "templates endpoint returns ok" "$TEMPLATES"

# When no custom templates exist (built-in fallback), all three role_hints appear.
# When custom templates exist, each carries its own role_hint.
# Either way, the templates response must carry the role_hint field.
assert_contains "templates response includes role_hint field" "$TEMPLATES" '"role_hint":'

# Create a test template with a known role_hint to verify persistence of the field.
TMPL_WITH_HINT=$(post /agents/templates/create '{
  "template_id": "test-hint-check",
  "display_name": "Hint Check",
  "role_hint": "verifier",
  "default_provider_profile": "pi",
  "author": "test_script"
}')
assert_ok "create template with role_hint=verifier" "$TMPL_WITH_HINT"
assert_field "created template stores role_hint correctly" "$TMPL_WITH_HINT" "role_hint" "verifier"

SHOW_HINT=$(post /agents/templates/show '{"template_id":"test-hint-check"}')
assert_ok "show template with role_hint" "$SHOW_HINT"
assert_field "role_hint persists across show" "$SHOW_HINT" "role_hint" "verifier"

# Cleanup this extra template before continuing
post /agents/templates/archive '{"template_id":"test-hint-check"}' >/dev/null 2>&1 || true

# ============================================================
# 2. GET /agents?role_hint= — filtering by role_hint
# ============================================================

# With no persisted agents the filtered list should be empty for all role_hints
CODER_AGENTS=$(get "/agents?role_hint=coder")
assert_ok "GET /agents?role_hint=coder returns ok" "$CODER_AGENTS"
assert_contains "role_hint filter response has agents array" "$CODER_AGENTS" '"agents":'

REVIEWER_AGENTS=$(get "/agents?role_hint=reviewer")
assert_ok "GET /agents?role_hint=reviewer returns ok" "$REVIEWER_AGENTS"

UNKNOWN_ROLE=$(get "/agents?role_hint=nonexistent_role")
assert_ok "GET /agents?role_hint=<unknown> returns ok (empty list)" "$UNKNOWN_ROLE"
assert_contains "unknown role_hint returns empty agents list" "$UNKNOWN_ROLE" '"agents":[]'

# Without role_hint filter, registry agents still appear
ALL_AGENTS=$(get "/agents")
assert_ok "GET /agents (no filter) returns ok" "$ALL_AGENTS"

# ============================================================
# 3. Create a custom template with role_hint, then filter it
# ============================================================

CREATE_TMPL=$(post /agents/templates/create '{
  "template_id": "test-tester",
  "display_name": "Test Tester",
  "role_hint": "tester",
  "default_provider_profile": "pi",
  "author": "test_script"
}')
assert_ok "create template with custom role_hint=tester" "$CREATE_TMPL"
assert_field "created template has role_hint=tester" "$CREATE_TMPL" "role_hint" "tester"

# Show the template to verify persistence
SHOW_TMPL=$(post /agents/templates/show '{"template_id":"test-tester"}')
assert_ok "show template returns ok" "$SHOW_TMPL"
assert_field "persisted template has correct role_hint" "$SHOW_TMPL" "role_hint" "tester"

# ============================================================
# 4. Register an agent instance using the new template,
#    then verify role_hint filtering includes it
# ============================================================

# POST /agents/start persists the agent record in the daemon store (required before /agents/update).
# The wrapper launch will fail on this platform (binary is macOS arm64) and return 500,
# but the store write happens first — we use post_raw to tolerate the 500 and continue.
START=$(post_raw /agents/start "{\"agent_instance_id\":\"$TEST_AGENT_ID\",\"display_name\":\"Feature X Tester\",\"template_id\":\"test-tester\",\"provider_profile\":\"pi\"}")
if echo "$START" | grep -qF "\"agent_instance_id\":\"$TEST_AGENT_ID\"" || echo "$START" | grep -qF '"failed to start wrapper"'; then
  pass "agent record created via /agents/start (wrapper launch expected to fail on this platform)"
else
  fail "agent record creation via /agents/start" "$START"
fi

# Persist it as an agent record linked to the tester template via inline edit
UPDATE=$(post /agents/update "{\"agent_instance_id\":\"$TEST_AGENT_ID\",\"display_name\":\"Feature X Tester\",\"template_id\":\"test-tester\",\"provider_profile\":\"pi\"}")
assert_ok "POST /agents/update sets template_id (inline edit form)" "$UPDATE"
assert_field "updated agent has correct template_id" "$UPDATE" "template_id" "test-tester"

# Now the role_hint filter should include our agent (template role_hint=tester)
TESTER_AGENTS=$(get "/agents?role_hint=tester")
assert_ok "GET /agents?role_hint=tester after update" "$TESTER_AGENTS"
assert_contains "filtered agents include our tester agent" "$TESTER_AGENTS" "$TEST_AGENT_ID"

# Agents with a different role_hint must NOT appear in the tester filter
CODER_AFTER=$(get "/agents?role_hint=coder")
assert_ok "coder filter still returns ok" "$CODER_AFTER"
if echo "$CODER_AFTER" | grep -qF "$TEST_AGENT_ID"; then
  fail "coder filter must not include agent with role_hint=tester" "$CODER_AFTER"
else
  pass "coder filter excludes agent with different role_hint"
fi

# ============================================================
# 5. POST /agents/update — inline edit: change display name
# ============================================================

RENAME=$(post /agents/update "{\"agent_instance_id\":\"$TEST_AGENT_ID\",\"display_name\":\"Renamed Tester\"}")
assert_ok "inline edit: update display_name" "$RENAME"
assert_field "display_name updated correctly" "$RENAME" "display_name" "Renamed Tester"

# ============================================================
# 6. POST /agents/update — inline edit: change provider_profile
# ============================================================

REPROVIDER=$(post /agents/update "{\"agent_instance_id\":\"$TEST_AGENT_ID\",\"provider_profile\":\"local\"}")
assert_ok "inline edit: update provider_profile" "$REPROVIDER"
assert_field "provider_profile updated correctly" "$REPROVIDER" "provider_profile" "local"

# ============================================================
# 7. Project-scoped role_hint filter
# ============================================================

PROJ=$(post /projects/create "{\"agent_token\":\"$AGENT_TOKEN\",\"name\":\"Test Project X\",\"description\":\"role_hint test project\"}")
assert_ok "create test project" "$PROJ"

PROJ_ID=$(echo "$PROJ" | sed -n 's/.*"project_id":"\([^"]*\)".*/\1/p')
if [ -z "$PROJ_ID" ]; then
  fail "could not extract project_id from: $PROJ"
else
  pass "extracted project_id: $PROJ_ID"

  ASSOC=$(post /agents/associate "{\"agent_instance_id\":\"$TEST_AGENT_ID\",\"project_id\":\"$PROJ_ID\"}")
  assert_ok "associate agent with project" "$ASSOC"

  PROJ_AGENTS=$(get "/agents?role_hint=tester&project_id=$PROJ_ID")
  assert_ok "GET /agents?role_hint=tester&project_id= returns ok" "$PROJ_AGENTS"
  assert_contains "project-scoped tester filter includes agent" "$PROJ_AGENTS" "$TEST_AGENT_ID"

  PROJ_AGENTS_OTHER=$(get "/agents?role_hint=tester&project_id=proj_nonexistent")
  assert_ok "GET /agents with wrong project_id returns ok" "$PROJ_AGENTS_OTHER"
  assert_contains "wrong project_id returns empty agents list" "$PROJ_AGENTS_OTHER" '"agents":[]'
fi

# ============================================================
# 8. Archive custom template — cleanup
# ============================================================

ARCHIVE=$(post /agents/templates/archive '{"template_id":"test-tester"}')
assert_ok "archive test-tester template (cleanup)" "$ARCHIVE"

# ============================================================
# Cleanup
# ============================================================
echo "=== CLEANUP: Wiping test records to prevent database pollution ==="

# 1. Archive the test agent via REST API
echo "[*] Archiving test agent via REST API..."
post /agents/archive "{\"agent_instance_id\":\"$TEST_AGENT_ID\"}" >/dev/null || true

# 2. Delete tasks, chains, and participants from SQLite database
DB_PATH="$HOME/.local/share/heimdall/tasks/task.db"
if [ -f "$DB_PATH" ] && [ -n "${PROJ_ID:-}" ]; then
  echo "[*] Wiping tasks, chains, votes, comments, and participants from SQLite..."
  sqlite3 "$DB_PATH" <<EOF
DELETE FROM task_participants WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = '$PROJ_ID');
DELETE FROM task_lgtm_votes WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = '$PROJ_ID');
DELETE FROM task_comments WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = '$PROJ_ID');
DELETE FROM tasks WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = '$PROJ_ID');
DELETE FROM task_chains WHERE project_id = '$PROJ_ID';
EOF
fi

# 3. Clean up flat files (JSONL event logs) on disk for next daemon start
PROJECT_LOG="$HOME/.local/share/heimdall/projects/events.jsonl"
if [ -f "$PROJECT_LOG" ] && [ -n "${PROJ_ID:-}" ]; then
  echo "[*] Removing test project events from flat file logs..."
  grep -v "\"project_id\":\"$PROJ_ID\"" "$PROJECT_LOG" > "${PROJECT_LOG}.tmp" || true
  mv "${PROJECT_LOG}.tmp" "$PROJECT_LOG"
fi

AGENT_LOG="$HOME/.local/share/heimdall/agents/instance-events.jsonl"
if [ -f "$AGENT_LOG" ]; then
  echo "[*] Removing test agent events from flat file logs..."
  grep -v "\"agent_instance_id\":\"$TEST_AGENT_ID\"" "$AGENT_LOG" > "${AGENT_LOG}.tmp" || true
  mv "${AGENT_LOG}.tmp" "$AGENT_LOG"
fi

echo "[+] Cleanup completed successfully!"
echo ""

# ============================================================
# Summary
# ============================================================

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
