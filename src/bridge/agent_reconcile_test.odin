package main

import "core:strings"
import "core:testing"

@(test)
test_agent_reconcile_extract_active_ids :: proc(t: ^testing.T) {
	json_payload := `{"ok":true,"data":[` +
		`{"agent_instance_id":"inst_active_1","runtime_status":"running"},` +
		`{"agent_instance_id":"inst_active_2","runtime_status":"launching"},` +
		`{"agent_instance_id":"inst_active_3","runtime_status":"starting"},` +
		`{"agent_instance_id":"inst_stopped","runtime_status":"stopped"},` +
		`{"agent_instance_id":"inst_failed","runtime_status":"failed"},` +
		`{"agent_instance_id":"inst_unreach","runtime_status":"unreachable"},` +
		`{"agent_instance_id":"inst_blocked","runtime_status":"blocked"},` +
		`{"agent_instance_id":"inst_active_1","runtime_status":"running"}` + // duplicate test
		`]}`

	active_ids, ok := bridge_agent_instance_extract_active_ids(json_payload)
	testing.expect(t, ok, "extraction should succeed on valid payload")
	defer bridge_agent_instance_delete_active_ids(&active_ids)

	testing.expect(t, "inst_active_1" in active_ids, "inst_active_1 (running) should be active")
	testing.expect(t, "inst_active_2" in active_ids, "inst_active_2 (launching) should be active")
	testing.expect(t, "inst_active_3" in active_ids, "inst_active_3 (starting) should be active")
	testing.expect(t, !("inst_stopped" in active_ids), "inst_stopped should not be active")
	testing.expect(t, !("inst_failed" in active_ids), "inst_failed should not be active")
	testing.expect(t, !("inst_unreach" in active_ids), "inst_unreach should not be active")
	testing.expect(t, !("inst_blocked" in active_ids), "inst_blocked should not be active")
	testing.expect(t, len(active_ids) == 3, "expected exactly 3 unique active IDs")
}

@(test)
test_agent_reconcile_extract_active_ids_invalid_json :: proc(t: ^testing.T) {
	_, ok1 := bridge_agent_instance_extract_active_ids("not valid json")
	testing.expect(t, !ok1, "invalid json should fail safely")

	_, ok2 := bridge_agent_instance_extract_active_ids(`{"ok":false}`)
	testing.expect(t, !ok2, "missing data should fail safely")

	_, ok3 := bridge_agent_instance_extract_active_ids(`{"data":"not an array"}`)
	testing.expect(t, !ok3, "non-array data should fail safely")
}

@(test)
test_agent_reconcile_filter_orphans :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)
	active_ids["inst_live_1"] = true
	active_ids["inst_live_2"] = true

	pty_agents := []Pty_Host_Agent_Info{
		// Shell sessions: MUST be ignored even if alive
		{instance_id = "sh_bash_1", alive = true},
		{instance_id = "sh_dev_server", alive = true},
		// Non-inst prefixes: MUST be ignored
		{instance_id = "sess_42", alive = true},
		// Dead instances: MUST be ignored
		{instance_id = "inst_dead_orphan", alive = false},
		{instance_id = "inst_dead_active", alive = false},
		// Active instances in Hub: MUST NOT be reaped
		{instance_id = "inst_live_1", alive = true},
		{instance_id = "inst_live_2", alive = true},
		// Orphans (live pty instances starting with inst_ not in Hub active set): MUST be returned
		{instance_id = "inst_orphan_1", alive = true},
		{instance_id = "inst_orphan_2", alive = true},
	}

	orphans := bridge_agent_instance_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 2, "expected exactly 2 orphans")

	has_orphan_1 := false
	has_orphan_2 := false
	for o in orphans {
		if o == "inst_orphan_1" do has_orphan_1 = true
		if o == "inst_orphan_2" do has_orphan_2 = true
		testing.expect(t, strings.has_prefix(o, "inst_"), "all orphans must have inst_ prefix")
		testing.expect(t, !strings.has_prefix(o, "sh_"), "orphans must never have sh_ prefix")
	}
	testing.expect(t, has_orphan_1, "inst_orphan_1 must be in orphans")
	testing.expect(t, has_orphan_2, "inst_orphan_2 must be in orphans")
}

@(test)
test_agent_reconcile_empty_active_hub :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "sh_terminal", alive = true},
		{instance_id = "inst_reap_me", alive = true},
	}

	orphans := bridge_agent_instance_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 1, "expected 1 orphan when hub is empty")
	testing.expect(t, orphans[0] == "inst_reap_me", "expected inst_reap_me to be reaped")
}

@(test)
test_agent_reconcile_all_active_no_orphans :: proc(t: ^testing.T) {
	active_ids := make(map[string]bool)
	defer delete(active_ids)
	active_ids["inst_running_1"] = true
	active_ids["inst_running_2"] = true

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "sh_1", alive = true},
		{instance_id = "inst_running_1", alive = true},
		{instance_id = "inst_running_2", alive = true},
	}

	orphans := bridge_agent_instance_find_orphans(pty_agents, active_ids)
	defer {
		for id in orphans do delete(id)
		delete(orphans)
	}

	testing.expect(t, len(orphans) == 0, "expected 0 orphans when all instances active")
}

