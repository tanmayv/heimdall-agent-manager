package bots

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import virtual "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

Delivery_Fixture :: struct {
	owned: mem.Allocator,
	pair: ^Pairing_Fixture,
	placement: ^Placement_Fixture,
	agents: agent_service.Agent_Service,
	repo: iface.Agent_Repository,
	sink: project_service.Bridge_Command_Sink,
	instance: domain.Agent_Instance,
	op: domain.Instance_Reconfiguration,
	ms: i64,
	frames: [dynamic]string,
}
delivery_clock :: proc(ctx: rawptr) -> string {
	return platform.format_rfc3339_utc(time.Time{_nsec = (^Delivery_Fixture)(ctx).ms * 1_000_000})
}
delivery_instance :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	return placement_clone(f.instance), id == f.instance.agent_instance_id, {}
}
delivery_save :: proc(ctx: rawptr, inst: domain.Agent_Instance) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	context.allocator = f.owned
    f.instance = placement_clone(inst)
	f.instance.configuration_revision += 1
	return placement_clone(f.instance), true, {}
}
delivery_save_guarded :: proc(ctx: rawptr, inst: domain.Agent_Instance, count: int, epoch: string, revision: int) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
    f := (^Delivery_Fixture)(ctx)
    if f.instance.run_count != count || f.instance.launch_epoch != epoch || f.instance.configuration_revision != revision do return {}, false, {}
    return delivery_save(ctx, inst)
}
delivery_agent :: proc(ctx: rawptr, id: string) -> (domain.Agent, bool, domain.Domain_Error) {
	return placement_clone(domain.Agent{agent_id = "agt_a", owner_user_id = "alice", name = "bot", state = .Active}), true, {}
}
delivery_ops :: proc(ctx: rawptr, owner, inst: string, active: bool) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	if f.op.idempotency_key == "" || (active && !domain.instance_reconfiguration_blocks_input(f.op)) do return nil, {}
	return placement_clone([]domain.Instance_Reconfiguration{f.op}), {}
}
delivery_op_get :: proc(ctx: rawptr, owner, inst, key: string) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	return placement_clone(f.op), f.op.idempotency_key == key, {}
}
delivery_op_advance :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, rev: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	f.op = placement_clone(op)
	return placement_clone(op), true, {}
}
delivery_send :: proc(ctx: rawptr, cmd: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	append(&f.frames, strings.clone(cmd.body_json, runtime.heap_allocator()))
	return true, {}
}
delivery_fixture :: proc(t: ^testing.T) -> ^Delivery_Fixture {
	f := new(Delivery_Fixture)
	f.owned = context.allocator
	f.pair = pairing_fixture(t)
	f.placement = placement_fixture()
	placement_select_bridges(f.placement)
	f.placement.bridges = f.placement.bridges[:1]
	f.ms = bots_stamp_ms("2026-11-17T12:00:00Z")
	f.pair.clock = {ctx = f, now = delivery_clock}
	f.repo = {ctx = f, get_instance = delivery_instance, save_instance = delivery_save, save_instance_guarded = delivery_save_guarded, get = delivery_agent,get_support=delivery_support,
		reconfiguration_begin = delivery_op_begin, reconfiguration_list = delivery_ops, reconfiguration_get = delivery_op_get, reconfiguration_advance = delivery_op_advance}
	f.instance = {agent_instance_id = "inst_a", agent_id = "agt_a", owner_user_id = "alice", bridge_id = "b1",
		provider = "alpha", provider_profile = "alpha", model = "m1", runtime_status = "stopped", configuration_revision = 1}
	f.sink = {ctx = f, send_runtime_command = delivery_send}
	f.agents = {agents = &f.repo, bridges = &f.placement.bridge_repo, providers = &f.placement.provider_repo,
		bridge_runtime_registry = &f.placement.registry, bridge_command_sink = f.sink, clock = &f.pair.clock, ids = &f.pair.ids}
	s := &f.pair.service
	s.agents, s.bridges, s.providers, s.registry, s.command_sink = &f.agents, &f.placement.bridge_repo, &f.placement.providers, &f.placement.registry, &f.sink
	s.boot_unix_ms, s.last_idle_check_ms, s.last_retention_ms, s.last_waiting_recheck_ms = f.ms, f.ms, f.ms, f.ms
	testing.expect_value(t, iface.bot_set_instance(s.repo, "bot_a", "inst_a", delivery_clock(f)).code, domain.Error_Code.None)
	pairing_test_bound(t, f.pair)
	f.pair.adapter.send_text = delivery_notice
	f.pair.adapter.ctx = f
	return f
}
delivery_destroy :: proc(f: ^Delivery_Fixture) {
	bots_service_destroy(&f.pair.service)
	for frame in f.frames do delete(frame, runtime.heap_allocator())
	delete(f.frames)
	placement_fixture_destroy(f.placement)
	pairing_fixture_destroy(f.pair)
	free(f)
}
delivery_inbound :: proc(t: ^testing.T, f: ^Delivery_Fixture, id := "chm_a") {
	binding, _, _ := iface.binding_get_active_by_owner(&f.pair.repo, "alice", "telegram")
	defer domain.channel_binding_destroy(&binding)
	rows := []domain.Channel_Message{{message_id = id, binding_id = binding.binding_id, bot_id = "bot_a", owner_user_id = "alice",
		direction = .Inbound, provider_update_key = id, body = "hello", created_at = delivery_clock(f)}}
	inserted, e := iface.inbound_store_batch(&f.pair.repo, "telegram", rows, id, delivery_clock(f))
	for value in inserted do delete(value)
	delete(inserted)
	testing.expect_value(t, e.code, domain.Error_Code.None)
	testing.expect_value(t, delivery_on_inbound(&f.pair.service, "bot_a", f.ms).code, domain.Error_Code.None)
}
delivery_get_test :: proc(f: ^Delivery_Fixture) -> domain.Bot_Delivery {
	ds, _ := iface.delivery_list_recent(&f.pair.repo, "bot_a", 1)
	defer delete(ds)
	return ds[0]
}
delivery_attempt_test :: proc(f: ^Delivery_Fixture) -> domain.Bot_Delivery_Attempt {
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	all, _ := iface.attempt_list_for_delivery(&f.pair.repo, d.delivery_id)
	defer delete(all)
	return all[len(all)-1]
}
delivery_seed :: proc(t: ^testing.T, f: ^Delivery_Fixture, state := domain.Bot_Attempt_State.Sent) {
	delivery_inbound(t, f)
	bots_supervisor_tick(&f.pair.service)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	updated := a
	updated.state = state
	if state == .Accepted do updated.accepted_at = delivery_clock(f)
	if !domain.bot_attempt_state_open(state) do updated.finished_at = delivery_clock(f)
	changed, e := iface.attempt_update(&f.pair.repo, updated, a.state)
	testing.expect(t, changed && e.code == .None)
}
delivery_report_test :: proc(t: ^testing.T, f: ^Delivery_Fixture, state: string, seq := 1) {
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	frame, _ := json.marshal(contracts.Bot_Delivery_Report_Wire{type = "bot_delivery_report", attempt_id = a.attempt_id, delivery_id = a.delivery_id, agent_instance_id = "inst_a", seq = seq, state = state})
	defer delete(frame)
	ack, failed := bots_on_report(&f.pair.service, "b1", string(frame))
	defer delete(ack)
	testing.expect(t, !failed)
	testing.expect(t, strings.contains(ack, a.attempt_id))
}
delivery_expect :: proc(t: ^testing.T, f: ^Delivery_Fixture, state: domain.Bot_Delivery_State, reason := "") {
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	testing.expect_value(t, d.state, state)
	if reason != "" do testing.expect_value(t, d.waiting_reason if state == .Waiting else d.finish_reason, reason)
}
delivery_attempt_expect :: proc(t: ^testing.T, f: ^Delivery_Fixture, state: domain.Bot_Attempt_State) {
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	testing.expect_value(t, a.state, state)
}

