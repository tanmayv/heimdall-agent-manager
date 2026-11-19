package http

import "core:mem/virtual"
import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import sqlite "odin_test:hub/repository/sqlite"

// Status frames write durable state while holding state_mutex. A matcher UoW
// must be able to reserve runtime capacity concurrently, without holding db_mutex
// while it waits for state_mutex. Bounded try-lock makes the old ABBA fail the
// assertion and unwind, rather than hanging the runner with two blocked threads.
@(test)
test_uow_runtime_reservation_and_state_locked_write_do_not_deadlock :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	f := wire_setup(t, "uow_runtime_locks")
	defer wire_teardown(f)
	registry: project.Bridge_Runtime_Registry
	defer project.bridge_runtime_registry_destroy(&registry)
	_, generation, online := project.bridge_runtime_registry_accept_live(&registry, f.bridge_pin, false, "", string(f.owner))
	if !testing.expect(t, online) do return
	connection := project.bridge_runtime_connection_acquire(&registry, f.bridge_pin, generation)
	if !testing.expect(t, connection != nil) do return
	defer project.bridge_runtime_connection_release(&registry, connection)

	Job :: struct {
		connection: ^project.Bridge_Runtime_Connection,
		conn: ^sqlite.Conn,
		repo: ^iface.Agent_Repository,
		instance_id: string,
		state_locked, begin_done, wrote: bool,
	}
	job := Job{connection=connection, conn=&f.conn, repo=&f.ag_repo, instance_id=f.instance_id}
	worker := thread.create_and_start_with_data(&job, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		j := (^Job)(data)
		project.connection_state_lock(j.connection)
		defer project.connection_state_unlock(j.connection)
		sync.atomic_store(&j.state_locked, true)
		deadline := time.tick_now()._nsec + i64(2*time.Second)
		for !sync.atomic_load(&j.begin_done) {
			if time.tick_now()._nsec >= deadline do return
			time.sleep(time.Millisecond)
		}
		mutex := sqlite.sqlite3_db_mutex(j.conn.db)
		for sqlite.sqlite3_mutex_try(mutex) != sqlite.SQLITE_OK {
			if time.tick_now()._nsec >= deadline do return
			time.sleep(time.Millisecond)
		}
		defer sqlite.sqlite3_mutex_leave(mutex)
		inst, found, err := iface.agent_get_instance(j.repo, j.instance_id)
		defer domain.agent_instance_destroy(&inst)
		if !found || err.code != .None do return
		_, saved, save_err := iface.agent_save_instance(j.repo, inst)
		sync.atomic_store(&j.wrote, saved && save_err.code == .None)
	})
	defer {thread.join(worker); thread.destroy(worker)}
	deadline := time.tick_now()._nsec + i64(2*time.Second)
	for !sync.atomic_load(&job.state_locked) && time.tick_now()._nsec < deadline do time.sleep(time.Millisecond)
	if !testing.expect(t, sync.atomic_load(&job.state_locked)) do return
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory
	factory := sqlite.new_unit_of_work_factory(&factory_impl, &f.conn, nil)
	uow, begun, _ := iface.unit_of_work_begin(&factory)
	sync.atomic_store(&job.begin_done, true)
	if !testing.expect(t, begun) do return
	_, reserved, err := project.bridge_runtime_instance_apply(&registry, f.bridge_pin, generation, "inst_reserve", string(f.owner), "starting", "idle", 1, reserve=true)
	testing.expect(t, reserved, err.message)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	testing.expect(t, sync.atomic_load(&job.wrote), "state-locked repository write must complete while UoW reserves capacity")
}
