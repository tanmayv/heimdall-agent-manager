#+build windows
package runtimectl

import "core:os"
import "core:testing"
import "../procs"

Session :: struct {
	ok:      bool,
	id:      procs.Id,
	process: os.Process,
}

spawn_session :: proc(t: ^testing.T) -> (s: Session) {
	p, err := os.process_start({command = {"ping.exe", "-n", "300", "127.0.0.1"}})
	if err != nil {
		testing.expectf(t, false, "process_start: %v", err)
		return
	}
	s.process = p
	s.id, s.ok = procs.identify(int(p.pid))
	testing.expect(t, s.ok, "identify session")
	return
}

cleanup_session :: proc(s: ^Session) {
	if s.process.handle == 0 do return
	_ = os.process_kill(s.process)
	_, _ = os.process_wait(s.process)
	s^ = {}
}
