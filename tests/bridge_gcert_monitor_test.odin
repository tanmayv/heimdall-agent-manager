package bridge_gcert_monitor_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import bridge "odin_test:bridge"

main :: proc() {
	run_gcert_monitor_test()
}

@(test)
test_gcert_monitor :: proc(t: ^testing.T) {
	run_gcert_monitor_test()
}

run_gcert_monitor_test :: proc() {
	bridge.bridge_gcert_init()

	// 1. Initial status with default minutes (1200m)
	check(bridge.bridge_gcert_is_healthy(), "initial gcert state should be healthy")
	check(!bridge.bridge_gcert_is_expired(), "initial gcert state should not be expired")

	// 2. Mock Expired status (0 minutes remaining)
	os.set_env("HEIMDALL_MOCK_GCERT_REMAINING_MINUTES", "0")
	status_expired := bridge.bridge_gcert_check_once()
	check(status_expired == .Expired, "should detect expired status")
	check(bridge.bridge_gcert_is_expired(), "is_expired should be true when remaining minutes is 0")
	check(!bridge.bridge_gcert_is_healthy(), "is_healthy should be false when remaining minutes is 0")

	// 3. Mock Renewal and Re-arming (user runs gcert, now 1200 minutes remaining)
	os.set_env("HEIMDALL_MOCK_GCERT_REMAINING_MINUTES", "1200")
	status_renewed := bridge.bridge_gcert_check_once()
	check(status_renewed == .Valid, "should detect valid status after renewal")
	check(!bridge.bridge_gcert_is_expired(), "is_expired should reset to false after renewal")
	check(bridge.bridge_gcert_is_healthy(), "is_healthy should be true after renewal")
	check(bridge.bridge_gcert_state.rearmed, "rearmed flag must be set when recovering from expired to valid")

	// 4. Mock Expiring Soon (< 30 minutes)
	os.set_env("HEIMDALL_MOCK_GCERT_REMAINING_MINUTES", "20")
	status_expiring := bridge.bridge_gcert_check_once()
	check(status_expiring == .Expiring, "should detect expiring status when < 30m")
	check(!bridge.bridge_gcert_is_expired(), "is_expired should remain false when expiring soon but still valid")

	os.unset_env("HEIMDALL_MOCK_GCERT_REMAINING_MINUTES")
	fmt.println("PASS: bridge gcert monitor lifetime and re-arming verification")
}

check :: proc(ok: bool, msg: string) {
	if !ok {
		fmt.eprintln("FAIL:", msg)
		os.exit(1)
	}
}
