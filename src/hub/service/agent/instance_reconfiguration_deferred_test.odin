package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"

// T4: apply "after_turn" queues a reconfiguration in waiting_for_idle while the
// instance is mid-turn and fires it on the next idle report.

@(private = "file") DEFER_OWNER :: "user_deferred"
@(private = "file") DEFER_AGENT :: "agt_deferred"
@(private = "file") DEFER_INSTANCE :: "inst_deferred"
@(private = "file") DEFER_SOURCE :: "brg_deferred_source"
@(private = "file") DEFER_DESTINATION :: "brg_deferred_destination"
@(private = "file") DEFER_PROVIDER :: "codex"
@(private = "file") DEFER_MODEL :: "gpt-6.1-sol"

@(private = "file")
Deferred_Event :: struct { change: string, phase: domain.Instance_Reconfiguration_Phase, failure_code: string }

@(private = "file")
Deferred_Harness :: struct {
	path:          string,
	conn:          sqlite.Conn,
	agent_impl:    sqlite.Agent_Repo_SQLite,
	bridge_impl:   sqlite.Bridge_Repo_SQLite,
	project_impl:  sqlite.Project_Repo_SQLite,
	content_impl:  sqlite.Content_Repo_SQLite,
	provider_impl: sqlite.Provider_Repo_SQLite,
	agents:        iface.Agent_Repository,
	bridges:       iface.Bridge_Repository,
	projects:      iface.Project_Repository,
	content:       iface.Content_Repository,
	providers:     iface.Provider_Repository,
	registry:      project_service.Bridge_Runtime_Registry,
	commands:      [dynamic]project_service.Runtime_Command,
	events:        [dynamic]Deferred_Event,
	clock:         platform.Clock,
	ids:           platform.ID_Generator,
	service:       Agent_Service,
}

@(private = "file")
deferred_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	h := (^Deferred_Harness)(ctx)
	append(&h.commands, command)
	return true, {}
}

@(private = "file")
deferred_validate :: proc(ctx: rawptr, command: project_service.Validate_Project_Path_Command) -> (project_service.Project_Path_Validation_Result, bool, domain.Domain_Error) {
	return {command_id = command.command_id, project_id = command.project_id, path = command.path, ok = true}, true, {}
}

@(private = "file")
deferred_on_changed :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, change: string, config_committed: bool) {
	h := (^Deferred_Harness)(ctx)
	append(&h.events, Deferred_Event{change = strings.clone(change), phase = op.phase, failure_code = strings.clone(op.failure_code)})
}