@(test)
test_delivery_row_01 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f); delivery_expect(t, f, .Pending)
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	testing.expect_value(t, d.round, 1); testing.expect_value(t, d.through_message_id, "chm_a")
}
@(test)
test_delivery_row_02 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); delivery_expect(t, f, .Dispatched); delivery_attempt_expect(t, f, .Sent)
    value, err := json.parse(f.frames[0], allocator = context.temp_allocator)
    object, ok := value.(json.Object)
    _, skip_array := object["skip"].(json.Array)
    testing.expect(t, err == nil && ok && skip_array)
}
@(test)
test_delivery_row_03 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f); f.placement.bridges = nil
	count := len(f.pair.sent)
	bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Waiting, "no_bridge")
	testing.expect_value(t, len(f.pair.sent), count+1); pairing_test_last(t, f.pair, COPY_NO_MACHINE)
	bots_supervisor_tick(&f.pair.service); testing.expect_value(t, len(f.pair.sent), count+1)
}
@(test)
test_single_bridge_all_exhausted_abandons_with_gave_up :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	count := len(f.pair.sent)
	delivery_report_test(t, f, "exhausted")
	delivery_expect(t, f, .Pending)
	bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Abandoned, "all_tried")
	pairing_test_last(t, f.pair, COPY_GAVE_UP)
	bots_supervisor_tick(&f.pair.service)
	testing.expect_value(t, len(f.pair.sent), count+1)
}
@(test)
test_delivery_row_05 :: proc(t: ^testing.T) {test_single_bridge_all_exhausted_abandons_with_gave_up(t)}
@(test)
test_delivery_row_04 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); count := len(f.pair.sent)
	delivery_report_test(t, f, "busy"); bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Waiting, "busy"); testing.expect_value(t, len(f.pair.sent), count)
}
@(test)
test_delivery_row_06 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	delivery_inbound(t, f, "chm_b")
	delivery_report_test(t, f, "acted")
	// The old message remains pending in this synthetic bridge-only report,
	// so R3 immediately opens a new pending delivery including it and chm_b.
	delivery_expect(t, f, .Pending)
	ds, _ := iface.delivery_list_recent(&f.pair.repo, "bot_a", 10)
	defer {for &d in ds do domain.bot_delivery_destroy(&d); delete(ds)}
	testing.expect_value(t, len(ds), 2)
	for d in ds do if d.state == .Acted do testing.expect_value(t, d.finish_reason, "acted")
}
@(test)
test_delivery_row_07 :: proc(t: ^testing.T) {
	for state in ([]string{"exhausted", "busy"}) {
		f := delivery_fixture(t)
		delivery_seed(t, f); delivery_report_test(t, f, state); delivery_expect(t, f, .Pending)
		delivery_destroy(f)
	}
}
@(test)
test_delivery_row_08 :: proc(t: ^testing.T) {test_relocation_stranded_waits_for_hello(t)}
@(test)
test_delivery_row_09 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	testing.expect_value(t, iface.messages_mark_read(&f.pair.repo, "bot_a", {"chm_a"}, delivery_clock(f)).code, domain.Error_Code.None)
	binding, _, _ := iface.binding_get_active_by_owner(&f.pair.repo, "alice", "telegram")
	defer domain.channel_binding_destroy(&binding)
	testing.expect_value(t, bots_channel_replied(&f.pair.service, "bot_a", binding.binding_id).code, domain.Error_Code.None)
	delivery_expect(t, f, .Acted, "acted"); delivery_attempt_expect(t, f, .Acted)
}
@(test)
test_delivery_row_10 :: proc(t: ^testing.T) {test_no_bridge_recheck_on_hello_and_periodic(t)}
@(test)
test_delivery_row_11 :: proc(t: ^testing.T) {test_round_end_with_busy_waits_then_retries_next_round(t)}
@(test)
test_delivery_row_12 :: proc(t: ^testing.T) {test_relocation_stranded_waits_for_hello(t)}
@(test)
test_delivery_row_13 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f); f.placement.bridges = nil; bots_supervisor_tick(&f.pair.service)
	rev, e := bots_put_placement(&f.pair.service, "alice", 0, nil)
	testing.expect_value(t, e.code, domain.Error_Code.None); testing.expect_value(t, rev, 1)
	delivery_expect(t, f, .Pending)
}
@(test)
test_delivery_row_14 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f); f.placement.bridges = nil; bots_supervisor_tick(&f.pair.service)
	count := len(f.pair.sent)
	delivery_inbound(t, f, "chm_b")
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	testing.expect_value(t, d.through_message_id, "chm_b")
	testing.expect_value(t, d.state, domain.Bot_Delivery_State.Waiting)
	testing.expect_value(t, len(f.pair.sent), count)
}
@(test)
test_delivery_row_15 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f); delivery_inbound(t, f, "chm_b")
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	testing.expect_value(t, d.through_message_id, "chm_a")
	bots_supervisor_tick(&f.pair.service); delivery_inbound(t, f, "chm_c")
	next := delivery_get_test(f); defer domain.bot_delivery_destroy(&next)
	testing.expect_value(t, next.through_message_id, "chm_a")
}
@(test)
test_delivery_row_16 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	testing.expect_value(t, bots_disconnect(&f.pair.service, "alice", "telegram", false).code, domain.Error_Code.None)
	delivery_expect(t, f, .Abandoned, "binding_revoked"); delivery_attempt_expect(t, f, .Cancelled)
}
@(test)
test_delivery_row_17 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	testing.expect_value(t, bots_disconnect_for_reason(&f.pair.service, "alice", "telegram", false, "bot_deleted").code, domain.Error_Code.None)
	delivery_expect(t, f, .Abandoned, "bot_deleted"); delivery_attempt_expect(t, f, .Cancelled)
}
@(test)
test_delivery_row_18 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); count := len(f.pair.sent)
	bots_on_experiment_disabled(&f.pair.service, "alice")
	delivery_expect(t, f, .Abandoned, "experiment_disabled"); delivery_attempt_expect(t, f, .Cancelled)
	testing.expect_value(t, len(f.pair.sent), count)
}

