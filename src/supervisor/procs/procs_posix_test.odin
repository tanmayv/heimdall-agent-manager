#+build linux, darwin, freebsd, openbsd, netbsd
package procs

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// Agent: a child that leads its own process group (like the supervisor's children, §2)
// and starts a helper in that group.
Agent :: struct {
	ok:     bool,
	target: Target,
	helper: Id,
}

// spawn_sh forks a group leader running `sh -c script`; `$HELPER` in the script is the
// file the helper pid is written to.
@(private = "file")
spawn_sh :: proc(t: ^testing.T, dir, name, script: string) -> (a: Agent) {
	helper_file := strings.concatenate({dir, "/", name, ".helper"}, context.temp_allocator)
	full := strings.concatenate({"HELPER='", helper_file, "'; ", script}, context.temp_allocator)
	argv := []cstring{"sh", "-c", strings.clone_to_cstring(full, context.temp_allocator), nil}
	// The child waits on `gate` (one byte) before exec until the parent has recorded its identity, as a
	// real spawner records (pid, start_time) before the child can run (and exit).
	gate: [2]posix.FD
	if posix.pipe(&gate) != .OK do testing.fail_now(t, "pipe")
	pid := posix.fork()
	if pid == 0 {
		posix.setpgid(0, 0)
		posix.close(gate[1])
		b: [1]byte
		posix.read(gate[0], &b[0], 1)
		posix.close(gate[0])
		posix.execv("/bin/sh", raw_data(argv))
		posix._exit(127)
	}
	posix.close(gate[0])
	if pid < 0 {
		posix.close(gate[1])
		testing.fail_now(t, "fork")
	}
	posix.setpgid(pid, pid) // close the race with the child's own setpgid
	id, ok := identify(int(pid))
	// A byte, not EOF: children forked concurrently by other tests may still hold copies
	// of gate[1] until their own exec, and waiting for EOF could deadlock them pairwise.
	release := [1]byte{1}
	posix.write(gate[1], &release[0], 1)
	posix.close(gate[1])
	testing.expect(t, ok, "identify child")
	a.target = Target{id, true}
	// Wait for the helper pid.
	for _ in 0 ..< 250 {
		data, err := os.read_entire_file(helper_file, context.temp_allocator)
		if err == nil && strings.has_suffix(string(data), "\n") {
			hp, parsed := strconv.parse_int(strings.trim_space(string(data)), 10)
			if parsed {
				a.helper, a.ok = identify(hp)
				break
			}
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, a.ok, "%s: helper did not start", name)
	return
}

spawn_agent :: proc(t: ^testing.T, dir, name: string) -> Agent {
	return spawn_sh(t, dir, name, `sleep 300 & echo $! > "$HELPER"; wait`)
}

// cleanup_agent: kill whatever is left (only these recorded processes) and reap the leader.
cleanup_agent :: proc(a: ^Agent) {
	if a.target.id.pid <= 0 do return
	if a.helper.pid > 0 && alive(a.helper) do posix.kill(posix.pid_t(a.helper.pid), .SIGKILL)
	if alive(a.target.id) do posix.kill(-posix.pid_t(a.target.id.pid), .SIGKILL)
	status: i32
	posix.waitpid(posix.pid_t(a.target.id.pid), &status, {})
	a.target = {}
}

// wait_gone: the helper (not our child: reaped by init / a subreaper) disappears.
wait_gone :: proc(id: Id) -> bool {
	for _ in 0 ..< 250 {
		if !alive(id) do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}

// Agents that ignore SIGTERM (an ignored signal stays ignored across exec) are killed after
// the grace period.
@(test)
test_stop_escalates_after_grace :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "t14-procs-term-*", context.temp_allocator)
	defer os.remove_all(dir)
	a := spawn_sh(t, dir, "deaf", `trap '' TERM; sleep 300 & echo $! > "$HELPER"; wait`)
	defer cleanup_agent(&a)
	if !a.ok do return
	start := time.tick_now()
	r := stop([]Target{a.target}, grace_ms = 500, wait_ms = 10_000)
	elapsed := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, r.survivors, 0)
	testing.expectf(t, elapsed >= 450, "SIGKILL only after the grace period (%.0f ms)", elapsed)
	testing.expect(t, wait_gone(a.helper), "helper killed with the group")
}

