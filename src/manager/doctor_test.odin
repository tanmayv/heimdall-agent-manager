// Tests for `heimdall doctor` internals (src/manager/doctor.odin): loopback
// probe classification, health-summary rendering, TCP probing, and live probes
// against an in-test mock bridge over real TCP.
//
// The classification strings are pinned to the real bridge contract
// (src/bridge/main.odin:382 401 body, :403 health json), so a drift there
// must update these tests deliberately.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_manager_classify_loopback_probe :: proc(t: ^testing.T) {
	testing.expect(t, manager_classify_loopback_probe(false, false, 0, "") == .Not_Listening, "closed port")
	testing.expect(t, manager_classify_loopback_probe(true, false, 0, "") == .Other_Service, "port open but not HTTP")

	healthy := `{"ok":true,"contract_version":1,"ws_frame_version":2}`
	testing.expect(t, manager_classify_loopback_probe(true, true, 200, healthy) == .Heimdall_Ok, "healthy bridge")

	unauthorized := `{"ok":false,"message":"bridge loopback unauthorized"}`
	testing.expect(t, manager_classify_loopback_probe(true, true, 401, unauthorized) == .Heimdall_Unauthorized, "bridge 401 body")
	testing.expect(t, manager_classify_loopback_probe(true, true, 401, "") == .Heimdall_Unauthorized, "bare 401 status")

	testing.expect(t, manager_classify_loopback_probe(true, true, 200, `{"contract_version":1,"ws_frame_version":2}`) == .Heimdall_Responding, "contract_version-only body")
	testing.expect(t, manager_classify_loopback_probe(true, true, 404, `{"ok":false,"message":"unsupported_route"}`) == .Heimdall_Responding, "unsupported_route body")

	testing.expect(t, manager_classify_loopback_probe(true, true, 200, `{"hello":"world"}`) == .Other_Service, "foreign 200 body")
	testing.expect(t, manager_classify_loopback_probe(true, true, 404, `{"error":"nope"}`) == .Other_Service, "foreign 404 body")
}

@(test)
test_manager_health_summary :: proc(t: ^testing.T) {
	testing.expect(t, manager_health_summary(`{"ok":true,"contract_version":"1","ws_frame_version":"2"}`) == "contract 1, ws frame 2", "contract summary")
	testing.expect(t, manager_health_summary(`{"ok":true}`) == "ok", "summary without contract falls back to ok")
	testing.expect(t, manager_health_summary("") == "ok", "empty body falls back to ok")
}

@(test)
test_manager_tcp_probe :: proc(t: ^testing.T) {
	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	testing.expect(t, manager_tcp_probe(port), fmt.tprintf("open port %d probes true", port))
	net.close(listener)
	testing.expect(t, !manager_tcp_probe(port), fmt.tprintf("closed port %d probes false", port))
}

@(test)
test_manager_probe_bridge_loopback_against_mock :: proc(t: ^testing.T) {
	// Healthy, token-less bridge.
	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	mock := new(Manager_Test_Mock_Hub)
	handle := manager_test_mock_hub_start(mock, listener, 200, `{"ok":true,"contract_version":"1","ws_frame_version":"2"}`)
	testing.expect(t, handle != nil, "mock hub thread started")
	if handle == nil {
		net.close(listener)
		free(mock)
		return
	}
	probe, detail := manager_probe_bridge_loopback(port, "")
	manager_test_mock_hub_join(mock, handle)
	defer manager_test_mock_hub_free(mock)
	testing.expect(t, probe == .Heimdall_Ok, fmt.tprintf("healthy classification: %s", detail))
	testing.expect(t, strings.contains(detail, "healthy"), fmt.tprintf("healthy detail: %s", detail))
	testing.expect(t, strings.contains(detail, "contract 1"), fmt.tprintf("healthy detail carries the contract version: %s", detail))

	// Token-protected bridge rejecting a stale token (401).
	listener2, port2, lok2 := manager_test_loopback_listener()
	testing.expect(t, lok2, "second loopback listener bound")
	if !lok2 do return
	mock2 := new(Manager_Test_Mock_Hub)
	handle2 := manager_test_mock_hub_start(mock2, listener2, 401, `{"ok":false,"message":"bridge loopback unauthorized"}`)
	testing.expect(t, handle2 != nil, "second mock hub thread started")
	if handle2 == nil {
		net.close(listener2)
		free(mock2)
		return
	}
	probe2, detail2 := manager_probe_bridge_loopback(port2, "btk_stale")
	manager_test_mock_hub_join(mock2, handle2)
	defer manager_test_mock_hub_free(mock2)
	testing.expect(t, probe2 == .Heimdall_Unauthorized, fmt.tprintf("401 classification: %s", detail2))
	testing.expect(t, strings.contains(detail2, "token required"), fmt.tprintf("401 detail: %s", detail2))
	testing.expect(t, mock2.served == 1, fmt.tprintf("mock hub captured one HTTP request (%d)", mock2.served))
	if mock2.served == 1 {
		testing.expect(t, strings.contains(manager_test_mock_request(mock2, 0), "Authorization: Bearer btk_stale"), "stored token sent on the probe")
	}

	// Nothing listening on the port.
	closed_listener, closed_port, clok := manager_test_loopback_listener()
	if clok do net.close(closed_listener)
	probe3, _ := manager_probe_bridge_loopback(closed_port, "")
	testing.expect(t, probe3 == .Not_Listening, fmt.tprintf("closed port %d classifies as not listening", closed_port))
}

@(test)
test_manager_unit_present :: proc(t: ^testing.T) {
	testing.expect(t, !manager_unit_present(.Unsupported, MANAGER_SERVICE_UNIT, ""), "unsupported platform has no unit")

	// A unit name that cannot exist reports absent (deterministic even when
	// systemctl is missing: run_capture then fails and reports absent too).
	testing.expect(t, !manager_unit_present(.Linux, "heimdall-manager-missing-unit-xyz", ""), "missing systemd unit reports absent")

	tmp := manager_test_tmp_dir("unit-plist")
	defer manager_test_cleanup(tmp)
	plist := fmt.tprintf("%s/works.earendil.heimdall-bridge.plist", tmp)
	testing.expect(t, !manager_unit_present(.Darwin, "", plist), "missing launchd plist reports absent")
	testing.expect(t, os.write_entire_file(plist, "<plist/>") == nil, "write fake plist")
	testing.expect(t, manager_unit_present(.Darwin, "", plist), "present launchd plist reports present")
}