@(test)
test_new_message_after_abandon_opens_round_one_delivery :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); delivery_report_test(t, f, "exhausted"); bots_supervisor_tick(&f.pair.service)
	delivery_inbound(t, f, "chm_b"); delivery_expect(t, f, .Pending)
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	testing.expect_value(t, d.round, 1)
	pending, _ := iface.messages_pending(&f.pair.repo, "bot_a", -1)
	defer {for &m in pending do domain.channel_message_destroy(&m); delete(pending)}
	testing.expect_value(t, len(pending), 2)
}
@(test)
test_round_end_with_busy_waits_then_retries_next_round :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); delivery_report_test(t, f, "busy"); bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Waiting, "busy")
	f.ms += f.pair.service.timers.bot_busy_retry_ms
	bots_supervisor_tick(&f.pair.service); delivery_expect(t, f, .Pending)
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	testing.expect_value(t, d.round, 2)
	bots_supervisor_tick(&f.pair.service); delivery_expect(t, f, .Dispatched)
}
@(test)
test_no_bridge_recheck_on_hello_and_periodic :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f)
	f.placement.bridges[0].status = .Offline
	bots_supervisor_tick(&f.pair.service)
	bots_on_bridge_hello(&f.pair.service, "b1"); bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Waiting, "no_bridge")
	f.placement.bridges[0].status = .Online
	bots_supervisor_tick(&f.pair.service); delivery_expect(t, f, .Waiting)
	f.ms += f.pair.service.timers.bot_waiting_recheck_ms
	bots_supervisor_tick(&f.pair.service); delivery_expect(t, f, .Pending)
}
@(test)
test_wakeup_past_max_rounds_abandons :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); delivery_report_test(t, f, "busy"); bots_supervisor_tick(&f.pair.service)
	d := delivery_get_test(f); defer domain.bot_delivery_destroy(&d)
	updated := d; updated.round = f.pair.service.timers.bot_max_rounds
	_, _ = iface.delivery_update(&f.pair.repo, updated, .Waiting)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	ua := a; ua.round = updated.round; _, _ = iface.attempt_update(&f.pair.repo, ua, a.state)
	f.ms += f.pair.service.timers.bot_busy_retry_ms
	bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Abandoned, "max_rounds"); pairing_test_last(t, f.pair, COPY_GAVE_UP)
}
@(test)
test_hello_hook_changes_no_delivery :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_inbound(t, f); f.placement.bridges = nil; bots_supervisor_tick(&f.pair.service)
	count := len(f.pair.sent)
	bots_on_bridge_hello(&f.pair.service, "b1")
	delivery_expect(t, f, .Waiting, "no_bridge")
	testing.expect_value(t, len(f.pair.sent), count)
}
@(test)
test_resend_on_hello_same_command_id :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	before := len(f.frames)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	delivery_disconnect(f)
	f.ms += 1000
	f.instance.model = "m2"
	bots_on_bridge_hello(&f.pair.service, "b1")
	testing.expect_value(t, len(f.frames), before+1)
	frame: contracts.Bot_Deliver_Wire
	testing.expect_value(t, json.unmarshal(transmute([]u8)f.frames[len(f.frames)-1], &frame, allocator = context.temp_allocator), nil)
	testing.expect_value(t, frame.command_id, fmt.tprintf("cmd_bot_%s", a.attempt_id))
	testing.expect_value(t, frame.current_model, "m2")
	after := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&after)
	testing.expect_value(t, after.sent_at, a.sent_at); testing.expect_value(t, after.disconnected_at, "")
}
@(test)
test_disconnect_grace :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f, .Accepted); delivery_disconnect(f)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	f.ms += f.pair.service.timers.bot_disconnect_grace_ms
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Accepted)
	f.ms += 1000
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Disconnected)
	delivery_expect(t, f, .Pending)
}
@(test)
test_hub_restart_measures_silence_from_boot :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f, .Accepted)
	f.ms += 1_000_000; f.pair.service.boot_unix_ms = f.ms
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Accepted)
	f.ms += f.pair.service.timers.bot_attempt_silence_ms + 1000
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Deadline)
}
@(test)
test_report_seq_dedupe :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); delivery_report_test(t, f, "working", 2)
	delivery_report_test(t, f, "exhausted", 1)
	delivery_attempt_expect(t, f, .Sent)
	delivery_report_test(t, f, "busy", 3); delivery_report_test(t, f, "acted", 4)
	delivery_attempt_expect(t, f, .Busy)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	testing.expect_value(t, a.report_seq, 3)
	ack, bad := bots_on_report(&f.pair.service, "foreign", `{"attempt_id":"missing","seq":1,"state":"working"}`)
	delete(ack); testing.expect(t, !bad)
	invalid, failed := bots_on_report(&f.pair.service, "b1", "{"); delete(invalid); testing.expect(t, failed)
}

