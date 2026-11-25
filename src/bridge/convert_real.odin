package main

// Real implementations of the conversion seams (convert_cmd.odin), the C4a rescuer
// (`ham-bridge convert-rescue`, spec §6.4) and the parent-process gate discriminator
// (spec §9.1).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import lc "odin_test:launcher/core"
import bridgesvc "odin_test:lib/bridgesvc"

bridge_convert_new_state :: proc() -> ^Convert_State {
	c := new(Convert_State, context.temp_allocator)
	c.seams = bridge_convert_real_seams()
	return c
}

bridge_convert_real_seams :: proc() -> Convert_Seams {
	return Convert_Seams {
		now               = proc(s: ^Bridge_Setup) -> i64 {return time.to_unix_seconds(time.now())},
		sleep_ms          = proc(s: ^Bridge_Setup, ms: int) {time.sleep(time.Duration(ms) * time.Millisecond)},
		agent_count       = bridge_convert_agent_count_real,
		parent_is_worker  = bridge_convert_parent_is_worker_real,
		fetch             = bridge_convert_fetch_real,
		service_stop      = bridge_convert_service_stop_real,
		service_start     = bridge_convert_service_start_real,
		service_running   = proc(s: ^Bridge_Setup) -> bool {return bridge_service_running(s.host, s.layout)},
		service_connected = proc(s: ^Bridge_Setup) -> bool {
			st := bridge_service_status(s.host, s.layout.service_name, s.restart_at, s.stale_pid)
			return st.running && st.connected
		},
		pty_stop          = bridge_convert_pty_stop_real,
		repair            = bridge_convert_repair_real,
		register          = bridge_convert_register_real,
		enroll            = proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {return bridge_setup_run(s, .Enroll)},
		extensions        = proc(s: ^Bridge_Setup) -> bridgesvc.Step_Result {return bridge_setup_run(s, .Extensions)},
		spawn_rescuer     = bridge_convert_spawn_rescuer_real,
		stop_rescuer      = proc(s: ^Bridge_Setup, rec: Conversion_Record) {}, // exits by itself when conversion.json is gone
		old_version       = bridge_convert_old_version_real,
		os_restore_service = bridge_convert_os_restore_service_real,
		os_finalize       = bridge_convert_os_finalize_real,
		free_bytes        = bridge_convert_free_bytes,
		self_sha256       = proc(s: ^Bridge_Setup) -> string {
			exe, _ := os.get_executable_path(context.temp_allocator)
			return bridge_convert_file_sha256(exe)
		},
		owner_json        = bridge_convert_owner_json,
		windows_sid       = bridge_convert_windows_sid,
	}
}

// ---- agents -----------------------------------------------------------------------------

bridge_convert_agent_count_real :: proc(s: ^Bridge_Setup) -> int {
	sockets := make([dynamic]string, context.temp_allocator)
	bridge_profile_pty_sockets(s.layout.data_dir, &sockets)
	total := 0
	for socket in sockets {
		if !bridge_pty_host_ping(socket) do continue
		n, listed := pty_host_stale_agent_count(socket)
		if !listed do return -1 // a daemon that does not answer counts as busy
		total += n
	}
	return total
}

bridge_convert_pty_stop_real :: proc(s: ^Bridge_Setup) -> (bool, string) {
	sockets := make([dynamic]string, context.temp_allocator)
	bridge_profile_pty_sockets(s.layout.data_dir, &sockets)
	for socket in sockets {
		if !bridge_pty_host_ping(socket) do continue
		if ok, detail := bridge_update_stop_pty_host(socket); !ok do return false, detail
		deadline := time.time_add(time.now(), 10 * time.Second)
		for bridge_pty_host_ping(socket) {
			if time.diff(time.now(), deadline) <= 0 do return false, fmt.tprintf("the PTY host on %s did not exit", socket)
			time.sleep(100 * time.Millisecond)
		}
	}
	return true, ""
}

// ---- parent process (gate discriminator, spec §9.1) --------------------------------------------

// bridge_convert_is_worker_command: `<this profile's bin>/ham-bridge update ... --auto-worker
// ... --service <service>`.
bridge_convert_is_worker_command :: proc(command, bin_ham_bridge, service: string) -> bool {
	if !strings.contains(command, bin_ham_bridge) do return false
	fields := strings.fields(command, context.temp_allocator)
	has_update, has_worker, has_service := false, false, false
	for f, i in fields {
		switch f {
		case "update": has_update = true
		case "--auto-worker": has_worker = true
		case "--service": has_service = i + 1 < len(fields) && fields[i + 1] == service
		}
	}
	return has_update && has_worker && has_service
}

