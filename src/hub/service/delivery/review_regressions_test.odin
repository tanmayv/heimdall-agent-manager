package delivery

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

review_tracking :: proc(t: ^testing.T, scenario: proc(t: ^testing.T), uses_nats: bool = false) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	scenario(t)
	if uses_nats do testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_replacement_errors_roll_back :: proc(t: ^testing.T) {review_tracking(t, replacement_errors_scenario)}
@(test)
test_final_transition_errors_leave_delivery_pending :: proc(t: ^testing.T) {review_tracking(t, final_errors_scenario)}
@(test)
test_expiry_transition_error_rolls_back :: proc(t: ^testing.T) {review_tracking(t, expiry_error_scenario)}
@(test)
test_retired_forwarder_cannot_recreate_consumer :: proc(t: ^testing.T) {review_tracking(
		t,
		retired_pass_scenario,
		true,
	)}
@(test)
test_retired_forwarders_release_capacity :: proc(t: ^testing.T) {review_tracking(t, retired_capacity_scenario)}
@(test)
test_legacy_consumer_deletions_are_deduplicated :: proc(t: ^testing.T) {review_tracking(t, deletion_dedup_scenario)}
@(test)
test_expire_due_always_prunes :: proc(t: ^testing.T) {review_tracking(t, reconnect_prune_scenario)}

// Faults are local to the test/callback thread. The real SQLite context stays
// intact, so all unmodified repository methods still use the real database.
@(thread_local)
review_transition: proc(ctx: rawptr, d: domain.Pipeline_Delivery, from: string) -> (bool, domain.Domain_Error)
@(thread_local)
review_insert: proc(ctx: rawptr, d: domain.Pipeline_Delivery) -> domain.Domain_Error
@(thread_local)
review_append: proc(ctx: rawptr, d: domain.Event_Outbox_Row) -> domain.Domain_Error
@(thread_local)
review_fail_state: string
@(thread_local)
review_fail_transition, review_fail_insert, review_fail_append: int
@(thread_local)
review_lost_cas: bool

review_transition_fault :: proc(
	ctx: rawptr,
	d: domain.Pipeline_Delivery,
	from: string,
) -> (
	bool,
	domain.Domain_Error,
) {
	if review_fail_transition > 0 && d.state == review_fail_state {
		review_fail_transition -= 1
		if review_lost_cas do return false, {}
		return false, domain.domain_error(.Internal_Error, "injected transition failure")
	}
	return review_transition(ctx, d, from)
}
review_insert_fault :: proc(ctx: rawptr, d: domain.Pipeline_Delivery) -> domain.Domain_Error {
	if review_fail_insert > 0 {
		review_fail_insert -= 1
		return domain.domain_error(.Internal_Error, "injected insert failure")
	}
	return review_insert(ctx, d)
}
review_append_fault :: proc(ctx: rawptr, d: domain.Event_Outbox_Row) -> domain.Domain_Error {
	if review_fail_append > 0 {
		review_fail_append -= 1
		return domain.domain_error(.Internal_Error, "injected outbox failure")
	}
	return review_append(ctx, d)
}
review_install_faults :: proc(f: ^Fixture) {
	review_transition = f.repos.pipeline_deliveries.transition
	review_insert = f.repos.pipeline_deliveries.insert
	review_append = f.repos.event_outbox.append
	review_fail_state = ""
	review_fail_transition = 0; review_fail_insert = 0; review_fail_append = 0; review_lost_cas = false
	f.repos.pipeline_deliveries.transition = review_transition_fault
	f.repos.pipeline_deliveries.insert = review_insert_fault
	f.repos.event_outbox.append = review_append_fault
}
review_clear_faults :: proc() {
	review_fail_transition = 0; review_fail_insert = 0; review_fail_append = 0
}