@(private = "file")
deferred_open :: proc(t: ^testing.T, h: ^Deferred_Harness, name: string, runtime_status := "running", activity := "busy") -> bool {
	h.path = fmt.aprintf("%s/.cache/heimdall-tests/%s.db", os.get_env("HOME", context.temp_allocator), name)
	os.remove(h.path)
	conn, opened, open_err := sqlite.open(h.path)
	if !testing.expectf(t, opened, "open db: %s", open_err.message) do return false
	h.conn = conn
	if migrated, migration_err := sqlite.run_migrations(&h.conn); !testing.expectf(t, migrated, "migrations: %s", migration_err.message) do return false
	h.agents = sqlite.new_agent_repository(&h.agent_impl, &h.conn)
	h.bridges = sqlite.new_bridge_repository(&h.bridge_impl, &h.conn)
	h.projects = sqlite.new_project_repository(&h.project_impl, &h.conn)
	h.content = sqlite.new_content_repository(&h.content_impl, &h.conn)
	h.providers = sqlite.new_provider_repository(&h.provider_impl, &h.conn)
	h.clock = platform.real_clock()
	h.ids = platform.real_id_generator()
	sink := project_service.Bridge_Command_Sink{ctx = h, validate_project_path = deferred_validate, send_runtime_command = deferred_send}
	h.service = new_agent_service_with_runtime(&h.agents, &h.bridges, &h.projects, &h.content, nil, sink, &h.registry, &h.clock, &h.ids)
	h.service.providers = &h.providers
	h.service.resource_events = Resource_Event_Hooks{ctx = h, on_reconfiguration_changed = deferred_on_changed}
	now := "2026-11-26T10:00:00Z"
	feature_json := `{"features":["instance_reconfiguration_v1"]}`
	for id in ([]string{DEFER_SOURCE, DEFER_DESTINATION}) {
		_, saved, save_err := iface.bridge_save_bridge(&h.bridges, domain.Bridge{bridge_id = id, owner_user_id = DEFER_OWNER, label = id, machine_hostname = id, machine_os = "linux", machine_arch = "amd64", capabilities_json = feature_json, hub_url = "https://hub.example", status = .Online, bridge_token_hash = id, created_at = now, updated_at = now, last_seen_at = now})
		if !testing.expect(t, saved, save_err.message) do return false
		_, _, live := project_service.bridge_runtime_registry_accept_live(&h.registry, id, false, "", DEFER_OWNER)
		if !testing.expect(t, live) do return false
		_, status_err := iface.bridge_provider_status_upsert(&h.providers, domain.Bridge_Provider_Status{bridge_id = id, provider = DEFER_PROVIDER, binary_path = "/usr/bin/codex", state = "present", checked_at = now})
		if !testing.expect(t, status_err.code == .None, status_err.message) do return false
		_, setting_err := iface.bridge_provider_setting_upsert(&h.providers, domain.Bridge_Provider_Setting{bridge_id = id, provider = DEFER_PROVIDER, enabled = true, updated_at = now})
		if !testing.expect(t, setting_err.code == .None, setting_err.message) do return false
	}
	_, saved, save_err := iface.agent_save(&h.agents, domain.Agent{agent_id = DEFER_AGENT, owner_user_id = DEFER_OWNER, name = "Worker", slug = "worker", template_id = domain.TEMPLATE_EMPTY_ID, state = .Active, created_at = now, updated_at = now})
	if !testing.expect(t, saved, save_err.message) do return false
	_, saved, save_err = iface.agent_save_instance(&h.agents, domain.Agent_Instance{agent_instance_id = DEFER_INSTANCE, owner_user_id = DEFER_OWNER, agent_id = DEFER_AGENT, bridge_id = DEFER_SOURCE, provider = DEFER_PROVIDER, model = DEFER_MODEL, conversation_id = "chat_deferred", runtime_status = runtime_status, startup_status = "ready", activity_status = activity, launch_epoch = "launch_src", run_count = 1, created_at = now, updated_at = now})
	if !testing.expect(t, saved, save_err.message) do return false
	_, saved, save_err = iface.content_save_conversation(&h.content, domain.Chat_Conversation{conversation_id = "chat_deferred", owner_user_id = DEFER_OWNER, agent_id = DEFER_AGENT, agent_instance_id = DEFER_INSTANCE, title = "Worker", created_at = now, updated_at = now})
	return testing.expect(t, saved, save_err.message)
}

@(private = "file")
deferred_close :: proc(h: ^Deferred_Harness) {
	project_service.bridge_runtime_registry_destroy(&h.registry)
	sqlite.close(&h.conn)
	os.remove(h.path)
}

@(private = "file")
deferred_auth :: proc() -> contracts.Auth_Context { return {kind = .Session, user_id = DEFER_OWNER} }

@(private = "file")
deferred_input :: proc(key, apply: string, bridge := DEFER_SOURCE) -> Reconfigure_Operation_Input {
	return {bridge_id = bridge, provider = DEFER_PROVIDER, model = DEFER_MODEL, idempotency_key = key, expected_revision = 0, permission_mode = "ask", apply = apply}
}

@(private = "file")
deferred_set_activity :: proc(h: ^Deferred_Harness, activity: string) -> bool {
	return sqlite.exec(&h.conn, fmt.tprintf("UPDATE agent_instances SET activity_status='%s' WHERE agent_instance_id='%s';", activity, DEFER_INSTANCE))
}

@(private = "file")
deferred_get :: proc(t: ^testing.T, h: ^Deferred_Harness, key: string) -> domain.Instance_Reconfiguration {
	op, found, err := iface.instance_reconfiguration_get(&h.agents, DEFER_OWNER, DEFER_INSTANCE, key)
	testing.expect(t, found, err.message)
	return op
}

@(private = "file")
deferred_stop_count :: proc(h: ^Deferred_Harness) -> int {
	n := 0
	for c in h.commands do if strings.contains(c.body_json, `"stop_agent"`) || strings.contains(c.body_json, "configuration_change") do n += 1
	return n
}

@(test)
test_after_turn_on_idle_instance_starts_at_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_idle", activity = "idle") { deferred_close(&h); return }
	defer deferred_close(&h)
	op, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("idle-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect_value(t, op.phase, domain.Instance_Reconfiguration_Phase.Stopping)
	testing.expect_value(t, op.apply, "after_turn")
	testing.expect_value(t, op.waiting_since, "")
	testing.expect_value(t, deferred_stop_count(&h), 1)
	// An unknown apply mode is a validation error.
	_, accepted, err = begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("bad-key", "later"))
	testing.expect(t, !accepted && err.code == .Validation_Failed)
}