@(test)
test_agent_reconcile_extract_hub_instances :: proc(t: ^testing.T) {
	json_payload := `{"ok":true,"data":[` +
		`{"agent_instance_id":"inst_1","runtime_status":"running"},` +
		`{"agent_instance_id":"inst_2","runtime_status":"stopped"},` +
		`{"agent_instance_id":"inst_3","runtime_status":"unreachable"},` +
		`{"agent_instance_id":"inst_4","runtime_status":"starting"}` +
		`]}`

	hub_instances, ok := bridge_agent_instance_extract_hub_instances(json_payload)
	testing.expect(t, ok, "extraction should succeed")
	defer bridge_agent_instance_delete_hub_instances(&hub_instances)

	testing.expect_value(t, len(hub_instances), 4)
	testing.expect_value(t, hub_instances["inst_1"], "running")
	testing.expect_value(t, hub_instances["inst_2"], "stopped")
	testing.expect_value(t, hub_instances["inst_3"], "unreachable")
	testing.expect_value(t, hub_instances["inst_4"], "starting")
}

@(test)
test_agent_reconcile_surviving_pty_preserved_not_stopped :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_alive_running"] = "running"
	hub_instances["inst_alive_unreach"] = "unreachable"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_alive_running", alive = true},
		{instance_id = "inst_alive_unreach", alive = true},
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	testing.expect_value(t, len(plan.to_preserve), 2)
	testing.expect_value(t, len(plan.to_reap), 0)

	has_running := false
	has_unreach := false
	for p in plan.to_preserve {
		if p == "inst_alive_running" do has_running = true
		if p == "inst_alive_unreach" do has_unreach = true
	}
	testing.expect(t, has_running, "inst_alive_running must be preserved")
	testing.expect(t, has_unreach, "inst_alive_unreach must be preserved")
}

@(test)
test_agent_reconcile_stopped_instance_reaped :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_user_stopped"] = "stopped"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_user_stopped", alive = true},
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	testing.expect_value(t, len(plan.to_preserve), 0)
	testing.expect_value(t, len(plan.to_reap), 1)
	testing.expect_value(t, plan.to_reap[0], "inst_user_stopped")
	testing.expect_value(t, len(plan.to_push_terminal), 1)
	testing.expect_value(t, plan.to_push_terminal[0], "inst_user_stopped")
}

@(test)
test_agent_reconcile_dead_hub_instance_pushed_terminal :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_dead_on_pty"] = "running"
	hub_instances["inst_absent_on_pty"] = "running"
	hub_instances["inst_already_stopped"] = "stopped"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "inst_dead_on_pty", alive = false},
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	testing.expect_value(t, len(plan.to_preserve), 0)
	testing.expect_value(t, len(plan.to_reap), 0)
	testing.expect_value(t, len(plan.to_push_terminal), 2)

	has_dead := false
	has_absent := false
	for term in plan.to_push_terminal {
		if term == "inst_dead_on_pty" do has_dead = true
		if term == "inst_absent_on_pty" do has_absent = true
	}
	testing.expect(t, has_dead, "inst_dead_on_pty must be pushed terminal")
	testing.expect(t, has_absent, "inst_absent_on_pty must be pushed terminal")
}

@(test)
test_agent_reconcile_bidirectional_convergence :: proc(t: ^testing.T) {
	hub_instances := make(map[string]string)
	defer delete(hub_instances)
	hub_instances["inst_keep"] = "running"
	hub_instances["inst_reap"] = "stopped"
	hub_instances["inst_vanished"] = "running"
	hub_instances["inst_idle_stopped"] = "stopped"

	pty_agents := []Pty_Host_Agent_Info{
		{instance_id = "sh_bash_1", alive = true},              // shell session -> ignored
		{instance_id = "other_prefix", alive = true},           // invalid prefix -> ignored
		{instance_id = "inst_keep", alive = true},              // alive, not stopped -> preserve
		{instance_id = "inst_reap", alive = true},              // alive, user stopped -> reap + push terminal
		{instance_id = "inst_dead", alive = false},             // dead -> ignored for reap/preserve
	}

	plan := bridge_agent_instance_compute_reconcile_plan(pty_agents, hub_instances)
	defer bridge_agent_instance_plan_delete(&plan)

	// Preserved: inst_keep
	testing.expect_value(t, len(plan.to_preserve), 1)
	testing.expect_value(t, plan.to_preserve[0], "inst_keep")

	// Reaped: inst_reap
	testing.expect_value(t, len(plan.to_reap), 1)
	testing.expect_value(t, plan.to_reap[0], "inst_reap")

	// Pushed terminal: inst_reap (reaped) and inst_vanished (in hub as running, absent physically)
	testing.expect_value(t, len(plan.to_push_terminal), 2)
	has_reap_term := false
	has_vanished_term := false
	for term in plan.to_push_terminal {
		if term == "inst_reap" do has_reap_term = true
		if term == "inst_vanished" do has_vanished_term = true
	}
	testing.expect(t, has_reap_term, "inst_reap must be in to_push_terminal")
	testing.expect(t, has_vanished_term, "inst_vanished must be in to_push_terminal")
}