delivery_relocating :: proc(t: ^testing.T, f: ^Delivery_Fixture) {
	delivery_seed(t, f)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	updated := a; updated.state, updated.relocation_key = .Relocating, "bot:move"
	_, _ = iface.attempt_update(&f.pair.repo, updated, a.state)
	f.op = {idempotency_key = "bot:move", owner_user_id = "alice", agent_instance_id = "inst_a", phase = .Ready}
}
@(test)
test_relocation_ready_sends_frame :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_relocating(t, f); before := len(f.frames)
	bots_supervisor_tick(&f.pair.service)
	delivery_attempt_expect(t, f, .Sent); testing.expect_value(t, len(f.frames), before+1)
}
@(test)
test_relocation_recovery_force_stops :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_relocating(t, f); f.op.phase = .Recovery_Required
	bots_supervisor_tick(&f.pair.service)
	delivery_attempt_expect(t, f, .Relocating)
	testing.expect_value(t, f.instance.runtime_status, "stopping")
	testing.expect(t, strings.contains(f.frames[len(f.frames)-1], "recovery_force_stop"))
	f.op.phase, f.op.failure_code = .Failed, "recovery_stopped"
	bots_supervisor_tick(&f.pair.service); delivery_attempt_expect(t, f, .Sent)
	frame: contracts.Bot_Deliver_Wire
	_ = json.unmarshal(transmute([]u8)f.frames[len(f.frames)-1], &frame, allocator = context.temp_allocator)
	testing.expect_value(t, len(frame.skip), 1)
}
@(test)
test_relocation_stranded_waits_for_hello :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_relocating(t, f); f.op.phase = .Recovery_Required
	f.instance.bridge_id = "offline"
	bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Waiting, "relocation_stranded")
	delivery_attempt_expect(t, f, .Disconnected)
	bots_on_bridge_hello(&f.pair.service, "b1"); bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Waiting)
	bots_on_bridge_hello(&f.pair.service, "offline"); bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Pending)
}
@(test)
test_idle_stop_uses_bot_idle_reason :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	f.instance.runtime_status = "running"
	f.ms += f.pair.service.timers.bot_idle_stop_ms + 60_000
	bots_supervisor_tick(&f.pair.service)
	testing.expect_value(t, f.instance.runtime_status, "stopping")
	testing.expect(t, strings.contains(f.frames[len(f.frames)-1], "bot_idle"))
	testing.expect_value(t, f.instance.stopped_by, "")
}
@(test)
test_switch_route_rules :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	candidate := contracts.Bot_Candidate_Wire{provider = "alpha", provider_profile = "alpha", model = "m1"}
	_, missing := bots_switch(&f.pair.service, "b1", "missing", candidate)
	testing.expect_value(t, missing.code, domain.Error_Code.Not_Found)
	_, wrong_bridge :=  bots_switch(&f.pair.service, "other", a.attempt_id, candidate)
	testing.expect_value(t, wrong_bridge.code, domain.Error_Code.Not_Found)
	_, invalid := bots_switch(&f.pair.service, "b1", a.attempt_id, {provider = "evil", model = "m1"})
	testing.expect(t, strings.contains(invalid.details_json, "bot_candidate_not_allowed"))
	f.instance.bridge_id = "other"
	_, elsewhere := bots_switch(&f.pair.service, "b1", a.attempt_id, candidate)
	testing.expect(t, strings.contains(elsewhere.details_json, "bot_instance_elsewhere"))
	f.instance.bridge_id = "b1"
	unchanged, e := bots_switch(&f.pair.service, "b1", a.attempt_id, candidate)
	testing.expect_value(t, e.code, domain.Error_Code.None)
	testing.expect(t, !unchanged.relaunched)
	testing.expect_value(t, unchanged.configuration_revision, 1)
	candidate.model = "m2"
	f.op = {idempotency_key = "blocking", phase = .Recovery_Required}
	_, blocked := bots_switch(&f.pair.service, "b1", a.attempt_id, candidate)
	testing.expect(t, strings.contains(blocked.details_json, "bot_relocation_open"))
	f.op = {}
	changed, err := bots_switch(&f.pair.service, "b1", a.attempt_id, candidate)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, changed.model, "m2"); testing.expect(t, !changed.relaunched)
}