@(test)
test_after_turn_on_busy_instance_waits_then_fires_on_idle_report :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_busy") { deferred_close(&h); return }
	defer deferred_close(&h)
	op, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("busy-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect_value(t, op.phase, domain.Instance_Reconfiguration_Phase.Waiting_For_Idle)
	testing.expect(t, op.waiting_since != "", "waiting_since is exposed")
	testing.expect_value(t, len(h.commands), 0)
	if testing.expect_value(t, len(h.events), 1) {
		testing.expect_value(t, h.events[0].change, "created")
		testing.expect_value(t, h.events[0].phase, domain.Instance_Reconfiguration_Phase.Waiting_For_Idle)
	}
	// Messages and runtime actions are not blocked while waiting.
	idle_ok, idle_err := reconfiguration_require_idle(&h.service, DEFER_INSTANCE)
	testing.expect(t, idle_ok, idle_err.message)
	// The same key is idempotent and returns the queued operation.
	again, again_ok, _ := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("busy-key", "after_turn"))
	testing.expect(t, again_ok && again.operation_id == op.operation_id && again.phase == .Waiting_For_Idle)
	// A busy report and the sweep keep waiting.
	notify_instance_activity(&h.service, DEFER_INSTANCE, "busy")
	reconcile_active_reconfigurations(&h.service)
	still := deferred_get(t, &h, "busy-key")
	testing.expect_value(t, still.phase, domain.Instance_Reconfiguration_Phase.Waiting_For_Idle)
	testing.expect_value(t, len(h.commands), 0)
	// The turn ends: the next idle report fires the normal flow.
	testing.expect(t, deferred_set_activity(&h, "idle"))
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	fired := deferred_get(t, &h, "busy-key")
	testing.expect_value(t, fired.phase, domain.Instance_Reconfiguration_Phase.Stopping)
	testing.expect_value(t, fired.waiting_since, op.waiting_since)
	testing.expect_value(t, deferred_stop_count(&h), 1)
	last := h.events[len(h.events)-1]
	testing.expect_value(t, last.change, "progress")
	testing.expect_value(t, last.phase, domain.Instance_Reconfiguration_Phase.Stopping)
	// A later idle report does not fire twice.
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	testing.expect_value(t, deferred_stop_count(&h), 1)
}

@(test)
test_after_turn_waits_for_acp_turn_hold :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_acp", activity = "idle") { deferred_close(&h); return }
	defer deferred_close(&h)
	testing.expect(t, sqlite.exec(&h.conn, "UPDATE agent_instances SET runtime_transport='acp' WHERE agent_instance_id='inst_deferred';"))
	testing.expect(t, sqlite.exec(&h.conn, "INSERT INTO chat_messages(message_id,conversation_id,owner_user_id,direction,body,created_at) VALUES('msg_held','chat_deferred','user_deferred','user_to_agent','hi','now');"))
	held := domain.ACP_Input_Delivery{message_id = "msg_held", owner_user_id = DEFER_OWNER, conversation_id = "chat_deferred", agent_instance_id = DEFER_INSTANCE, launch_epoch = "launch_src", state = "queued", hold_reason = "turn_active", created_at = "now", updated_at = "now"}
	testing.expect_value(t, iface.content_save_input_delivery(&h.content, held).code, domain.Error_Code.None)
	inst, _, _ := iface.agent_get_instance(&h.agents, DEFER_INSTANCE)
	testing.expect(t, !reconfiguration_instance_idle(&h.service, inst), "an ACP turn hold means the turn is still running")
	// A hold from an earlier launch is stale and does not count.
	held.launch_epoch = "launch_old"
	testing.expect_value(t, iface.content_save_input_delivery(&h.content, held).code, domain.Error_Code.None)
	testing.expect(t, reconfiguration_instance_idle(&h.service, inst))
}

@(test)
test_after_turn_fire_time_revision_conflict_fails_with_conflict_code :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_conflict") { deferred_close(&h); return }
	defer deferred_close(&h)
	_, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("conflict-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	// Something else changed the configuration while the operation waited.
	testing.expect(t, sqlite.exec(&h.conn, "UPDATE agent_instances SET configuration_revision=configuration_revision+1, activity_status='idle' WHERE agent_instance_id='inst_deferred';"))
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	failed := deferred_get(t, &h, "conflict-key")
	testing.expect_value(t, failed.phase, domain.Instance_Reconfiguration_Phase.Failed)
	testing.expect_value(t, failed.failure_code, domain.RECONFIGURATION_CONFLICT)
	testing.expect_value(t, failed.failure_code, domain.error_code_string(.Conflict))
	testing.expect_value(t, len(h.commands), 0)
	testing.expect_value(t, h.events[len(h.events)-1].change, "failed")
	// The slot is free again.
	queued, _, _ := reconfiguration_waiting_for_instance(&h.service, "", DEFER_INSTANCE)
	testing.expect_value(t, queued.operation_id, "")
}

