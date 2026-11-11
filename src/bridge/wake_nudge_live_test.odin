#+build !windows
package main

// A daemon startup token alone cannot establish retained native configuration.
// Unknown legacy children remain alive without task-pack or PTY mutations.
// Real signed native positive delivery is covered in executor_local_native_test.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

@(test)
test_wake_nudge_line_names_lease_and_lease_next :: proc(t: ^testing.T) {
	work := bridge_wake_nudge_line("lease_1", "task_1", "worker")
	defer delete(work)
	testing.expect(t, strings.contains(work, "lease_1") && strings.contains(work, "task_1") && strings.contains(work, "ham-ctl lease next") && strings.contains(work, "work lease"), work)
	review := bridge_wake_nudge_line("lease_2", "task_2", "reviewer")
	defer delete(review)
	testing.expect(t, strings.contains(review, "review lease") && strings.contains(review, "TASK.md"), review)
	testing.expect(t, !strings.contains(review, "\n"), "one line")
}

// Without a launch record (or a generation) the nudge path declines, so the
// handler falls back to a full launch — no daemon is contacted.
@(test)
test_wake_nudge_declines_without_launch_record :: proc(t: ^testing.T) {
	testing.expect(t, !bridge_wake_nudge_live_child("t8_nudge_never_launched", "task", "worker", "lease", 3, "{}"), "no launch record → launch")
	testing.expect(t, !bridge_wake_nudge_live_child("t8_nudge_never_launched", "task", "worker", "lease", 0, "{}"), "no generation → launch")
}

