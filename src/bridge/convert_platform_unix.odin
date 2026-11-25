#+build linux, darwin, freebsd, openbsd, netbsd
package main

import "core:fmt"
import "core:sys/posix"

// Platform seams of the conversion (parent process, owner, disk space, signals).

bridge_convert_parent_pid :: proc() -> int {
	return int(posix.getppid())
}

bridge_convert_owner_json :: proc() -> string {
	return fmt.tprintf(`{{"uid":%d}}`, posix.geteuid())
}

bridge_convert_windows_sid :: proc() -> string {
	return ""
}

bridge_convert_free_bytes :: proc(dir: string) -> i64 {
	return -1 // unknown: the disk_full refusal is applied where the platform can say
}

// Set by SIGTERM/SIGINT/SIGHUP; polled between steps (spec §6.2).
bridge_convert_signalled: bool

@(private = "file")
bridge_convert_on_signal :: proc "c" (sig: posix.Signal) {
	bridge_convert_signalled = true
}

bridge_convert_install_signal_handlers :: proc() {
	act: posix.sigaction_t
	act.sa_handler = bridge_convert_on_signal
	posix.sigemptyset(&act.sa_mask)
	for sig in ([]posix.Signal{.SIGTERM, .SIGINT, .SIGHUP}) do _ = posix.sigaction(sig, &act, nil)
}
