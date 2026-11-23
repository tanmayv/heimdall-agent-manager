#+build darwin
package procs

import "core:sys/darwin"
import "core:sys/posix"

SZOMB :: 5 // <sys/proc.h> p_stat of an exited, unreaped process

// _stat: proc_pidinfo(PROC_PIDTBSDINFO) start time in microseconds since the epoch.
// Not found for a process we may not inspect (another user's), which is then never ours.
@(private)
_stat :: proc(pid: int) -> (start_time: u64, zombie: bool, found: bool) {
	info: darwin.proc_bsdinfo
	n := darwin.proc_pidinfo(posix.pid_t(pid), .BSDINFO, 0, &info, i32(size_of(info)))
	if n != i32(size_of(info)) || int(info.pbi_pid) != pid do return
	return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, info.pbi_status == SZOMB, true
}

// _group_has_running_member: a non-zombie process in process group `pgid`.
@(private)
_group_has_running_member :: proc(pgid: int) -> bool {
	n := darwin.proc_listallpids(nil, 0)
	if n <= 0 do return false
	pids := make([]i32, int(n) + 64, context.temp_allocator)
	got := darwin.proc_listallpids(raw_data(pids), i32(len(pids) * size_of(i32)))
	if got <= 0 do return false
	for pid in pids[:min(int(got), len(pids))] {
		if pid <= 0 do continue
		info: darwin.proc_bsdinfo
		r := darwin.proc_pidinfo(posix.pid_t(pid), .BSDINFO, 0, &info, i32(size_of(info)))
		if r != i32(size_of(info)) do continue
		if int(info.pbi_pgid) == pgid && info.pbi_status != SZOMB do return true
	}
	return false
}
