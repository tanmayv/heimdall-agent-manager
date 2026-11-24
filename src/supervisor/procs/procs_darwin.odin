#+build darwin
package procs

import "core:sys/darwin"
import "core:sys/posix"

SZOMB :: 5 // <sys/proc.h> p_stat of an exited, unreaped process

// _stat: proc_pidinfo(PROC_PIDTBSDINFO) start time in microseconds since the epoch.
// Not found for a process we may not inspect (another user's), which is then never ours.
// proc_pidinfo does not answer for zombies (seen on macOS 15 CI), so a failure is retried
// with sysctl(KERN_PROC_PID), which does; only a zombie is reported from that fallback.
@(private)
_stat :: proc(pid: int) -> (start_time: u64, zombie: bool, found: bool) {
	info: darwin.proc_bsdinfo
	n := darwin.proc_pidinfo(posix.pid_t(pid), .BSDINFO, 0, &info, i32(size_of(info)))
	if n == i32(size_of(info)) && int(info.pbi_pid) == pid {
		return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, info.pbi_status == SZOMB, true
	}
	st, stat, ok := _kinfo(pid)
	if ok && stat == SZOMB do return st, true, true
	return
}

foreign import libsystem "system:System"

@(default_calling_convention = "c")
foreign libsystem {
	@(link_name = "sysctl")
	_sysctl :: proc(name: [^]i32, namelen: u32, oldp: rawptr, oldlenp: ^uint, newp: rawptr, newlen: uint) -> i32 ---
}

CTL_KERN :: 1
KERN_PROC :: 14
KERN_PROC_PID :: 1
// struct kinfo_proc (<sys/sysctl.h>) starts with struct extern_proc: p_un (union with
// struct timeval p_starttime, 16 bytes) @0, p_vmspace @16, p_sigacts @24, p_flag @32,
// p_stat (char) @36, p_pid @40. sizeof(struct kinfo_proc) = 648 on 64-bit.
KINFO_PROC_SIZE :: 648

// _kinfo: start time (µs) and p_stat from sysctl(KERN_PROC_PID); works for zombies.
@(private)
_kinfo :: proc(pid: int) -> (start_time: u64, stat: u32, ok: bool) {
	buf: [KINFO_PROC_SIZE / 8 + 8]u64 // 8-byte aligned
	size := uint(size_of(buf))
	mib := [4]i32{CTL_KERN, KERN_PROC, KERN_PROC_PID, i32(pid)}
	if _sysctl(&mib[0], 4, &buf[0], &size, nil, 0) != 0 || size < KINFO_PROC_SIZE do return
	raw := ([^]byte)(&buf[0])
	got_pid := (^i32)(&raw[40])^
	if int(got_pid) != pid do return
	sec := (^i64)(&raw[0])^
	usec := (^i32)(&raw[8])^
	if sec <= 0 do return
	return u64(sec) * 1_000_000 + u64(usec), u32(raw[36]), true
}

// _group_has_running_member: a non-zombie process in process group `pgid`.
@(private)
_group_has_running_member :: proc(pgid: int) -> bool {
	// Fails safe like Linux: no process list = "still running".
	n := darwin.proc_listallpids(nil, 0)
	if n <= 0 do return true
	pids := make([]i32, int(n) + 64, context.temp_allocator)
	got := darwin.proc_listallpids(raw_data(pids), i32(len(pids) * size_of(i32)))
	if got <= 0 do return true
	for pid in pids[:min(int(got), len(pids))] {
		if pid <= 0 do continue
		info: darwin.proc_bsdinfo
		r := darwin.proc_pidinfo(posix.pid_t(pid), .BSDINFO, 0, &info, i32(size_of(info)))
		if r != i32(size_of(info)) do continue
		if int(info.pbi_pgid) == pgid && info.pbi_status != SZOMB do return true
	}
	return false
}
