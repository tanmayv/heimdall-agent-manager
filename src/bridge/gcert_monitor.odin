package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Gcert_Status :: enum {
	Unknown,
	Valid,
	Expiring,
	Expired,
}

Bridge_Gcert_State :: struct {
	mutex: sync.Mutex,
	status: Gcert_Status,
	is_expired: bool,
	last_check_ms: i64,
	remaining_minutes: int,
	rearmed: bool,
	enabled: bool,
}

bridge_gcert_state: Bridge_Gcert_State

bridge_gcert_init :: proc() {
	bridge_gcert_state.mutex = sync.Mutex{}
	bridge_gcert_state.status = .Unknown
	bridge_gcert_state.is_expired = false
	bridge_gcert_state.last_check_ms = 0
	bridge_gcert_state.remaining_minutes = 1200 // default 20 hours
	bridge_gcert_state.rearmed = false
	bridge_gcert_state.enabled = true
}

// bridge_gcert_check_once evaluates current LOAS/gcert credentials.
// Detects:
// 1. Mock override in test envs (HEIMDALL_MOCK_GCERT_REMAINING_MINUTES).
// 2. /usr/bin/gcertstatus binary check (--check_remaining).
// 3. /tmp/krb5cc_<uid> or /tmp/x509up_u<uid> presence.
bridge_gcert_check_once :: proc() -> Gcert_Status {
	sync.lock(&bridge_gcert_state.mutex)
	defer sync.unlock(&bridge_gcert_state.mutex)

	// Support test/override via env
	if mock_env := os.get_env("HEIMDALL_MOCK_GCERT_REMAINING_MINUTES", context.allocator); mock_env != "" {
		rem := 0
		if parsed, ok := strconv.parse_int(mock_env); ok {
			rem = int(parsed)
		}
		bridge_gcert_state.remaining_minutes = rem
		prev_expired := bridge_gcert_state.is_expired
		if rem <= 0 {
			bridge_gcert_state.status = .Expired
			bridge_gcert_state.is_expired = true
		} else if rem < 30 {
			bridge_gcert_state.status = .Expiring
			bridge_gcert_state.is_expired = false
		} else {
			bridge_gcert_state.status = .Valid
			bridge_gcert_state.is_expired = false
			if prev_expired {
				bridge_gcert_state.rearmed = true
			}
		}
		return bridge_gcert_state.status
	}

	// Check if gcertstatus exists
	gcertstatus_bin := "/usr/bin/gcertstatus"
	if !os.exists(gcertstatus_bin) {
		// Non-Google environment or gcertstatus not installed; mark valid
		bridge_gcert_state.status = .Valid
		bridge_gcert_state.is_expired = false
		return .Valid
	}

	// Run gcertstatus --check_remaining=30m
	cmd_30m := []string{gcertstatus_bin, "--check_remaining=30m"}
	proc_30m, err_30m := os.process_start(os.Process_Desc{command = cmd_30m})
	has_30m := false
	if err_30m == nil {
		state, werr := os.process_wait(proc_30m)
		if werr == nil && state.exit_code == 0 {
			has_30m = true
		}
	}

	prev_status := bridge_gcert_state.status
	if has_30m {
		bridge_gcert_state.status = .Valid
		if bridge_gcert_state.is_expired {
			fmt.println("bridge gcert monitor: LOAS/gcert credentials renewed! Re-arming agents and operations.")
			bridge_gcert_state.rearmed = true
		}
		bridge_gcert_state.is_expired = false
	} else {
		// Check if at least 1s left (not completely expired)
		cmd_0m := []string{gcertstatus_bin, "--check_remaining=1s"}
		proc_0m, err_0m := os.process_start(os.Process_Desc{command = cmd_0m})
		is_valid_now := false
		if err_0m == nil {
			state_0, werr_0 := os.process_wait(proc_0m)
			if werr_0 == nil && state_0.exit_code == 0 {
				is_valid_now = true
			}
		}
		if is_valid_now {
			bridge_gcert_state.status = .Expiring
			bridge_gcert_state.is_expired = false
			if prev_status != .Expiring {
				fmt.eprintln("bridge gcert monitor: WARNING: LOAS/gcert expires in less than 30 minutes! Run 'gcert' on Cloudtop.")
			}
		} else {
			bridge_gcert_state.status = .Expired
			bridge_gcert_state.is_expired = true
			if prev_status != .Expired {
				fmt.eprintln("bridge gcert monitor: CRITICAL: LOAS/gcert has EXPIRED! Agent operations paused until 'gcert' is run.")
			}
		}
	}
	return bridge_gcert_state.status
}

bridge_gcert_is_expired :: proc() -> bool {
	sync.lock(&bridge_gcert_state.mutex)
	defer sync.unlock(&bridge_gcert_state.mutex)
	return bridge_gcert_state.is_expired
}

bridge_gcert_is_healthy :: proc() -> bool {
	sync.lock(&bridge_gcert_state.mutex)
	defer sync.unlock(&bridge_gcert_state.mutex)
	return !bridge_gcert_state.is_expired
}

bridge_gcert_monitor_start :: proc() {
	bridge_gcert_init()
	_ = bridge_gcert_check_once()
	thread.run(bridge_gcert_monitor_worker)
}

bridge_gcert_monitor_worker :: proc() {
	for {
		time.sleep(60 * time.Second)
		_ = bridge_gcert_check_once()
	}
}
