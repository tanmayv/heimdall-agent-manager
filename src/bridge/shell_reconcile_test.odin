package main

import "core:strings"
import "core:testing"

@(test)
test_shell_reconcile_extract_active_ids_hub_envelope :: proc(t: ^testing.T) {
	json_payload := `{"data":{"ok":true,"sessions":[` +
		`{"session_id":"sh_active_1","status":"running"},` +
		`{"session_id":"sh_active_2","status":"starting"},` +
		`{"session_id":"sh_stopped","status":"stopped"},` +
		`{"session_id":"sh_killed","status":"killed"},` +
		`{"session_id":"sh_failed","status":"failed"},` +
		`{"session_id":"sh_active_1","status":"running"}` + // duplicate test
		`],"next_cursor":"","has_more":false},"meta":{}}`

	active_ids, ok := bridge_shell_extract_active_ids(json_payload)
	testing.expect(t, ok, "extraction should succeed on valid Hub payload")
	defer bridge_shell_delete_active_ids(&active_ids)

	testing.expect(t, "sh_active_1" in active_ids, "sh_active_1 (running) should be active")
	testing.expect(t, "sh_active_2" in active_ids, "sh_active_2 (starting) should be active")
	testing.expect(t, !("sh_stopped" in active_ids), "sh_stopped should not be active")
	testing.expect(t, !("sh_killed" in active_ids), "sh_killed should not be active")
	testing.expect(t, !("sh_failed" in active_ids), "sh_failed should not be active")
	testing.expect(t, len(active_ids) == 2, "expected exactly 2 unique active IDs")
}

@(test)
test_shell_reconcile_extract_active_ids_alternative_envelopes :: proc(t: ^testing.T) {
	// Direct sessions object
	payload_sessions := `{"sessions":[{"session_id":"sh_sess_1","status":"running"}]}`
	ids1, ok1 := bridge_shell_extract_active_ids(payload_sessions)
	testing.expect(t, ok1, "direct sessions envelope should succeed")
	defer bridge_shell_delete_active_ids(&ids1)
	testing.expect(t, "sh_sess_1" in ids1, "sh_sess_1 should be extracted")

	// Direct data array
	payload_data_arr := `{"data":[{"session_id":"sh_data_1","status":"running"}]}`
	ids2, ok2 := bridge_shell_extract_active_ids(payload_data_arr)
	testing.expect(t, ok2, "direct data array should succeed")
	defer bridge_shell_delete_active_ids(&ids2)
	testing.expect(t, "sh_data_1" in ids2, "sh_data_1 should be extracted")

	// Raw array
	payload_raw_arr := `[{"session_id":"sh_raw_1","status":"running"}]`
	ids3, ok3 := bridge_shell_extract_active_ids(payload_raw_arr)
	testing.expect(t, ok3, "raw array should succeed")
	defer bridge_shell_delete_active_ids(&ids3)
	testing.expect(t, "sh_raw_1" in ids3, "sh_raw_1 should be extracted")
}

@(test)
test_shell_reconcile_extract_active_ids_invalid_json :: proc(t: ^testing.T) {
	_, ok1 := bridge_shell_extract_active_ids("not valid json")
	testing.expect(t, !ok1, "invalid json should fail safely")

	_, ok2 := bridge_shell_extract_active_ids(`{"ok":false}`)
	testing.expect(t, !ok2, "missing sessions/data should fail safely")

	_, ok3 := bridge_shell_extract_active_ids(`{"data":"not an array or object"}`)
	testing.expect(t, !ok3, "non-array non-object data should fail safely")
}

@(test)
test_shell_reconcile_filter_orphans :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)
	active_ids["sh_active_1"] = true
	active_ids["sh_active_2"] = true

	pty_agents := []Pty_Host_Agent_Info{
		// Agent instance sessions: MUST be ignored even if alive (handled by agent reaper)
		{instance_id = "inst_agent_1", alive = true},
		{instance_id = "inst_worker_42", alive = true},
		// Non-sh prefixes: MUST be ignored
		{instance_id = "sess_custom", alive = true},
		// Dead shell sessions: MUST be ignored
		{instance_id = "sh_dead_orphan", alive = false},
		{instance_id = "sh_dead_active", alive = false},
		// Active shells in Hub: MUST NOT be reaped
		{instance_id = "sh_active_1", alive = true},
		{instance_id = "sh_active_2", alive = true},
		// Orphans (live pty sessions starting with sh_ not in Hub active set): MUST be returned
		{instance_id = "sh_orphan_1", alive = true},
		{instance_id = "sh_orphan_2", alive = true},
	}

	orphans := bridge_shell_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 2, "expected exactly 2 orphans")

	has_orphan_1 := false
	has_orphan_2 := false
	for o in orphans {
		if o == "sh_orphan_1" do has_orphan_1 = true
		if o == "sh_orphan_2" do has_orphan_2 = true
		testing.expect(t, strings.has_prefix(o, "sh_"), "all orphans must have sh_ prefix")
		testing.expect(t, !strings.has_prefix(o, "inst_"), "orphans must never have inst_ prefix")
	}
	testing.expect(t, has_orphan_1, "sh_orphan_1 must be in orphans")
	testing.expect(t, has_orphan_2, "sh_orphan_2 must be in orphans")
}

@(test)
test_shell_reconcile_empty_active_hub :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_agent_foo", alive = true},
		{instance_id = "sh_reap_orphan", alive = true},
	}

	orphans := bridge_shell_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 1, "expected 1 orphan when hub active set is empty")
	testing.expect(t, orphans[0] == "sh_reap_orphan", "expected sh_reap_orphan to be reaped")
}

@(test)
test_shell_reconcile_all_active_no_orphans :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)
	active_ids["sh_1"] = true
	active_ids["sh_2"] = true

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_1", alive = true},
		{instance_id = "sh_1", alive = true},
		{instance_id = "sh_2", alive = true},
	}

	orphans := bridge_shell_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 0, "expected 0 orphans when all shell sessions are active in hub")
}
