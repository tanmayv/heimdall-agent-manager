#+build windows
package procs

import "core:os"
import "core:testing"
import "core:time"

// Agent: a long-running child process. Windows has no process groups; helpers live in the
// instance's job object (T13b), so `helper` is a second recorded process.
Agent :: struct {
	ok:      bool,
	target:  Target,
	helper:  Id,
	process: os.Process,
	extra:   os.Process,
}

@(private = "file")
spawn_ping :: proc(t: ^testing.T) -> (os.Process, Id, bool) {
	p, err := os.process_start({command = {"ping.exe", "-n", "300", "127.0.0.1"}})
	if err != nil {
		testing.expectf(t, false, "process_start: %v", err)
		return {}, {}, false
	}
	id, ok := identify(int(p.pid))
	testing.expect(t, ok, "identify child")
	return p, id, ok
}

spawn_agent :: proc(t: ^testing.T, dir, name: string) -> (a: Agent) {
	ok1, ok2: bool
	a.process, a.target.id, ok1 = spawn_ping(t)
	a.extra, a.helper, ok2 = spawn_ping(t)
	a.ok = ok1 && ok2
	return
}

cleanup_agent :: proc(a: ^Agent) {
	for p in ([]os.Process{a.process, a.extra}) {
		if p.handle == 0 do continue
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
	}
	a^ = {}
}

wait_gone :: proc(id: Id) -> bool {
	for _ in 0 ..< 250 {
		if !alive(id) do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}

// Both recorded processes of one instance are stopped (hard stop after the grace period).
@(test)
test_stop_windows_helpers_recorded :: proc(t: ^testing.T) {
	a := spawn_agent(t, "", "a")
	b := spawn_agent(t, "", "b")
	defer cleanup_agent(&b)
	defer cleanup_agent(&a)
	if !a.ok || !b.ok do return
	r := stop([]Target{a.target, {id = a.helper}}, grace_ms = 200, wait_ms = 10_000)
	testing.expect_value(t, r.signalled, 2)
	testing.expect_value(t, r.survivors, 0)
	testing.expect(t, wait_gone(a.helper))
	testing.expect(t, alive(b.target.id) && alive(b.helper), "the other instance is untouched")
}