@(test)
test_after_turn_source_offline_keeps_waiting_until_reconnect :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_offline") { deferred_close(&h); return }
	defer deferred_close(&h)
	_, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("offline-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	// The source disconnects mid-turn; a stale idle activity must not fence it.
	project_service.bridge_runtime_registry_mark_offline(&h.registry, DEFER_SOURCE, 0)
	testing.expect(t, deferred_set_activity(&h, "idle"))
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	reconcile_active_reconfigurations(&h.service)
	waiting := deferred_get(t, &h, "offline-key")
	testing.expect_value(t, waiting.phase, domain.Instance_Reconfiguration_Phase.Waiting_For_Idle)
	testing.expect_value(t, len(h.commands), 0)
	// Reconnect: the bridge reconcile (or next idle report) fires it.
	_, _, live := project_service.bridge_runtime_registry_accept_live(&h.registry, DEFER_SOURCE, false, "", DEFER_OWNER)
	testing.expect(t, live)
	reconcile_instance_reconfigurations(&h.service, DEFER_SOURCE)
	fired := deferred_get(t, &h, "offline-key")
	testing.expect_value(t, fired.phase, domain.Instance_Reconfiguration_Phase.Stopping)
	testing.expect_value(t, deferred_stop_count(&h), 1)
}

@(test)
test_after_turn_destination_offline_at_fire_fails_without_stopping_source :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_destination_offline") { deferred_close(&h); return }
	defer deferred_close(&h)
	_, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("move-key", "after_turn", DEFER_DESTINATION))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect(t, sqlite.exec(&h.conn, "UPDATE bridges SET status='offline' WHERE bridge_id='brg_deferred_destination';"))
	project_service.bridge_runtime_registry_mark_offline(&h.registry, DEFER_DESTINATION, 0)
	testing.expect(t, deferred_set_activity(&h, "idle"))
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	failed := deferred_get(t, &h, "move-key")
	testing.expect_value(t, failed.phase, domain.Instance_Reconfiguration_Phase.Failed)
	testing.expect(t, failed.failure_code != "" && !failed.source_stopped, failed.failure_code)
	testing.expect_value(t, len(h.commands), 0)
	testing.expect(t, !domain.instance_reconfiguration_blocks_input(failed), "the running agent keeps accepting messages")
}

@(test)
test_cancel_only_in_waiting_for_idle :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_cancel") { deferred_close(&h); return }
	defer deferred_close(&h)
	op, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("cancel-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	_, cancelled, cancel_err := cancel_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, "cancel-key", op.revision + 1)
	testing.expect(t, !cancelled && cancel_err.code == .Conflict, "a stale revision is a conflict")
	_, cancelled, cancel_err = cancel_instance_reconfiguration(&h.service, contracts.Auth_Context{kind = .Session, user_id = "someone_else"}, DEFER_INSTANCE, "cancel-key", op.revision)
	testing.expect(t, !cancelled && cancel_err.code == .Not_Found, "another owner cannot cancel")
	ended: domain.Instance_Reconfiguration
	ended, cancelled, cancel_err = cancel_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, "cancel-key", op.revision)
	if !testing.expect(t, cancelled, cancel_err.message) do return
	testing.expect_value(t, ended.phase, domain.Instance_Reconfiguration_Phase.Failed)
	testing.expect_value(t, ended.failure_code, domain.RECONFIGURATION_CANCELLED)
	testing.expect_value(t, h.events[len(h.events)-1].change, "cancelled")
	_, cancelled, cancel_err = cancel_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, "cancel-key", ended.revision)
	testing.expect(t, !cancelled && cancel_err.code == .Conflict, "a cancelled operation cannot be cancelled again")
	// The idle report after a cancel fires nothing.
	testing.expect(t, deferred_set_activity(&h, "idle"))
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	testing.expect_value(t, len(h.commands), 0)
	// A running (now) operation is never cancelled here.
	now_op, now_ok, now_err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("now-key", "now"))
	if !testing.expect(t, now_ok, now_err.message) do return
	_, cancelled, cancel_err = cancel_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, "now-key", now_op.revision)
	testing.expect(t, !cancelled && cancel_err.code == .Conflict)
}