bridge_convert_parent_is_worker_real :: proc(s: ^Bridge_Setup) -> bool {
	ppid := bridge_convert_parent_pid()
	if ppid <= 1 do return false
	_, command, ok := bridge_os_process_lstart_and_command(ppid)
	if !ok do return false // unknown: treated as user-started
	expected := bridgesvc.pjoin(s.layout.bin_dir, bridgesvc.exe_name(s.host, "ham-bridge"))
	return bridge_convert_is_worker_command(command, expected, s.layout.service_name)
}

// ---- service control ---------------------------------------------------------------------------

bridge_convert_win_task :: proc(s: ^Bridge_Setup) -> string {
	rec, reason := lc.read_instance_record(s.layout.data_dir, context.temp_allocator)
	if reason != "" do return ""
	return strings.concatenate({"\\", bridgesvc.windows_task_name(s.layout.service_name, bridge_convert_windows_sid(), rec.instance_id)}, context.temp_allocator)
}

bridge_convert_service_stop_real :: proc(s: ^Bridge_Setup) -> (bool, string) {
	if s.layout.backend == .Schtasks {
		if tn := bridge_convert_win_task(s); tn != "" && bridge_convert_supervisor_managed(s.host, s.layout) {
			// The fallback only: the stop request/event is tried first by R1.
			ok, out := bridge_service_exec({"schtasks", "/End", "/TN", tn})
			return ok, out
		}
	}
	if !bridge_service_running(s.host, s.layout) && bridge_service_runtime_pid(s.host, s.layout) <= 0 do return true, "already stopped"
	return bridge_service_action(s.host, s.layout.service_name, .Stop)
}

bridge_convert_service_start_real :: proc(s: ^Bridge_Setup) -> (bool, string) {
	if s.layout.backend == .Schtasks && bridge_convert_supervisor_managed(s.host, s.layout) {
		if tn := bridge_convert_win_task(s); tn != "" do return bridge_service_exec({"schtasks", "/Run", "/TN", tn})
	}
	return bridge_service_action(s.host, s.layout.service_name, .Start)
}

bridge_convert_os_restore_service_real :: proc(s: ^Bridge_Setup, rec: Conversion_Record) -> (bool, string) {
	l := s.layout
	#partial switch l.backend {
	case .Systemd:
		_, _ = bridge_service_exec({"systemctl", "--user", "daemon-reload"})
	case .Schtasks:
		new_tn := strings.concatenate({"\\", bridgesvc.windows_task_name(l.service_name, bridge_convert_windows_sid(), rec.instance_id)}, context.temp_allocator)
		_, _ = bridge_service_exec({"schtasks", "/Delete", "/TN", new_tn, "/F"})
		_, _ = bridge_service_exec({"schtasks", "/Change", "/TN", strings.concatenate({"\\", l.service_name}, context.temp_allocator), "/ENABLE"})
		for p in ([]string{bridgesvc.windows_launcher_cmd_path(l), bridgesvc.windows_launcher_vbs_path(l), bridgesvc.windows_launcher_task_xml_path(l)}) do _ = os.remove(p)
	}
	return true, ""
}

bridge_convert_old_version_real :: proc(s: ^Bridge_Setup) -> string {
	exe := bridgesvc.pjoin(s.layout.bin_dir, bridgesvc.exe_name(s.host, "ham-bridge"))
	out, errout, ran, _ := bridge_process_run_capture({exe, "--version"}, 5 * time.Second)
	defer {delete(out); delete(errout)}
	if !ran do return ""
	return bridgesvc.parse_version_output(out)
}

bridge_convert_repair_real :: proc(s: ^Bridge_Setup, rel: Convert_Release, rec: Conversion_Record) -> (int, string) {
	exe := bridgesvc.pjoin(s.bundle_dir, bridgesvc.exe_name(s.host, "ham-supervisor"))
	argv := []string{exe, "repair", "--instance-root", s.layout.data_dir, "--state-root", s.layout.state_dir, "--bundle", rel.archive, "--manifest", rel.manifest, "--signature", rel.signature, "--op-id", rec.op_id}
	out, errout, ran, timed_out := bridge_process_run_capture(argv, 10 * time.Minute)
	defer {delete(out); delete(errout)}
	detail := strings.trim_space(strings.concatenate({errout, out}, context.temp_allocator))
	if timed_out do return 1, "timed out"
	if !ran do return 1, detail
	return 0, detail
}

