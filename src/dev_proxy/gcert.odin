package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

Dev_Proxy_Gcert_State :: struct {
	mutex: sync.Mutex,
	last_check_time: time.Time,
	last_result: bool,
	initialized: bool,
}

dev_proxy_gcert_state: Dev_Proxy_Gcert_State

dev_proxy_gcert_init :: proc() {
	dev_proxy_gcert_state.mutex = sync.Mutex{}
	dev_proxy_gcert_state.last_check_time = time.Time{}
	dev_proxy_gcert_state.last_result = true
	dev_proxy_gcert_state.initialized = false
}

// dev_proxy_check_gcert performs a lightweight LOAS/gcert credential freshness check.
// In tests or environments where HEIMDALL_MOCK_GCERT_REMAINING_MINUTES is set:
//   remaining <= 0 => returns (false, "LOAS/gcert credential expired or missing; run gcert")
//   remaining > 0  => returns (true, "")
// In environments where HAM_DEV_PROXY_DISABLE_GCERT=1 or /usr/bin/gcertstatus does not exist:
//   returns (true, "")
// Otherwise runs /usr/bin/gcertstatus --check_remaining=0m, cached for 3 seconds to avoid
// per-request subprocess fork overhead.
dev_proxy_check_gcert :: proc() -> (bool, string) {
	if os.get_env("HAM_DEV_PROXY_DISABLE_GCERT", context.allocator) == "1" {
		return true, ""
	}

	// Fast mock override for unit/integration tests
	if mock_env := os.get_env("HEIMDALL_MOCK_GCERT_REMAINING_MINUTES", context.allocator); mock_env != "" {
		rem := 0
		if parsed, ok := strconv.parse_int(mock_env); ok {
			rem = int(parsed)
		}
		if rem <= 0 {
			return false, "LOAS/gcert credential expired or missing; run gcert"
		}
		return true, ""
	}

	gcertstatus_bin := "/usr/bin/gcertstatus"
	if !os.exists(gcertstatus_bin) {
		return true, ""
	}

	sync.lock(&dev_proxy_gcert_state.mutex)
	defer sync.unlock(&dev_proxy_gcert_state.mutex)

	now := time.now()
	if dev_proxy_gcert_state.initialized && time.diff(dev_proxy_gcert_state.last_check_time, now) < 3 * time.Second {
		if !dev_proxy_gcert_state.last_result {
			return false, "LOAS/gcert credential expired or missing; run gcert"
		}
		return true, ""
	}

	cmd := []string{gcertstatus_bin, "--check_remaining=0m"}
	p, err := os.process_start(os.Process_Desc{command = cmd})
	ok := false
	if err == nil {
		state, werr := os.process_wait(p)
		if werr == nil && state.exit_code == 0 {
			ok = true
		}
	}

	dev_proxy_gcert_state.last_check_time = now
	dev_proxy_gcert_state.last_result = ok
	dev_proxy_gcert_state.initialized = true

	if !ok {
		return false, "LOAS/gcert credential expired or missing; run gcert"
	}
	return true, ""
}