@(test)
test_restart_now_supersedes_waiting_operation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_restart_now") { deferred_close(&h); return }
	defer deferred_close(&h)
	queued, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("queued-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	// One active operation: another queued request, or one that omits apply, conflicts.
	_, accepted, err = begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("second-queued", "after_turn"))
	testing.expect(t, !accepted && err.code == .Conflict)
	_, accepted, err = begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("implicit-now", ""))
	testing.expect(t, !accepted && err.code == .Conflict, "an omitted apply never supersedes")
	events_before := len(h.events)
	now_op, now_ok, now_err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("restart-now", "now"))
	if !testing.expect(t, now_ok, now_err.message) do return
	testing.expect_value(t, now_op.phase, domain.Instance_Reconfiguration_Phase.Stopping)
	testing.expect_value(t, now_op.apply, "now")
	testing.expect_value(t, deferred_stop_count(&h), 1)
	superseded := deferred_get(t, &h, "queued-key")
	testing.expect_value(t, superseded.phase, domain.Instance_Reconfiguration_Phase.Failed)
	testing.expect_value(t, superseded.failure_code, domain.RECONFIGURATION_SUPERSEDED)
	testing.expect_value(t, superseded.revision, queued.revision + 1)
	if testing.expect(t, len(h.events) >= events_before + 2) {
		testing.expect_value(t, h.events[events_before].change, "cancelled")
		testing.expect_value(t, h.events[events_before].failure_code, domain.RECONFIGURATION_SUPERSEDED)
		testing.expect_value(t, h.events[events_before+1].change, "created")
	}
}

@(test)
test_user_stop_while_waiting_cancels_queued_change :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_stop_while_waiting") { deferred_close(&h); return }
	defer deferred_close(&h)
	_, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("stop-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	_, stopped, stop_err := stop_instance(&h.service, deferred_auth(), DEFER_INSTANCE, {reason = "user_requested"})
	if !testing.expect(t, stopped, stop_err.message) do return
	cancelled := deferred_get(t, &h, "stop-key")
	testing.expect_value(t, cancelled.phase, domain.Instance_Reconfiguration_Phase.Failed)
	testing.expect_value(t, cancelled.failure_code, domain.RECONFIGURATION_CANCELLED)
	testing.expect_value(t, cancelled.failure_message, RECONFIGURATION_STOPPED_MESSAGE)
	testing.expect_value(t, h.events[len(h.events)-1].change, "cancelled")
	// The runtime reports stopped and the sweep runs: nothing relaunches it.
	sent := len(h.commands)
	testing.expect(t, sqlite.exec(&h.conn, "UPDATE agent_instances SET runtime_status='stopped', activity_status='idle' WHERE agent_instance_id='inst_deferred';"))
	notify_instance_activity(&h.service, DEFER_INSTANCE, "idle")
	reconcile_active_reconfigurations(&h.service)
	testing.expect_value(t, len(h.commands), sent)
	for c in h.commands do testing.expect(t, !strings.contains(c.body_json, "launch_agent"), c.body_json)
}

@(test)
test_runtime_stopped_or_failed_while_waiting_cancels_without_launch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	for status in ([]string{"stopped", "failed"}) {
		h: Deferred_Harness
		if !deferred_open(t, &h, fmt.tprintf("t4_runtime_%s_while_waiting", status)) { deferred_close(&h); return }
		_, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("exit-key", "after_turn"))
		if testing.expect(t, accepted, err.message) {
			// A bridge-side exit or crash that did not go through stop_instance.
			testing.expect(t, sqlite.exec(&h.conn, fmt.tprintf("UPDATE agent_instances SET runtime_status='%s' WHERE agent_instance_id='inst_deferred';", status)))
			reconcile_active_reconfigurations(&h.service)
			op := deferred_get(t, &h, "exit-key")
			testing.expectf(t, op.phase == .Failed && op.failure_code == domain.RECONFIGURATION_CANCELLED, "%s: %v %s", status, op.phase, op.failure_code)
			testing.expectf(t, len(h.commands) == 0, "%s: nothing launched", status)
		}
		deferred_close(&h)
	}
}

@(test)
test_after_turn_on_stopped_instance_starts_at_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	h: Deferred_Harness
	if !deferred_open(t, &h, "t4_after_turn_stopped", runtime_status = "stopped", activity = "unknown") { deferred_close(&h); return }
	defer deferred_close(&h)
	op, accepted, err := begin_instance_reconfiguration(&h.service, deferred_auth(), DEFER_INSTANCE, deferred_input("stopped-key", "after_turn"))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect(t, op.phase != .Waiting_For_Idle, "a stopped agent has no turn to wait for")
	testing.expect_value(t, op.waiting_since, "")
}