@(test)
test_bot_switch_reports_relaunch_only_when_sent :: proc(t: ^testing.T) {
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	for still_alive in ([2]bool{false, true}) {
		f := delivery_fixture(t)
		defer delivery_destroy(f)
		delivery_seed(t, f)
		a := delivery_attempt_test(f)
		defer domain.bot_delivery_attempt_destroy(&a)
		f.instance.run_count = 7
		f.instance.runtime_status = "failed" if still_alive else "running"
		if still_alive {
			f.agents.fixture_start_fact = proc(_: domain.Agent_Instance) -> agent_service.Agent_Liveness {
				return {state = .Alive, reason = .pty_child_alive, pid = 42, ready = true}
			}
		} else {
			f.agents.fixture_start_fact = proc(_: domain.Agent_Instance) -> agent_service.Agent_Liveness {
				return {state = .Exited, reason = .pty_child_exited, pid = 42}
			}
		}
		before := len(f.frames)
		view, err := bots_switch(&f.pair.service, "b1", a.attempt_id, {provider = "alpha", provider_profile = "alpha", model = "m2"})
		testing.expect_value(t, err.code, domain.Error_Code.None)
		testing.expect_value(t, view.relaunched, still_alive)
		testing.expect_value(t, view.model, "m2")
		testing.expect_value(t, len(f.frames) - before, 1 if still_alive else 0)
		testing.expect_value(t, f.instance.run_count, 8 if still_alive else 7)
	}
}

delivery_notice :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	f := (^Delivery_Fixture)(ctx)
	caller := context.allocator
	context.allocator = f.owned
	result, err := pairing_test_send(f.pair, chat, text)
	delete(result, f.owned)
	return strings.clone("sent", caller), err
}

