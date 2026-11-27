package main

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

// Linux stat's starttime is a tick counter relative to boot, not wall time.
// Include the boot identity so a reboot cannot alias the retained process.
bridge_agent_process_os_read :: proc(pid: i32) -> Bridge_Agent_Process_View {
	if pid <= 0 do return {}
	raw, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.allocator)
	if err != nil {
		return {state = .Gone} if !bridge_os_pid_alive(int(pid)) else {}
	}
	defer delete(raw)
	state, group, stamp := bridge_agent_process_linux_stat(string(raw))
	if state == 0 || stamp <= 0 do return {}
	if state == 'Z' || state == 'X' do return {state = .Gone}
	boot, boot_err := os.read_entire_file("/proc/sys/kernel/random/boot_id", context.allocator)
	if boot_err != nil do return {}
	defer delete(boot)
	text := strings.trim_space(string(boot))
	if len(text) != 36 do return {}
	digest: [32]byte
	hash.hash_string_to_buffer(.SHA256, text, digest[:])
	boot_key: u64
	for byte in digest[:8] do boot_key = boot_key << 8 | u64(byte)
	return {state = .Alive, identity = {pid, stamp, i64(boot_key >> 1)}, group = group}
}

bridge_agent_process_linux_stat :: proc(text: string) -> (state: byte, group: i32, start: i64) {
	close := strings.last_index_byte(text, ')')
	if close < 0 do return
	fields := text[close+1:]
	i := 0
	for field in strings.fields_iterator(&fields) {
		switch i {
		case 0:
			if len(field) != 1 do return 0, 0, 0
			state = field[0]
		case 2:
			if number, ok := strconv.parse_i64(field); ok && number > 0 && number <= 0x7fff_ffff do group = i32(number)
		case 19:
			start, _ = strconv.parse_i64(field)
			return
		}
		i += 1
	}
	return 0, 0, 0
}

// Opening a pidfd and then checking the identity again closes PID reuse
// between the identity check and the process-group signal. On kernels before
// Linux 6.9, fail closed if group targeting is unavailable.
bridge_agent_process_kill_orphan :: proc(expected: Bridge_Agent_Process_Identity) -> bool {
	if expected.pid <= 0 || expected.pid == i32(os.get_pid()) do return false
	fd := linux.syscall(linux.SYS_pidfd_open, uintptr(expected.pid), uintptr(0))
	if fd < 0 do return false
	defer posix.close(posix.FD(fd))
	view := bridge_agent_process_os_read(expected.pid)
	if view.state != .Alive || view.identity != expected || view.group != expected.pid do return false
	PIDFD_SIGNAL_PROCESS_GROUP :: uintptr(1 << 2)
	rc := linux.syscall(linux.SYS_pidfd_send_signal, uintptr(fd), uintptr(posix.Signal.SIGKILL), uintptr(0), PIDFD_SIGNAL_PROCESS_GROUP)
	if rc != 0 do return false
	for _ in 0..<30 {
		if bridge_agent_process_match(expected, bridge_agent_process_os_read(expected.pid)) == .Gone do return true
		time.sleep(25 * time.Millisecond)
	}
	return false
}

// Scan /proc for a live process whose environment names this instance.
// Returns scanned=false when /proc cannot be listed, so callers fail closed.
bridge_agent_process_find_by_instance :: proc(id: string) -> (found: bool, view: Bridge_Agent_Process_View, scanned: bool) {
	if id == "" do return false, {}, false
	dir, open_err := os.open("/proc")
	if open_err != nil do return false, {}, false
	defer os.close(dir)
	entries, read_err := os.read_dir(dir, -1, context.temp_allocator)
	if read_err != nil do return false, {}, false
	needle := strings.concatenate({"HEIMDALL_AGENT_INSTANCE_ID=", id}, context.temp_allocator)
	self := i32(os.get_pid())
	for entry in entries {
		pid, ok := strconv.parse_i64(entry.name)
		if !ok || pid <= 0 || i32(pid) == self do continue
		raw, err := os.read_entire_file(fmt.tprintf("/proc/%d/environ", pid), context.temp_allocator)
		if err != nil do continue
		if !bridge_agent_environ_has(string(raw), needle) do continue
		v := bridge_agent_process_os_read(i32(pid))
		if v.state == .Alive do return true, v, true
	}
	return false, {}, true
}

bridge_agent_environ_has :: proc(environ, entry: string) -> bool {
	rest := environ
	for len(rest) > 0 {
		end := strings.index_byte(rest, 0)
		item := rest if end < 0 else rest[:end]
		if item == entry do return true
		if end < 0 do break
		rest = rest[end+1:]
	}
	return false
}