// ---- C4a rescuer (spec §6.4) --------------------------------------------------------------------------

bridge_convert_rescue_dir :: proc(l: bridgesvc.Layout, txn: string) -> string {
	return bridgesvc.pjoin(bridgesvc.convert_backup_dir(l, txn), "rescue")
}

bridge_convert_spawn_rescuer_real :: proc(s: ^Bridge_Setup, rec: Conversion_Record) -> bool {
	l := s.layout
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil || exe == "" do return false
	dir := bridge_convert_rescue_dir(l, rec.txn)
	_ = os.make_directory_all(dir)
	copy_path := bridgesvc.pjoin(dir, bridgesvc.exe_name(s.host, "ham-bridge"))
	if os.copy_file(copy_path, exe) != nil do return false
	_ = os.chmod(copy_path, {.Read_User, .Write_User, .Execute_User})
	started, _, _ := bridge_os_process_lstart_and_command(s.pid)
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, copy_path, "convert-rescue", "--txn", rec.txn, "--setup-pid", fmt.tprintf("%d", s.pid), "--setup-start", fmt.tprintf("%d", started), "--hub", s.profile.hub_url)
	if s.profile.profile != "" do append(&argv, "--profile", s.profile.profile)
	return bridge_os_spawn_new_session(argv[:])
}

// bridge_convert_rescue_command: `ham-bridge convert-rescue --txn T --setup-pid P --setup-start S
// --hub H [--profile P]`. Watches setup; when it is gone and conversion.json still exists, it
// recovers under the install lock (roll forward if C6 is done, else R1-R6).
bridge_convert_rescue_command :: proc(args: []string) -> int {
	txn := strings.trim_space(option_value(args, "--txn", ""))
	pid, _ := strconv.parse_int(option_value(args, "--setup-pid", "0"))
	start, _ := strconv.parse_i64(option_value(args, "--setup-start", "0"), 10)
	hub := strings.trim_space(option_value(args, "--hub", ""))
	profile_name := strings.trim_space(option_value(args, "--profile", ""))
	if !bridgesvc.valid_txn(txn) || hub == "" do return bridgesvc.EXIT_USAGE
	profile, ok := bridgesvc.profile_from(hub, profile_name, context.temp_allocator)
	if !ok do return bridgesvc.EXIT_USAGE
	s := Bridge_Setup{host = bridge_service_host(), profile = profile, args = args, pid = os.get_pid(), backups = make(map[string]Maybe(string), context.temp_allocator), recovered = make([dynamic]string, context.temp_allocator)}
	s.layout = bridgesvc.layout_for(s.host, profile.service_name)
	s.lock_path = bridgesvc.pjoin(s.layout.state_dir, bridgesvc.LOCK_FILE)
	s.bundle_dir = bridgesvc.pdir(os.args[0])
	for {
		rec, present, _ := bridge_convert_read_record(s.layout)
		if !present || (rec.txn != "" && rec.txn != txn) do return 0 // finished, or another conversion
		if bridge_convert_setup_alive(pid, start) {
			time.sleep(2 * time.Second)
			continue
		}
		break
	}
	// Setup is gone mid-transaction. The OS lock is free once its owner is dead.
	locked := bridgesvc.lock_acquire(s.lock_path, s.pid, time.now(), bridge_os_pid_alive)
	if !locked.ok {
		if locked.failure != .Stale_Lock || !bridgesvc.lock_break(s.lock_path) do return bridgesvc.EXIT_BUSY
		locked = bridgesvc.lock_acquire(s.lock_path, s.pid, time.now(), bridge_os_pid_alive)
		if !locked.ok do return bridgesvc.EXIT_BUSY
	}
	defer bridgesvc.lock_release(s.lock_path, s.pid)
	s.conv = bridge_convert_new_state()
	s.facts.running = true
	_, ok2 := bridge_convert_recover(&s)
	return 0 if ok2 else bridgesvc.EXIT_ROLLBACK_INCOMPLETE
}

// bridge_convert_setup_alive: the same (pid, start time) is still running.
bridge_convert_setup_alive :: proc(pid: int, start: i64) -> bool {
	if pid <= 0 || !bridge_os_pid_alive(pid) do return false
	if start <= 0 do return true
	got, _, known := bridge_os_process_lstart_and_command(pid)
	return !known || got == start || got == 0
}