@(test)
test_attempt_row_01 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	first := f.placement.bridges[0]
	f.placement.bridges = make([]domain.Bridge, 2, context.temp_allocator)
	f.placement.bridges[0] = first
	f.placement.bridges[1] = {bridge_id = "b2", owner_user_id = "alice", status = .Offline, capabilities_json = first.capabilities_json}
	f.instance.bridge_id = "b2"
	f.instance.conversation_id = "chat_same"
	delivery_inbound(t, f)
	bots_supervisor_tick(&f.pair.service)
	delivery_attempt_expect(t, f, .Relocating)
	delivery_expect(t, f, .Dispatched)
	testing.expect_value(t, f.op.destination.bridge_id, "b1")
	testing.expect_value(t, f.op.conversation_id, "chat_same")
	testing.expect(t, strings.has_prefix(f.op.idempotency_key, "bot:bda_"))
	testing.expect(t, strings.contains(f.frames[len(f.frames)-1], "configuration_change"))
}
@(test)
test_attempt_row_02 :: proc(t: ^testing.T) {test_delivery_row_02(t)}
@(test)
test_attempt_row_03 :: proc(t: ^testing.T) {test_relocation_ready_sends_frame(t)}
@(test)
test_attempt_row_04 :: proc(t: ^testing.T) {test_relocation_recovery_force_stops(t)}
@(test)
test_attempt_row_05 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_relocating(t, f); delivery_disconnect(f)
	f.ms += f.pair.service.timers.bot_disconnect_grace_ms + 1000
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Disconnected)
}
@(test)
test_attempt_row_06 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_relocating(t, f); f.ms += f.pair.service.timers.bot_relocation_wait_ms
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Deadline); delivery_expect(t, f, .Pending)
}
@(test)
test_attempt_row_07 :: proc(t: ^testing.T) {
	for status in ([]string{"accepted", "succeeded"}) {
		f := delivery_fixture(t); delivery_seed(t, f)
		a := delivery_attempt_test(f)
		bots_on_command_result(&f.pair.service, "wrong", fmt.tprintf("cmd_bot_%s", a.attempt_id), status, "")
		delivery_attempt_expect(t, f, .Sent)
		bots_on_command_result(&f.pair.service, "b1", fmt.tprintf("cmd_bot_%s", a.attempt_id), status, "")
		delivery_attempt_expect(t, f, .Accepted)
		domain.bot_delivery_attempt_destroy(&a); delivery_destroy(f)
	}
}
@(test)
test_attempt_row_08 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	bots_on_command_result(&f.pair.service, "b1", fmt.tprintf("cmd_bot_%s", a.attempt_id), "failed", "validation_failed")
	delivery_attempt_expect(t, f, .Exhausted); delivery_expect(t, f, .Pending)
	updated := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&updated)
	testing.expect(t, strings.contains(updated.report_json, "validation_failed"))
}
@(test)
test_attempt_row_09 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f); f.ms += f.pair.service.timers.bot_attempt_accept_ms
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Deadline)
}
@(test)
test_attempt_row_10 :: proc(t: ^testing.T) {
	for state in ([]domain.Bot_Attempt_State{.Sent, .Accepted}) {
		f := delivery_fixture(t); delivery_seed(t, f, state); f.ms += 1000
		delivery_report_test(t, f, "working"); delivery_attempt_expect(t, f, state)
		a := delivery_attempt_test(f)
		testing.expect_value(t, a.last_report_at, delivery_clock(f))
		domain.bot_delivery_attempt_destroy(&a); delivery_destroy(f)
	}
}
@(test)
test_attempt_row_11 :: proc(t: ^testing.T) {test_delivery_row_06(t)}
@(test)
test_attempt_row_12 :: proc(t: ^testing.T) {test_single_bridge_all_exhausted_abandons_with_gave_up(t)}
@(test)
test_attempt_row_13 :: proc(t: ^testing.T) {test_delivery_row_04(t)}
@(test)
test_attempt_row_14 :: proc(t: ^testing.T) {test_hub_restart_measures_silence_from_boot(t)}
@(test)
test_attempt_row_15 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f, .Accepted); f.ms += f.pair.service.timers.bot_attempt_total_ms + 1000
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	sync.mutex_lock(&f.pair.service.mutex)
	bots_attempt_tick_locked(&f.pair.service, a, delivery_clock(f), f.ms)
	sync.mutex_unlock(&f.pair.service.mutex)
	delivery_attempt_expect(t, f, .Deadline)
	testing.expect_value(t, len(f.frames), 1) // no stop just for a deadline
}
@(test)
test_attempt_row_16 :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f)
	delivery_disconnect(f)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	testing.expect_value(t, a.state, domain.Bot_Attempt_State.Sent)
	testing.expect_value(t, a.disconnected_at, delivery_clock(f))
}
@(test)
test_attempt_row_17 :: proc(t: ^testing.T) {test_resend_on_hello_same_command_id(t)}
@(test)
test_attempt_row_18 :: proc(t: ^testing.T) {test_disconnect_grace(t)}
@(test)
test_attempt_row_19 :: proc(t: ^testing.T) {test_delivery_row_18(t)}

