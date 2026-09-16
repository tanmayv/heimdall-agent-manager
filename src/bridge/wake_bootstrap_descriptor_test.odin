package main

import "core:strings"
import "core:testing"

// REQ-37: the wake_agent / scheduler launch paths must carry the full descriptor so
// bridge_bootstrap_descriptor_from_launch yields a non-empty agent_id — which is what
// routes the launch to the full agent-keyed template bootstrap instead of the
// header-only instance fallback (bridge_bootstrap_launch_materialize_run_dir refuses
// to launch when agent_id is empty).

@(test)
wake_launch_command_json_roundtrips_full_descriptor :: proc(t: ^testing.T) {
	cmd := bridge_wake_launch_command_json(
		"cmd_1", "inst_abc", "task_9", "reviewer", "pi", "smart",
		"agt_42", "coder", "chain_7", "Heimdall — Coordinator Session",
		"inst_coord", "proj_3", "/home/x/project",
	)
	defer delete(cmd)

	// The type must be a launch_agent whose payload carries every descriptor field.
	testing.expect(t, strings.contains(cmd, "\"type\":\"launch_agent\""))
	d := bridge_bootstrap_descriptor_from_launch(cmd)
	testing.expect_value(t, d.instance_id, "inst_abc")
	testing.expect_value(t, d.agent_id, "agt_42")
	testing.expect_value(t, d.agent_name, "coder")
	testing.expect_value(t, d.role, "reviewer")
	testing.expect_value(t, d.chain_id, "chain_7")
	testing.expect_value(t, d.chain_title, "Heimdall — Coordinator Session")
	testing.expect_value(t, d.coordinator_id, "inst_coord")
	testing.expect_value(t, d.project_id, "proj_3")
	testing.expect_value(t, d.project_path, "/home/x/project")
}

@(test)
wake_launch_command_json_escapes_free_text :: proc(t: ^testing.T) {
	// A chain title containing a double-quote must not break the JSON payload.
	cmd := bridge_wake_launch_command_json(
		"cmd_2", "inst_q", "", "worker", "", "",
		"agt_1", "coder", "chain_1", "Say \"hi\" now",
		"", "proj_1", "",
	)
	defer delete(cmd)
	d := bridge_bootstrap_descriptor_from_launch(cmd)
	testing.expect_value(t, d.agent_id, "agt_1")
	testing.expect_value(t, d.chain_title, "Say \"hi\" now")
}

@(test)
bare_launch_payload_leaves_agent_id_empty :: proc(t: ^testing.T) {
	// The pre-REQ-37 minimal payload (only agent_instance_id) is exactly what made the
	// bridge take the header-only fallback; document that it yields an empty agent_id
	// (which the launch guard now rejects rather than silently degrading).
	bare := "{\"type\":\"launch_agent\",\"command_id\":\"c\",\"payload\":{\"agent_instance_id\":\"inst_bare\"}}"
	d := bridge_bootstrap_descriptor_from_launch(bare)
	testing.expect_value(t, d.instance_id, "inst_bare")
	testing.expect_value(t, d.agent_id, "")
	// role degrades to worker (documented default), not empty.
	testing.expect_value(t, d.role, "worker")
}