// The group leader already exited (reaped or still a zombie) but a helper of its group
// still runs: stop reaches it through the group, and nothing else.
@(test)
test_stop_reaches_orphaned_group_members :: proc(t: ^testing.T) {
	for reap_leader in ([]bool{false, true}) {
		base, _ := os.temp_directory(context.temp_allocator)
		dir, _ := os.make_directory_temp(base, "t14-procs-orphan-*", context.temp_allocator)
		a := spawn_sh(t, dir, "orphan", `sleep 300 & echo $! > "$HELPER"; exit 0`)
		other := spawn_agent(t, dir, "other")
		if a.ok && other.ok {
			// Leader exits right after writing the helper pid.
			for _ in 0 ..< 250 {
				if !alive(a.target.id) do break
				time.sleep(20 * time.Millisecond)
			}
			if reap_leader {
				status: i32
				posix.waitpid(posix.pid_t(a.target.id.pid), &status, {})
			}
			testing.expectf(t, !alive(a.target.id), "reap=%v: leader exited", reap_leader)
			testing.expectf(t, alive(a.helper), "reap=%v: helper still runs", reap_leader)
			if !running(a.target) {
				when ODIN_OS == .Linux {
					st, _ := os.read_entire_file(fmt.tprintf("/proc/%d/stat", a.helper.pid), context.temp_allocator)
					lst, _ := os.read_entire_file(fmt.tprintf("/proc/%d/stat", a.target.id.pid), context.temp_allocator)
					testing.expectf(t, false, "DEBUG reap=%v helper %v stat=%q leader %v stat=%q scan=%v orphans=%v running=%v", reap_leader, a.helper, string(st), a.target.id, string(lst), _group_has_running_member(a.target.id.pid), _group_orphans_alive(a.target.id), running(a.target))
				} else {
					testing.expectf(t, false, "reap=%v: the group counts as running", reap_leader)
				}
			}
			r := stop([]Target{a.target}, grace_ms = 2000, wait_ms = 5000)
			testing.expectf(t, r.signalled == 1 && r.survivors == 0, "reap=%v: %v", reap_leader, r)
			testing.expectf(t, wait_gone(a.helper), "reap=%v: orphaned helper stopped", reap_leader)
			testing.expectf(t, alive(other.target.id) && alive(other.helper), "reap=%v: the other instance is untouched", reap_leader)
		}
		cleanup_agent(&other)
		cleanup_agent(&a)
		os.remove_all(dir)
	}
	_ = fmt.tprintf
}

// A long stop (leader gone, a TERM-ignoring group member survives the whole grace, so every
// 20 ms poll scans the process table) must not allocate from the caller's temp allocator.
@(test)
test_stop_keeps_caller_temp_flat :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "t14-procs-mem-*", context.temp_allocator)
	defer os.remove_all(dir)
	a := spawn_sh(t, dir, "deaf-orphan", `trap '' TERM; sleep 300 & echo $! > "$HELPER"; exit 0`)
	defer cleanup_agent(&a)
	if !a.ok do return
	for _ in 0 ..< 250 {
		if !alive(a.target.id) do break
		time.sleep(20 * time.Millisecond)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	r: Stop_Result
	{
		context.temp_allocator = mem.tracking_allocator(&track)
		r = stop([]Target{a.target}, grace_ms = 1500, wait_ms = 10_000)
	}
	testing.expect_value(t, r.survivors, 0)
	if !wait_gone(a.helper) {
		when ODIN_OS == .Linux {
			st, _ := os.read_entire_file(fmt.tprintf("/proc/%d/stat", a.helper.pid), context.temp_allocator)
			lst, _ := os.read_entire_file(fmt.tprintf("/proc/%d/stat", a.target.id.pid), context.temp_allocator)
			testing.expectf(t, false, "DEBUG helper %v stat=%q leader %v stat=%q scan=%v orphans=%v r=%v", a.helper, string(st), a.target.id, string(lst), _group_has_running_member(a.target.id.pid), _group_orphans_alive(a.target.id), r)
		} else {
			testing.expect(t, false, "member killed after the grace")
		}
	}
	testing.expectf(t, track.total_allocation_count == 0, "stop allocated %d times (%d bytes peak) from the caller's temp allocator", track.total_allocation_count, track.peak_memory_allocated)
	_ = fmt.tprintf
}