@(test)
test_restart_hello_resends_without_disconnect_stamp :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f, .Accepted)
	before := len(f.frames)
	bots_on_bridge_hello(&f.pair.service, "b1")
	testing.expect_value(t, len(f.frames), before+1)
	delivery_attempt_expect(t, f, .Accepted)
}
@(test)
test_relocation_skip_survives_working_report_and_resend :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_relocating(t, f); f.op.phase = .Failed
	bots_supervisor_tick(&f.pair.service)
	delivery_report_test(t, f, "working")
	delivery_disconnect(f)
	bots_on_bridge_hello(&f.pair.service, "b1")
	frame: contracts.Bot_Deliver_Wire
	_ = json.unmarshal(transmute([]u8)f.frames[len(f.frames)-1], &frame, allocator = context.temp_allocator)
	if testing.expect_value(t, len(frame.skip), 1) do testing.expect_value(t, frame.skip[0].reason, "relocation_failed")
}

delivery_op_begin :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	f := (^Delivery_Fixture)(ctx)
	f.op = placement_clone(op)
	return placement_clone(op), true, {}
}
delivery_chain_save :: proc(ctx: rawptr, chain: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {return placement_clone(chain), true, {}}
delivery_conversation_by_instance :: proc(ctx: rawptr, owner: domain.User_ID, instance_id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {return {}, false, domain.domain_error(.Not_Found, "conversation not found")}
delivery_conversation_save :: proc(ctx: rawptr, conv: domain.Chat_Conversation) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {return placement_clone(conv), true, {}}

@(test)
test_dispatch_prepares_lazily_and_cancels_reservation :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	chains := iface.Taskchain_Repository{save_chain = delivery_chain_save}
	content := iface.Content_Repository{conversation_by_instance = delivery_conversation_by_instance, save_conversation = delivery_conversation_save}
	f.agents.taskchains, f.agents.content = &chains, &content
	_ = iface.bot_set_instance(&f.pair.repo, "bot_a", "", delivery_clock(f))
	delivery_inbound(t, f)
	bots_supervisor_tick(&f.pair.service)
	delivery_expect(t, f, .Dispatched)
	delivery_attempt_expect(t, f, .Sent)
	testing.expect(t, f.instance.agent_instance_id != "inst_a")
	testing.expect(t, f.instance.conversation_id != "" && f.instance.chain_id != "")
    testing.expect_value(t, f.instance.runtime_status, "stopped")
    testing.expect_value(t, f.instance.startup_status, "stopped")
    testing.expect_value(t, f.instance.run_count, 0)
	bot, _, _ := iface.bot_get(&f.pair.repo, "bot_a"); defer domain.bot_destroy(&bot)
	testing.expect_value(t, bot.agent_instance_id, f.instance.agent_instance_id)
	connection := project_service.bridge_runtime_connection_acquire(&f.placement.registry, "b1", 0)
	if testing.expect(t, connection != nil) {
		project_service.connection_state_lock(connection)
		_, reserved := connection.instances[f.instance.agent_instance_id]
		project_service.connection_state_unlock(connection)
		project_service.bridge_runtime_connection_release(&f.placement.registry, connection)
		testing.expect(t, !reserved)
	}
	testing.expect_value(t, len(f.frames), 1)
	testing.expect(t, strings.contains(f.frames[0], "bot_deliver"))
}

delivery_disconnect :: proc(f: ^Delivery_Fixture) {
	for &bridge in f.placement.bridges do if bridge.bridge_id == "b1" do bridge.status = .Offline
	bots_on_bridge_disconnect(&f.pair.service, "b1")
}
@(test)
test_stale_disconnect_after_hello_is_ignored :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	delivery_seed(t, f, .Accepted)
	bots_on_bridge_hello(&f.pair.service, "b1")
	bots_on_bridge_disconnect(&f.pair.service, "b1")
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	testing.expect_value(t, a.disconnected_at, "")
}

delivery_fail_acted :: proc(ctx: rawptr, d: domain.Bot_Delivery, expected: domain.Bot_Delivery_State) -> (bool, domain.Domain_Error) {
    if d.state == .Acted do return false, domain.domain_error(.Internal_Error, "injected delivery write failure")
    return sqlite.delivery_update_sqlite(ctx, d, expected)
}
@(test)
test_terminal_report_rolls_back_seq_on_storage_failure :: proc(t: ^testing.T) {
    f := delivery_fixture(t); defer delivery_destroy(f)
    delivery_seed(t, f)
    a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
    frame := fmt.tprintf(`{{"attempt_id":"%s","seq":1,"state":"acted"}}`, a.attempt_id)
    original := f.pair.repo.delivery_update
    f.pair.repo.delivery_update = delivery_fail_acted
    ack, failed := bots_on_report(&f.pair.service, "b1", frame)
    delete(ack)
    testing.expect(t, !failed && ack == "")
    current := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&current)
    testing.expect_value(t, current.state, domain.Bot_Attempt_State.Sent)
    testing.expect_value(t, current.report_seq, 0)
    f.pair.repo.delivery_update = original
    delivery_report_test(t, f, "acted")
    terminal, _, _ := iface.attempt_get(&f.pair.repo, a.attempt_id)
    defer domain.bot_delivery_attempt_destroy(&terminal)
    testing.expect_value(t, terminal.state, domain.Bot_Attempt_State.Acted)
}

