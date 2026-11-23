#+build linux, darwin
package e2e

import "core:sys/posix"

// hard_kill: SIGKILL (a crash the process cannot handle).
hard_kill :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), .SIGKILL) == .OK
}
