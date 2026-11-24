package actions

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"

@(test)
test_memory_approved_preset_matches_real_producer :: proc(t: ^testing.T) {
	action_test_case(t, memory_approved_scenario)
}
memory_approved_scenario :: proc(t: ^testing.T, f: ^Action_Test) {
	descriptor := event_descriptor_find("memory.state")
	if !testing.expect(t, descriptor != nil) do return
	testing.expect_value(t, descriptor.class, "state")
	testing.expect_value(t, descriptor.scope, "memory")
	testing.expect_value(t, len(descriptor.presets), 2)
	testing.expect_value(t, descriptor.presets[0].label, "Memory proposed")
	testing.expect_value(t, descriptor.presets[1].label, "Memory approved")
	svc := content.Content_Service{content=&f.repos.content, uow_factory=&f.factory, clock=&f.clock, ids=&f.ids}
	auth := contracts.Auth_Context{kind=.Session, user_id="owner"}
	m, ok, err := content.create_memory(&svc, auth, {type=.Habit, body="secret"})
	if !testing.expect(t, ok && err.code == .None) do return
	config := test_config(`{"event_type":"memory.state"}`)
	config["filter"] = test_config(descriptor.presets[1].filter_json)
	spec, compile_err := event_compile("owner", "action", "trigger", config, context.allocator)
	if !testing.expect_value(t, compile_err.code, domain.Error_Code.None) do return
	repo := &f.repos.actions
	testing.expect_value(t, repo.trigger_save(repo.ctx, {
		trigger_id="trigger", action_id="action", owner_user_id="owner", kind="event", enabled=true, rev=1,
		config_json=`{"event_type":"memory.state"}`,
		event_type=spec.event_type, subject_filter=spec.subject_filter, data_filter_json=spec.data_filter_json,
		updated_at="2026-01-01T00:00:00Z",
	}).code, domain.Error_Code.None)
	// Proposed does not match the approved preset.
	memory_preset_consume(t, f)
	testing.expect_value(t, len(action_test_rows(t, f)), 0)
	_, ok, err = content.approve_memory(&svc, auth, m.memory_id)
	testing.expect(t, ok && err.code == .None)
	memory_preset_consume(t, f)
	runs := action_test_rows(t, f)
	if !testing.expect_value(t, len(runs), 1) do return
	testing.expect_value(t, runs[0].event_type, "memory.state")
	testing.expect_value(t, runs[0].state, domain.ACTION_RUN_QUEUED)
	valid, reason := memory_preset_valid(t, f, runs[0])
	testing.expect(t, valid, reason)
	// A later status change supersedes a delayed approved run through generic heads.
	_, ok, err = content.archive_memory(&svc, auth, m.memory_id)
	testing.expect(t, ok && err.code == .None)
	valid, reason = memory_preset_valid(t, f, runs[0])
	testing.expect(t, !valid)
	testing.expect_value(t, reason, "superseded")
	memory_preset_consume(t, f)
	testing.expect_value(t, len(action_test_rows(t, f)), 1)
}
memory_preset_consume :: proc(t: ^testing.T, f: ^Action_Test) {
	uow, begun, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	row, found, err := uow.repos.event_outbox.next(uow.repos.event_outbox.ctx)
	testing.expect(t, found && err.code == .None)
	iface.unit_of_work_rollback(&uow)
	object := test_config(row.envelope_json)
	testing.expect(t, handle_message(&f.runtime, {
		subject=row.subject, owner=row.owner_user_id, event_type="memory.state", event_id=row.event_id,
		stream_time_ms=f.now_ms, stream_sequence=u64(row.outbox_seq), envelope=object,
	}))
	uow, begun, _ = iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return
	testing.expect_value(t, uow.repos.event_outbox.mark_published(uow.repos.event_outbox.ctx, row.outbox_seq, row.created_at).code, domain.Error_Code.None)
	_, _ = iface.unit_of_work_commit(&uow)
}

memory_preset_valid :: proc(t: ^testing.T, f: ^Action_Test, run: domain.Action_Run) -> (bool, string) {
	uow, begun, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, begun) do return false, "begin failed"
	defer iface.unit_of_work_rollback(&uow)
	return event_still_valid(uow.repos, run)
}