@(test)
test_switch_snapshot_candidate_keeps_alias_identity :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	f.placement.models = {{bridge_id = "b1", provider = "alpha", has_snapshot = true,
	models_json = `[{"model_id":"opus","resolved_model":"claude-opus-5-5"}]`}}
	_, policy_err := bots_put_placement(&f.pair.service, "alice", 0,
	{{bridge_id = "*", provider = "alpha", model = "claude-opus-5-5", tier = .Allowed}})
	testing.expect_value(t, policy_err.code, domain.Error_Code.None)
	delivery_seed(t, f)
	a := delivery_attempt_test(f); defer domain.bot_delivery_attempt_destroy(&a)
	candidates: []contracts.Bot_Candidate_Wire
	testing.expect(t, json.unmarshal_string(a.candidates_json, &candidates) == nil)
	defer bots_candidates_destroy(candidates)
	testing.expect_value(t, len(candidates), 1)
	if len(candidates) != 1 do return
	testing.expect_value(t, candidates[0].model, "opus")
	changed, err := bots_switch(&f.pair.service, "b1", a.attempt_id, candidates[0])
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, changed.model, "opus")
	repeated, repeat_err := bots_switch(&f.pair.service, "b1", a.attempt_id, candidates[0])
	testing.expect_value(t, repeat_err.code, domain.Error_Code.None)
	testing.expect(t, !repeated.relaunched)
	testing.expect_value(t, repeated.model, "opus")
	testing.expect_value(t, repeated.configuration_revision, changed.configuration_revision)
}

delivery_support :: proc(ctx:rawptr,a,b:string)->(domain.Agent_Bridge_Support,bool,domain.Domain_Error) {return {},false,{}}


// T24: exercise the supervisor's real lazy creation and the bridge-side opening
// on its bot_deliver frame. The fixture's bridge sink captures the wire bytes.
bot_start_test_run :: proc(t: ^testing.T, first_generation: bool) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    {
        arena: virtual.Arena
        assert(virtual.arena_init_growing(&arena) == nil)
        context.allocator = virtual.arena_allocator(&arena)
        context.temp_allocator = context.allocator
        defer virtual.arena_destroy(&arena)
        f := delivery_fixture(t); defer delivery_destroy(f)
        chains := iface.Taskchain_Repository{save_chain = delivery_chain_save}
        content := iface.Content_Repository{conversation_by_instance = delivery_conversation_by_instance, save_conversation = delivery_conversation_save}
        f.agents.taskchains, f.agents.content = &chains, &content
        _ = iface.bot_set_instance(&f.pair.repo, "bot_a", "", delivery_clock(f))
        delivery_inbound(t, f)
        bots_supervisor_tick(&f.pair.service)
        delivery_expect(t, f, .Dispatched)
        testing.expect_value(t, f.instance.run_count, 0)
        testing.expect_value(t, f.instance.runtime_status, "stopped")
        testing.expect_value(t, f.instance.startup_status, "stopped")
        testing.expect_value(t, f.instance.activity_status, "unknown")
        testing.expect_value(t, f.instance.stopped_by, "")
        connection := project_service.bridge_runtime_connection_acquire(&f.placement.registry, "b1", 0)
        if testing.expect(t, connection != nil) {
            project_service.connection_state_lock(connection)
            _, reserved := connection.instances[f.instance.agent_instance_id]
            project_service.connection_state_unlock(connection)
            project_service.bridge_runtime_connection_release(&f.placement.registry, connection)
            testing.expect(t, !reserved)
        }
        if first_generation && testing.expect_value(t, len(f.frames), 1) {
            frame: contracts.Bot_Deliver_Wire
            testing.expect(t, json.unmarshal_string(f.frames[0], &frame, allocator=context.temp_allocator) == nil)
            launch, count, reused, ok, err := agent_service.start_begin_for_bridge(&f.agents, "alice", "b1", frame.agent_instance_id, fmt.tprintf("bot_%s", frame.attempt_id))
            defer delete(launch)
            testing.expect(t, ok, err.message)
            testing.expect(t, !reused)
            testing.expect_value(t, count, 1)
            wire: struct {payload: struct {run_count: int}}
            testing.expect(t, json.unmarshal_string(launch, &wire, allocator=context.temp_allocator) == nil)
            testing.expectf(t, wire.payload.run_count == 1, "first bot launch: %s", launch)
        }
    }
    testing.expect_value(t, len(track.allocation_map), 0)
}
@(test)
test_bot_instance_created_stopped :: proc(t:^testing.T) {bot_start_test_run(t,false)}
@(test)
test_bot_first_generation_is_one :: proc(t:^testing.T) {bot_start_test_run(t,true)}