@(test)
test_wake_nudge_unknown_native_admission_keeps_process_and_refuses_task_md :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	id := "t8_wake_nudge_live"
	was_started := sync.atomic_exchange(&bridge_startup_worker_started, true)
	defer sync.atomic_store(&bridge_startup_worker_started, was_started)
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, token_hash = "t8-nudge-token", instance_token = "hit_t8_wake_nudge_live", role = .Agent, run_count = 4}
	sync.mutex_lock(&bridge_local_token_mutex)
	saved_records := bridge_local_token_records
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
	append(&bridge_local_token_records, rec)
	sync.mutex_unlock(&bridge_local_token_mutex)
	defer {
		sync.mutex_lock(&bridge_local_token_mutex)
		delete(bridge_local_token_records)
		bridge_local_token_records = saved_records
		sync.mutex_unlock(&bridge_local_token_mutex)
	}
	run_dir := fmt.tprintf("/tmp/ham-t8-nudge-run-%d", os.get_pid())
	_ = bridge_make_directory_all(run_dir)
	task_md := fmt.tprintf("%s/TASK.md", run_dir)
	defer {
		_ = os.remove(task_md)
		_ = os.remove(run_dir)
	}
	bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id = id, run_dir = run_dir})
	defer bridge_runtime_remove_launch(id)

	path := fmt.aprintf("/tmp/ham-t8-nudge-%d.sock", os.get_pid())
	defer delete(path)
	_ = posix.unlink(cstring(raw_data(path)))
	defer _ = posix.unlink(cstring(raw_data(path)))
	listener := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, listener >= 0) do return
	defer posix.close(listener)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for ch, i in path do addr.sun_path[i] = c.char(ch)
	if !testing.expect(t, posix.bind(listener, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK) do return
	if !testing.expect(t, posix.listen(listener, 8) == .OK) do return
	Server :: struct {
		listener: posix.FD,
		pings, queries, inputs, keys, unexpected: int,
		stop: bool, // set by the test once the handler returned; the server never gives up on a slow client
		typed: [dynamic]byte,
	}
	server := Server{listener = listener}
	defer delete(server.typed)
	worker := bridge_thread_start_with_data(&server, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		s := (^Server)(data)
		for !sync.atomic_load(&s.stop) {
			pfd := posix.pollfd{fd = s.listener, events = {.IN}}
			if posix.poll(&pfd, 1, 50) <= 0 do continue
			fd := posix.accept(s.listener, nil, nil)
			if fd < 0 do continue
			request, ok := pty_host_read_frame(fd)
			if !ok || len(request) == 0 { posix.close(fd); continue }
			payload := make([dynamic]byte)
			reply_needed := true
			switch request[0] {
			case PTY_HOST_T_PING:
				s.pings += 1
				append(&payload, PTY_HOST_T_PONG)
			case PTY_HOST_T_STARTUP_LAUNCH:
				s.queries += 1
				off := 1
				iid, iok := pty_host_get_str(request, &off)
				key, kok := pty_host_get_str(request, &off)
				if !iok || !kok { posix.close(fd); continue }
				append(&payload, PTY_HOST_T_STARTUP_LAUNCH_REPLY)
				pty_host_put_str(&payload, iid)
				pty_host_put_i32(&payload, 321 if key == "t8-nudge-token" else 0)
				pty_host_put_str(&payload, key)
				delete(iid); delete(key)
			case PTY_HOST_T_INPUT:
				s.inputs += 1
				off := 1
				iid, iok := pty_host_get_str(request, &off)
				if iok {
					append(&s.typed, ..request[off:])
					delete(iid)
				}
				reply_needed = false
			case PTY_HOST_T_KEY:
				s.keys += 1
				reply_needed = false
			case:
				s.unexpected += 1
				append(&payload, PTY_HOST_T_ERROR)
				pty_host_put_str(&payload, "t8_wake_nudge_live")
				pty_host_put_str(&payload, "unexpected operation")
			}
			if reply_needed {
				reply := pty_host_frame(payload[:])
				_ = pty_host_send_all(fd, reply)
				delete(reply)
			}
			delete(request); delete(payload)
			posix.close(fd)
		}
	})
	defer thread.destroy(worker)
	pty_host_test_swap := pty_host_test_install_socket(path)
	defer pty_host_test_restore_socket(pty_host_test_swap)

	pack := `{"task_id":"task_t8","attempt_no":2,"task":{"title":"T8 nudge"},"brief":{"goal":"NUDGE_GOAL","acceptance":["a"]}}`
	wake := strings.concatenate({
		`{"type":"wake_agent","chain_id":"chain_t8","payload":{"run":[{"agent_instance_id":"`, id,
		`","task_id":"task_t8","role":"worker","lease_id":"lease_t8","run_count":4,"deliver":"nudge","pack":`, pack,
		`}],"stop":[]}}`,
	})
	defer delete(wake)
    journal,journal_path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(journal,journal_path)
    bridge_hub_handle_wake_agent(nil,wake,journal)
    protected:=fmt.tprintf("%s/protected_worktree",run_dir)
    canonical:=bridge_fs_canonicalize_existing(protected);defer delete(canonical)
    pack_barrier:=executor.Legacy_Barrier{"pack_source","pack_migration",contracts.owner_payload_digest("pack selection"),1}
    testing.expect_value(t,bridge_legacy_install_barrier(journal,pack_barrier,[]executor.Legacy_Resource{{"workdir_hash",contracts.owner_payload_digest(canonical)}}).code,"ok")
    denied_workdir_pack:=bridge_legacy_test_pack(run_dir,protected,"claimed_other_task","heimdall/claimed_other_task")
    testing.expect(t,bridge_wake_nudge_live_child(id,"claimed_other_task","worker","denied_workdir_lease",4,denied_workdir_pack,journal),"fenced pack keeps existing child without relaunch or typing")
    testing.expect(t,!os.exists(protected))
    barrier:=executor.Legacy_Barrier{"source_chain","migration",contracts.owner_payload_digest("verified selection"),1}
    testing.expect_value(t,bridge_legacy_install_barrier(journal,barrier,[]executor.Legacy_Resource{{"instance",id}}).code,"ok")
    denied_pack:=`{"task_id":"claimed_other_task","brief":{"goal":"DENIED_AFTER_BARRIER","acceptance":["a"]}}`
    testing.expect(t,bridge_wake_nudge_live_child(id,"claimed_other_task","worker","late_lease",4,denied_pack,journal),"late wake refused without replacement fallback")
	sync.atomic_store(&server.stop, true)
	thread.join(worker)

	testing.expect_value(t, server.unexpected, 0) // no close / spawn: the child is kept
	testing.expect_value(t, server.queries, 2)
	testing.expect(t, server.inputs == 0 && server.keys == 0, "unknown native admission cannot receive input")
	typed := string(server.typed[:])
    testing.expect(t,typed=="","no unobserved lease line is typed")
    testing.expect(t,!strings.contains(typed,"denied_workdir_lease"),"fenced pack cannot send a misleading wake line")
    testing.expect(t,!os.exists(task_md),"unknown native child cannot acquire task context")
	sync.mutex_lock(&bridge_local_token_mutex)
	testing.expect_value(t, bridge_local_token_records[0].invalidated_at_unix_ms, 0) // token not rotated
	sync.mutex_unlock(&bridge_local_token_mutex)
	launch, has := bridge_runtime_get_launch(id)
	testing.expect(t, has && launch.role == "worker", "launch record kept, role refreshed")
}
