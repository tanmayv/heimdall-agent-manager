package http

import "core:mem/virtual"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import agent "odin_test:hub/service/agent"
import sqlite "odin_test:hub/repository/sqlite"
import lockorder "odin_test:lib/lockorder"

Runtime_Persist_Test :: struct {
	arena: virtual.Arena,
	allocator: mem.Allocator,
	t: ^testing.T,
	violations_before: int,
	fixture: ^wire_fixture,
	registry: project.Bridge_Runtime_Registry,
	factory_impl: sqlite.SQLite_Unit_Of_Work_Factory,
	factory: iface.Unit_Of_Work_Factory,
	handlers: Bridge_Handlers,
	generation: int,
}

runtime_persist_test_open :: proc(t: ^testing.T) -> ^Runtime_Persist_Test {
	f := new(Runtime_Persist_Test)
	f.allocator = context.allocator
	_ = virtual.arena_init_growing(&f.arena)
	// wire_setup returns only part of its login/seed results. Own the entire
	// fixture request lifetime, including user rows and envelope buffers.
	context.allocator = virtual.arena_allocator(&f.arena)
	context.temp_allocator = context.allocator
	f.t = t
	f.violations_before = sync.atomic_load(&lockorder.violations)
	f.fixture = wire_setup(t, "runtime_persist")
	f.factory = sqlite.new_unit_of_work_factory(&f.factory_impl, &f.fixture.conn, nil)
	f.handlers = Bridge_Handlers{uow_factory=&f.factory, bridges=&f.fixture.br_svc, agents=&f.fixture.ag_svc, bridge_runtime_registry=&f.registry}
	row, found, _ := iface.bridge_get_bridge(&f.fixture.br_repo, f.fixture.bridge_pin)
	testing.expect(t, found)
	defer domain.bridge_destroy(&row)
	hello, connected, ok, err := bridge_admit_hello(&f.handlers, row, f.fixture.bridge_token, "first", "linux", "amd64", `{"protocol_version":2,"capabilities":[]}`, "", "", "", "")
	testing.expect(t, ok, err.message)
	domain.bridge_destroy(&connected)
	f.generation = hello.generation
	return f
}

runtime_persist_test_close :: proc(f: ^Runtime_Persist_Test) {
	context.allocator = virtual.arena_allocator(&f.arena)
	context.temp_allocator = context.allocator
	project.bridge_runtime_registry_destroy(&f.registry)
	wire_teardown(f.fixture)
	testing.expect(f.t, sync.atomic_load(&lockorder.violations) == f.violations_before, "runtime persistence preserves lock order")
	allocator := f.allocator
	virtual.arena_destroy(&f.arena)
	free(f, allocator)
}

Runtime_Persist_Job :: struct {
	f: ^Runtime_Persist_Test,
	operation: proc(^Runtime_Persist_Test) -> bool,
	started, done, ok: bool,
}

runtime_persist_job_start :: proc(job: ^Runtime_Persist_Job) -> ^thread.Thread {
	return thread.create_and_start_with_data(job, proc(data: rawptr) {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator
		j := (^Runtime_Persist_Job)(data)
		sync.atomic_store(&j.started, true)
		j.ok = j.operation(j.f)
		sync.atomic_store(&j.done, true)
	})
}

runtime_persist_test_disconnect :: proc(f: ^Runtime_Persist_Test) -> bool {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	c := project.bridge_runtime_connection_acquire(&f.registry, f.fixture.bridge_pin, f.generation)
	defer project.bridge_runtime_connection_release(&f.registry, c)
	row, _, instances, current := bridge_disconnect_persist(&f.handlers, c)
	domain.bridge_destroy(&row)
	domain.agent_instances_destroy(instances)
	return current
}

runtime_persist_test_reconnect :: proc(f: ^Runtime_Persist_Test) -> bool {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	row, found, _ := iface.bridge_get_bridge(&f.fixture.br_repo, f.fixture.bridge_pin)
	if !found do return false
	defer domain.bridge_destroy(&row)
	_, connected, ok, _ := bridge_admit_hello(&f.handlers, row, f.fixture.bridge_token, "newest", "linux", "amd64", `{"protocol_version":2,"capabilities":[]}`, "", "", "", "")
	domain.bridge_destroy(&connected)
	return ok
}

runtime_persist_expect_newest :: proc(t: ^testing.T, f: ^Runtime_Persist_Test) {
	row, found, _ := iface.bridge_get_bridge(&f.fixture.br_repo, f.fixture.bridge_pin)
	defer domain.bridge_destroy(&row)
	testing.expect(t, found && row.status == .Online && row.machine_hostname == "newest", "newest admission owns durable bridge state")
}

