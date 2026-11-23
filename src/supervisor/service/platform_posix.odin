#+build linux, darwin
package service

// POSIX process plumbing of ham-supervisor (spec §7.1, §7.3): SIGTERM/SIGINT from the
// launcher (forwarded to the supervisor's process group) is the graceful stop; READY is
// written once to the inherited fd 3 (`--ready-fd`), which is then closed.

import "base:intrinsics"
import "core:strconv"
import "core:sys/posix"

@(private = "file") g_stop: i32

@(private = "file")
on_stop :: proc "c" (sig: posix.Signal) {
	intrinsics.atomic_store(&g_stop, 1)
	intrinsics.atomic_store(&g_net_cancel, true)
}

// stop_init installs the stop handlers. `instance_id` names the Windows stop event.
stop_init :: proc(instance_id: string) -> bool {
	act: posix.sigaction_t
	act.sa_handler = on_stop
	posix.sigemptyset(&act.sa_mask)
	if posix.sigaction(.SIGTERM, &act, nil) != .OK do return false
	if posix.sigaction(.SIGINT, &act, nil) != .OK do return false
	ign: posix.sigaction_t
	ign.sa_handler = auto_cast posix.SIG_IGN
	posix.sigemptyset(&ign.sa_mask)
	posix.sigaction(.SIGPIPE, &ign, nil)
	return true
}

stop_requested_flag :: proc() -> bool {
	return intrinsics.atomic_load(&g_stop) != 0
}

// note_stop: an internal stop (tests).
note_stop :: proc() {
	intrinsics.atomic_store(&g_stop, 1)
	intrinsics.atomic_store(&g_net_cancel, true)
}

// write_ready writes the READY line to the inherited descriptor and closes it.
write_ready :: proc(fd_text, line: string) -> bool {
	fd, ok := strconv.parse_int(fd_text, 10)
	if !ok || fd < 0 do return false
	data := transmute([]byte)line
	for len(data) > 0 {
		n := posix.write(posix.FD(fd), raw_data(data), uint(len(data)))
		if n < 0 {
			if posix.errno() == .EINTR do continue
			posix.close(posix.FD(fd))
			return false
		}
		data = data[n:]
	}
	posix.close(posix.FD(fd))
	return true
}

// close_ready_fd: a launch that exits without READY (75, 78) closes the pipe unwritten.
close_ready_fd :: proc(fd_text: string) {
	if fd, ok := strconv.parse_int(fd_text, 10); ok && fd >= 0 do posix.close(posix.FD(fd))
}

// mark_ready_fd_cloexec: the READY pipe and lifeline ends must never reach a child (§2.1).
mark_ready_fd_cloexec :: proc(fd_text: string) {
	if fd, ok := strconv.parse_int(fd_text, 10); ok && fd >= 0 {
		posix.fcntl(posix.FD(fd), .SETFD, i32(posix.FD_CLOEXEC))
	}
}