Replacement_Fault :: enum {
	Transition,
	Lost_Cas,
	Insert,
	Append,
	Callback,
}
replacement_errors_scenario :: proc(t: ^testing.T) {
	for fault in Replacement_Fault {
		for why in Replace_Why do replacement_error_case(t, fault, why)
	}
}
replacement_error_case :: proc(t: ^testing.T, fault: Replacement_Fault, why: Replace_Why) {
	f := fixture_new(t, false)
	defer fixture_destroy(f)
	id := fixture_route(t, f)
	defer delete(id)
	if why == .Fatal_Answer do fixture_set(f, id, "forwarded")
	on_bridge_online(f.s, "brg_one")
	f.replace_enabled = true
	review_install_faults(f)
	switch fault {
	case .Transition, .Lost_Cas:
		review_fail_transition = 1; review_fail_state = "replaced"; review_lost_cas = fault == .Lost_Cas
	case .Insert:
		review_fail_insert = 1
	case .Append:
		review_fail_append = 1
	case .Callback:
		f.fail_replace_after_route = true
	}
	review_replace_event(f, id, why)
	d := fixture_get(f, id)
	testing.expect_value(t, d.state, "forwarded" if why == .Fatal_Answer else "routed")
	domain.pipeline_delivery_destroy(&d)
	testing.expect_value(t, sync.atomic_load(&f.finals), i32(0))
	answers := take_answers(find_forwarder(f.s, "brg_one"))
	testing.expect(t, len(answers) == 0, "no answer after rollback")
	free_answers(answers)
	uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
	r := &uow.repos.pipeline_deliveries
	rows, err := r.open_for_bridge(r.ctx, "brg_two", "", -1)
	testing.expect(t, err.code == .None && len(rows) == 0, "replacement row rolled back")
	domain.pipeline_deliveries_destroy(rows)
	count, oe := uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
	testing.expect(t, oe.code == .None && count == 1, "replacement outbox row rolled back")
	iface.unit_of_work_rollback(&uow)
	// The same event succeeds after the transient failure, with one replacement.
	review_clear_faults(); f.fail_replace_after_route = false
	review_replace_event(f, id, why)
	d = fixture_get(f, id)
	testing.expect_value(t, d.state, "replaced")
	domain.pipeline_delivery_destroy(&d)
	assert_replacement(t, f, id)
}
review_replace_event :: proc(f: ^Fixture, id: string, why: Replace_Why) {
	switch why {
	case .Fatal_Answer:
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:1", id), `{"status":"failed","class":"fatal"}`)
	case .Bridge_Offline:
		on_bridge_offline(f.s, "brg_one")
	case .Downgrade:
		f.incapable = 1
		on_bridge_online(f.s, "brg_one")
	}
}

final_errors_scenario :: proc(t: ^testing.T) {
	for succeeded in ([2]bool{true, false}) {
		f := fixture_new(t, false)
		id := fixture_route(t, f)
		fixture_set(f, id, "forwarded")
		on_bridge_online(f.s, "brg_one")
		review_install_faults(f)
		review_fail_transition = 1; review_fail_state = "done" if succeeded else "failed"
		body := `{"status":"succeeded"}` if succeeded else `{"status":"failed","class":"fatal"}`
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:1", id), body)
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "forwarded")
		domain.pipeline_delivery_destroy(&d)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(0))
		answers := take_answers(find_forwarder(f.s, "brg_one"))
		testing.expect_value(t, len(answers), 0)
		free_answers(answers)
		review_clear_faults()
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:1", id), body)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
		delete(id); fixture_destroy(f)
	}
}
expiry_error_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, false)
	defer fixture_destroy(f)
	id := fixture_route(t, f)
	defer delete(id)
	fixture_set(f, id, "routed", 0, "2000-01-01T00:00:00Z")
	review_install_faults(f)
	review_fail_transition = 1; review_fail_state = "failed"
	expire_due(f.s)
	d := fixture_get(f, id)
	testing.expect_value(t, d.state, "routed")
	domain.pipeline_delivery_destroy(&d)
	testing.expect_value(t, sync.atomic_load(&f.finals), i32(0))
	testing.expect_value(t, sync.atomic_load(&f.s.prune_count), i64(0))
	review_clear_faults()
	expire_due(f.s)
	d = fixture_get(f, id)
	testing.expect_value(t, d.state, "failed")
	domain.pipeline_delivery_destroy(&d)
}