runtime_persist_expect_rollback :: proc(t: ^testing.T, f: ^Runtime_Persist_Test, operation: proc(^Runtime_Persist_Test) -> bool) {
	uow, opened, _ := iface.unit_of_work_begin(&f.factory)
	if !testing.expect(t, opened) do return
	job := Runtime_Persist_Job{f=f, operation=operation}
	worker := runtime_persist_job_start(&job)
	for !sync.atomic_load(&job.started) do time.sleep(time.Millisecond)
	time.sleep(30*time.Millisecond)
	testing.expect(t, !sync.atomic_load(&job.done), "runtime persistence must wait for the owning UoW")
	// A UoW can still reserve capacity: the blocked writer holds no state_mutex.
	_, reserved, err := project.bridge_runtime_instance_apply(&f.registry, f.fixture.bridge_pin, f.generation, "reservation", string(f.fixture.owner), "starting", "idle", 1, reserve=true)
	testing.expect(t, reserved, err.message)
	iface.unit_of_work_rollback(&uow)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, job.ok, "runtime write committed after foreign rollback")
}

@(test)
test_runtime_status_survives_foreign_uow_rollback :: proc(t: ^testing.T) {
	f := runtime_persist_test_open(t)
	defer runtime_persist_test_close(f)
	runtime_persist_expect_rollback(t, f, proc(f: ^Runtime_Persist_Test) -> bool {
		row, applied, err := bridge_apply_validated_status(&f.handlers, f.fixture.bridge_pin, f.generation, f.fixture.instance_id, 12, "running", "busy")
		defer domain.agent_instance_destroy(&row)
		return applied && err.code == .None
	})
	row, found, _ := iface.agent_get_instance(&f.fixture.ag_repo, f.fixture.instance_id)
	defer domain.agent_instance_destroy(&row)
	testing.expect(t, found && row.last_applied_seq == 12 && row.activity_status == "busy")
}

@(test)
test_runtime_disconnect_survives_foreign_uow_rollback :: proc(t: ^testing.T) {
	f := runtime_persist_test_open(t)
	defer runtime_persist_test_close(f)
	runtime_persist_expect_rollback(t, f, runtime_persist_test_disconnect)
	row, found, _ := iface.bridge_get_bridge(&f.fixture.br_repo, f.fixture.bridge_pin)
	defer domain.bridge_destroy(&row)
	inst, got, _ := iface.agent_get_instance(&f.fixture.ag_repo, f.fixture.instance_id)
	defer domain.agent_instance_destroy(&inst)
	testing.expect(t, found && row.status == .Offline)
	testing.expect(t, got && inst.runtime_status == "unreachable")
}

@(test)
test_runtime_new_admission_overwrites_prior_disconnect :: proc(t: ^testing.T) {
	f := runtime_persist_test_open(t)
	defer runtime_persist_test_close(f)
	testing.expect(t, runtime_persist_test_disconnect(f))
	testing.expect(t, runtime_persist_test_reconnect(f))
	runtime_persist_expect_newest(t, f)
	testing.expect(t, !runtime_persist_test_disconnect(f), "old generation writes nothing after retirement")
	runtime_persist_expect_newest(t, f)
}

@(test)
test_runtime_concurrent_reconnect_and_disconnect_keeps_newest :: proc(t: ^testing.T) {
	f := runtime_persist_test_open(t)
	defer runtime_persist_test_close(f)
	job := Runtime_Persist_Job{f=f, operation=runtime_persist_test_disconnect}
	worker := runtime_persist_job_start(&job)
	testing.expect(t, runtime_persist_test_reconnect(f))
	thread.join(worker)
	thread.destroy(worker)
	runtime_persist_expect_newest(t, f)
}

@(test)
test_runtime_concurrent_reports_keep_terminal_sequence :: proc(t: ^testing.T) {
	f := runtime_persist_test_open(t)
	defer runtime_persist_test_close(f)
	seed, found, _ := iface.agent_get_instance(&f.fixture.ag_repo, f.fixture.instance_id)
	if !testing.expect(t, found) do return
	defer domain.agent_instance_destroy(&seed)
	seed.run_count = max(1, seed.run_count)
	if _, saved, _ := iface.agent_save_instance(&f.fixture.ag_repo, seed); !testing.expect(t, saved) do return
	proof := agent.Process_Exit_Evidence{pid = 42, exit_code = 0, run_count = seed.run_count}
	job := Runtime_Persist_Job{f=f, operation=proc(f: ^Runtime_Persist_Test) -> bool {
		row, _, err := bridge_apply_validated_status(&f.handlers, f.fixture.bridge_pin, f.generation, f.fixture.instance_id, 10, "running", "busy")
		domain.agent_instance_destroy(&row)
		return err.code == .None
	}}
	worker := runtime_persist_job_start(&job)
	row, applied, err := bridge_apply_validated_status(&f.handlers, f.fixture.bridge_pin, f.generation, f.fixture.instance_id, 11, "stopped", "idle", reason = "pty_child_exited", process_exit = &proof)
	domain.agent_instance_destroy(&row)
	testing.expect(t, applied && err.code == .None)
	thread.join(worker)
	thread.destroy(worker)
	row, applied, err = iface.agent_get_instance(&f.fixture.ag_repo, f.fixture.instance_id)
	defer domain.agent_instance_destroy(&row)
	testing.expect(t, applied && row.last_applied_seq == 11 && row.runtime_status == "stopped")
}
