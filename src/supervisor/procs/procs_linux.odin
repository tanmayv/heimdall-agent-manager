#+build linux
package procs

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// _stat: /proc/<pid>/stat field 22 (starttime, clock ticks since boot). The comm
// field (2) may contain spaces and ')' so fields are counted after the LAST ')'.
// `zombie`: state 'Z' / 'X' (exited, not reaped; not running).
@(private)
_stat :: proc(pid: int) -> (start_time: u64, zombie: bool, found: bool) {
	start_time, zombie, _, found = _stat_full(pid)
	return
}

// _stat_full: _stat plus field 5 (pgrp).
@(private)
_stat_full :: proc(pid: int) -> (start_time: u64, zombie: bool, pgrp: int, found: bool) {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil do return
	text := string(data)
	close := strings.last_index_byte(text, ')')
	if close < 0 || close + 2 >= len(text) do return
	rest := text[close + 2:] // "S ppid pgrp …": field 3 onwards
	field := 3
	for part in strings.split_iterator(&rest, " ") {
		if field == 3 do zombie = part == "Z" || part == "X"
		if field == 5 do pgrp, _ = strconv.parse_int(part, 10)
		if field == 22 {
			start_time, found = strconv.parse_u64(part, 10)
			return
		}
		field += 1
	}
	return
}

// _group_has_running_member: a non-zombie process in process group `pgid` (/proc scan).
// Fails safe: an unreadable /proc counts as "still running" (stop keeps escalating and
// reports survivors) rather than "gone". Plain readdir, not core:os directory reading:
// that stats every entry and ended the listing early when a pid exited mid-scan, which
// made a live group member look gone (intermittent, seen in local loops).
@(private)
_group_has_running_member :: proc(pgid: int) -> bool {
	dir := posix.opendir("/proc")
	if dir == nil do return true
	defer posix.closedir(dir)
	for {
		ent := posix.readdir(dir)
		if ent == nil do break
		name := string(cstring(&ent.d_name[0]))
		pid, is_pid := strconv.parse_int(name, 10)
		if !is_pid || pid <= 0 do continue
		_, zombie, pgrp, found := _stat_full(pid)
		if found && !zombie && pgrp == pgid do return true
	}
	return false
}