retired_pass_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, true)
	defer fixture_destroy(f)
	fixture_live(f)
	forwarder := find_forwarder(f.s, "brg_one")
	sync.atomic_store(&forwarder.disabled, 1)
	f.s.conn = f.client; f.s.connected = true
	testing.expect_value(t, forwarder_pass(forwarder), time.Duration(-1))
	_, err := nats.consumer_state(f.client, STREAM, "brg_brg_one")
	testing.expect(t, err.status != 0 && err.jetstream == 10014, "retirement fences consumer recreation")
	f.s.conn = nil; f.s.connected = false
}
retired_capacity_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, false)
	defer fixture_destroy(f)
	for i in 0 ..< 256 do on_bridge_online(f.s, fmt.tprintf("brg_slot_%d", i))
	testing.expect_value(t, len(f.s.forwarders), 256)
	on_bridge_deleted(f.s, "brg_slot_0")
	on_bridge_online(f.s, "brg_slot_256")
	testing.expect(t, find_forwarder(f.s, "brg_slot_256") != nil, "retirement releases a slot")
	testing.expect_value(t, sync.atomic_load(&f.s.forwarders_refused), i64(0))
	on_bridge_online(f.s, "brg_slot_257")
	testing.expect(t, find_forwarder(f.s, "brg_slot_257") == nil)
	// Reactivating retained metadata must respect the same active limit.
	on_bridge_online(f.s, "brg_slot_0")
	testing.expect_value(t, sync.atomic_load(&find_forwarder(f.s, "brg_slot_0").disabled), i32(1))
	on_bridge_deleted(f.s, "brg_slot_1")
	on_bridge_online(f.s, "brg_slot_0")
	testing.expect_value(t, sync.atomic_load(&find_forwarder(f.s, "brg_slot_0").disabled), i32(0))
}
deletion_dedup_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, false)
	defer fixture_destroy(f)
	f.incapable = 1
	for _ in 0 ..< 100 do on_bridge_online(f.s, "brg_one")
	testing.expect_value(t, len(f.s.consumer_deletions), 1)
	testing.expect_value(t, f.s.consumer_deletions[0], "brg_one")
}
reconnect_prune_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, false)
	defer fixture_destroy(f)
	sync.atomic_store(&f.s.last_prune_ms, 0x7fffffffffffffff)
	expire_due(f.s)
	expire_due(f.s)
	testing.expect_value(t, sync.atomic_load(&f.s.prune_count), i64(2))
}

Queued_Callback :: struct {
	service:    ^Service,
	command_id: string,
	done:       sync.Sema,
}
queued_callback_entry :: proc(data: rawptr) {
	call := (^Queued_Callback)(data)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	on_command_result(call.service, "brg_one", call.command_id, `{"status":"succeeded"}`)
	sync.sema_post(&call.done)
}
queued_started_scenario :: proc(t: ^testing.T, f: ^Fixture) {
	testing.expect(t, start(f.s))
	fixture_live(f)
	id := fixture_route(t, f)
	defer delete(id)
	fixture_publish(t, f)
	if !fixture_wait_frames(t, f, 1) do return
	// Freeze the NATS workers while the callback runs. A callback that tried
	// to take conn_lock would fail the bounded completion assertion.
	sync.rw_mutex_lock(&f.s.conn_lock)
	natstest.stop(&f.server)
	call := Queued_Callback {
		service    = f.s,
		command_id = fmt.tprintf("%s:1", id),
	}
	caller_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	worker := thread.create_and_start_with_data(&call, queued_callback_entry, init_context = context)
	context.allocator = caller_allocator
	completed := sync.sema_wait_with_timeout(&call.done, 2 * time.Second)
	testing.expect(t, completed, "callback completes while NATS workers are fenced")
	if completed {
		answers := take_answers(find_forwarder(f.s, "brg_one"))
		testing.expect_value(t, len(answers), 1)
		if len(answers) > 0 do testing.expect_value(t, answers[0].op, Answer_Op.Ack)
		free_answers(answers)
	}
	sync.rw_mutex_unlock(&f.s.conn_lock)
	thread.join(worker); thread.destroy(worker)
}

downgrade_replace_scenario :: proc(t: ^testing.T) {
	f := fixture_new(t, true)
	defer fixture_destroy(f)
	id := fixture_route(t, f)
	defer delete(id)
	forwarded := fixture_route(t, f, 0, "run:forwarded")
	defer delete(forwarded)
	fixture_set(f, forwarded, "forwarded")
	testing.expect(t, start(f.s))
	fixture_live(f)
	f.replace_enabled = true
	f.incapable = 1
	on_bridge_online(f.s, "brg_one")
	d := fixture_get(f, id)
	testing.expect_value(t, d.state, "replaced")
	domain.pipeline_delivery_destroy(&d)
	d = fixture_get(f, forwarded)
	testing.expect_value(t, d.state, "failed")
	testing.expect_value(t, d.reason, "bridge_too_old")
	domain.pipeline_delivery_destroy(&d)
	testing.expect_value(t, sync.atomic_load(&f.replace_calls), i32(1))
	testing.expect_value(t, f.last_replace_why, Replace_Why.Downgrade)
	testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
	uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
	r := &uow.repos.pipeline_deliveries
	found: bool
	err: domain.Domain_Error
	d, found, err = r.open_by_ref(r.ctx, "run:one")
	testing.expect(t, found && err.code == .None && d.delivery_id != id && d.bridge_id == "brg_two")
	domain.pipeline_delivery_destroy(&d)
	iface.unit_of_work_rollback(&uow)
	testing.expect(t, find_forwarder(f.s, "brg_one").worker == nil)
}
