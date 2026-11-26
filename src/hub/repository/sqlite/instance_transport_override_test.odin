package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// 263: agent_instances.runtime_transport_override (per-instance PTY/ACP choice)
// defaults to '' for existing rows, is read by instance lookups and is written
// only by the reconfiguration commit trigger from $.destination.

@(private = "file")
ito_source :: proc() -> domain.Instance_Configuration {
	return {bridge_id = "ito_bridge", provider = "codex", provider_profile = "codex", model = "gpt-6.1-sol", runtime_transport = "pty"}
}

@(private = "file")
ito_op :: proc(key: string, destination: domain.Instance_Configuration) -> domain.Instance_Reconfiguration {
	return {operation_id = key, owner_user_id = "owner", agent_instance_id = "ito_inst", conversation_id = "ito_chat", actor_user_id = "owner", idempotency_key = key, revision = 1, phase = .Prepared, source = ito_source(), destination = destination, stop_command_id = "stop", launch_command_id = "launch", launch_epoch = "epoch", created_at = "now", updated_at = "now"}
}

// Prepared -> Stopping -> Source_Stopped -> Launching (the commit trigger).
@(private = "file")
ito_commit :: proc(t: ^testing.T, repo: ^iface.Agent_Repository, op: domain.Instance_Reconfiguration) -> bool {
	op := op
	stored, began, err := iface.instance_reconfiguration_begin(repo, op)
	if !testing.expect(t, began, err.message) do return false
	domain.instance_reconfiguration_destroy(&stored)
	op.phase = .Stopping; op.revision = 2
	step, ok, step_err := iface.instance_reconfiguration_advance(repo, op, 1)
	if !testing.expect(t, ok, step_err.message) do return false
	domain.instance_reconfiguration_destroy(&step)
	op.phase = .Source_Stopped; op.source_stopped = true; op.revision = 3
	step, ok, step_err = iface.instance_reconfiguration_advance(repo, op, 2)
	if !testing.expect(t, ok, step_err.message) do return false
	domain.instance_reconfiguration_destroy(&step)
	op.phase = .Launching; op.destination_committed = true; op.revision = 4
	step, ok, step_err = iface.instance_reconfiguration_advance(repo, op, 3)
	if !testing.expect(t, ok, step_err.message) do return false
	domain.instance_reconfiguration_destroy(&step)
	op.phase = .Ready; op.revision = 5
	step, ok, step_err = iface.instance_reconfiguration_advance(repo, op, 4)
	if !testing.expect(t, ok, step_err.message) do return false
	domain.instance_reconfiguration_destroy(&step)
	return true
}

// The override is a static literal; the resolved transport is cloned out.
@(private = "file")
ito_override :: proc(t: ^testing.T, repo: ^iface.Agent_Repository) -> (string, int, string) {
	inst, found, err := iface.agent_get_instance(repo, "ito_inst")
	if !testing.expect(t, found, err.message) do return "<missing>", -1, ""
	defer domain.agent_instance_destroy(&inst)
	return inst.runtime_transport_override, inst.configuration_revision, strings.clone(inst.runtime_transport, context.temp_allocator)
}

@(test)
test_instance_transport_override_migration_and_commit :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "263_instance_runtime_transport_override.sql")
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, exec(&conn, "INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,provider,provider_profile,model,conversation_id,runtime_status,runtime_transport,created_at,updated_at) VALUES('ito_inst','owner','agent','ito_bridge','codex','codex','gpt-6.1-sol','ito_chat','running','pty','','');"))
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, sqlite_trigger_mentions(&conn, "instance_reconfiguration_commit", "runtime_transport_override"), "commit applies the transport choice")
	testing.expect(t, sqlite_trigger_mentions(&conn, "instance_reconfiguration_commit", "permission_mode"), "commit still applies the permission mode")
	testing.expect(t, !exec(&conn, "UPDATE agent_instances SET runtime_transport_override='ssh';"), "CHECK rejects unknown transports")
	// Re-running is a no-op (ledger + completion guard).
	migrated, err = run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	embedded := migration_sql("263_instance_runtime_transport_override.sql", ""); defer delete(embedded)
	disk := migration_sql("263_instance_runtime_transport_override.sql", "src/hub/repository/sqlite/migrations"); defer delete(disk)
	testing.expect_value(t, embedded, disk)

	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)
	override, revision, transport := ito_override(t, &repo)
	testing.expect_value(t, override, "")

	// An explicit destination choice is committed with the move.
	acp := ito_source(); acp.runtime_transport = "acp"; acp.runtime_transport_override = "acp"
	if !ito_commit(t, &repo, ito_op("ito_acp", acp)) do return
	override, revision, transport = ito_override(t, &repo)
	testing.expect_value(t, override, "acp")
	testing.expect_value(t, revision, 1)
	testing.expect_value(t, transport, "acp")

	// A destination that clears the choice ('') unpins the instance.
	cleared := ito_source(); cleared.runtime_transport_override = ""
	source_acp := ito_source(); source_acp.runtime_transport = "acp"; source_acp.runtime_transport_override = "acp"
	clear_op := ito_op("ito_clear", cleared); clear_op.source = source_acp; clear_op.expected_revision = 1
	if !ito_commit(t, &repo, clear_op) do return
	override, revision, transport = ito_override(t, &repo)
	testing.expect_value(t, override, "")
	testing.expect_value(t, revision, 2)
	testing.expect_value(t, transport, "pty")

	// A payload persisted before 263 has no key: the commit keeps the stored value.
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_transport_override='pty';"))
	legacy := ito_op("ito_legacy", ito_source()); legacy.expected_revision = 2
	stored, began, begin_err := iface.instance_reconfiguration_begin(&repo, legacy)
	if !testing.expect(t, began, begin_err.message) do return
	domain.instance_reconfiguration_destroy(&stored)
	testing.expect(t, exec(&conn, "UPDATE instance_reconfigurations SET phase='source_stopped' WHERE operation_id='ito_legacy';"))
	testing.expect(t, exec(&conn, `UPDATE instance_reconfigurations SET phase='launching', payload_json=json_remove(json_set(payload_json,'$.source_stopped',json('true'),'$.destination_committed',json('true')),'$.destination.runtime_transport_override') WHERE operation_id='ito_legacy';`))
	override, revision, transport = ito_override(t, &repo)
	testing.expect_value(t, override, "pty")
	testing.expect_value(t, revision, 3)
	_ = transport
}
