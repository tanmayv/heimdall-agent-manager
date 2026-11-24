package card

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import taskchain_service "odin_test:hub/service/taskchain"

Projector_Order_Probe :: struct {
	h: ^Projector_Harness,
	factory: iface.Unit_Of_Work_Factory,
	owner_thread: int,
	begin_attempted, done: bool,
	stats: Attention_Reconcile_Stats,
	effects, effects_under_lock: int,
}

@(test)
test_projector_reconcile_and_task_verb_follow_tx_before_projector :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	h: Projector_Harness
	ph_open(t, &h, "projector_tx_order")
	defer ph_close(&h)
	task := ph_task("task_order", .In_Validation, "2026-10-01T00:00:00Z")
	_, seeded, _ := iface.taskchain_save_task(&h.tasks, task)
	if !testing.expect(t, seeded) do return
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	repos := iface.Repositories{taskchains=h.tasks, cards=h.cards, attention=h.attention, agents=h.agents, content=h.content}
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &h.conn, &repos)
	probe := Projector_Order_Probe{h=&h, factory=factory, owner_thread=sync.current_thread_id()}
	observed := iface.Unit_Of_Work_Factory{ctx=&probe, begin=proc(ctx: rawptr) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
		p := (^Projector_Order_Probe)(ctx)
		if sync.current_thread_id() != p.owner_thread do sync.atomic_store(&p.begin_attempted, true)
		return iface.unit_of_work_begin(&p.factory)
	}}
	h.svc.uow_factory = &observed
	h.taskchains.uow_factory = &factory
	h.engine.uow_factory = &factory
	h.svc.card_changed = {ctx=&probe, changed=proc(ctx: rawptr, owner, kind: string) {
		p := (^Projector_Order_Probe)(ctx)
		effect_uow, opened, _ := iface.unit_of_work_begin(&p.factory)
		outside_tx := opened && !effect_uow.nested
		outside_projector := sync.mutex_try_lock(&p.h.svc.projector_mutex)
		if outside_projector do sync.mutex_unlock(&p.h.svc.projector_mutex)
		if opened { _, _ = iface.unit_of_work_commit(&effect_uow) }
		if !outside_tx || !outside_projector do sync.atomic_add(&p.effects_under_lock, 1)
		sync.atomic_add(&p.effects, 1)
	}}
	uow, opened, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, opened) do return
	worker := thread.create_and_start_with_data(&probe, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		p := (^Projector_Order_Probe)(data)
		p.stats = reconcile_attention(&p.h.svc)
		sync.atomic_store(&p.done, true)
	})
	// Before the fix B owns projector_mutex and waits for A transaction gate.
	// Detect that order with a bounded try-lock rather than hanging the runner
	// by making A wait for the same mutex. Rollback then lets B unwind safely.
	deadline := time.tick_now()._nsec + i64(2*time.Second)
	inverted := false
	for !sync.atomic_load(&probe.begin_attempted) && time.tick_now()._nsec < deadline {
		if sync.mutex_try_lock(&h.svc.projector_mutex) {
			sync.mutex_unlock(&h.svc.projector_mutex)
		} else { inverted = true; break }
		time.sleep(time.Millisecond)
	}
	ordered := !inverted && sync.atomic_load(&probe.begin_attempted)
	testing.expect(t, ordered, "reconciliation waits for the UoW before taking projector_mutex")
	if ordered {
		_, _, commented, err := taskchain_service.comment_task(&h.taskchains, {kind=.Internal_User, user_id=string(PH_OWNER)}, {task_id=task.task_id, body="while reconciliation waits"})
		testing.expect(t, commented, err.message)
		testing.expect_value(t, sync.atomic_load(&probe.effects), 0)
		committed, commit_err := iface.unit_of_work_commit(&uow)
		testing.expect(t, committed, commit_err.message)
	} else { iface.unit_of_work_rollback(&uow) }
	deadline = time.tick_now()._nsec + i64(2*time.Second)
	for !sync.atomic_load(&probe.done) && time.tick_now()._nsec < deadline do time.sleep(time.Millisecond)
	testing.expect(t, sync.atomic_load(&probe.done), "reconciliation completes within deadline")
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, probe.stats.failed, 0)
	testing.expect(t, probe.effects > 0)
	testing.expect_value(t, probe.effects_under_lock, 0)
}

@(test)
test_projector_change_notification_waits_for_outer_commit_and_discards_rollback :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	h: Projector_Harness
	ph_open(t, &h, "projector_commit_notifications")
	defer ph_close(&h)
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &h.conn, nil)
	h.svc.uow_factory = &factory
	task := ph_task("task_effect", .In_Validation, "2026-10-01T00:00:00Z")
	_, seeded, _ := iface.taskchain_save_task(&h.tasks, task)
	if !testing.expect(t, seeded) do return
	uow, opened, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, opened) do return
	projected, err := project_task_card(&h.svc, PH_OWNER, task.task_id)
	testing.expect(t, projected, err.message)
	testing.expect_value(t, len(h.changed_kinds), 0)
	iface.unit_of_work_rollback(&uow)
	_, exists, _ := iface.card_get(&h.cards, attention_task_card_id(task.task_id))
	testing.expect(t, !exists, "rolled-back projection has no durable card")
	testing.expect_value(t, len(h.changed_kinds), 0)
	projected, err = project_task_card(&h.svc, PH_OWNER, task.task_id)
	testing.expect(t, projected, err.message)
	testing.expect(t, len(h.changed_kinds) > 0, "committed projection notifies")
}
