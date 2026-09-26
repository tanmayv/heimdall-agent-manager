// Tests for `heimdall enroll` (src/manager/enroll.odin): pure config-merge
// cases, token file persistence/permissions, argument validation, and full
// enroll round-trips against an in-test HTTP mock hub over real TCP.
//
// Every test points --config/--token-file at a temp dir, so the real
// ~/.config/heimdall is never read or written.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_manager_config_merge_pure :: proc(t: ^testing.T) {
	// Empty config: both sections are appended.
	empty := manager_config_merge("", "http://hub:1", "brg_new")
	testing.expect(t, strings.contains(empty, "[wrapper]"), fmt.tprintf("empty config gains [wrapper]: %s", empty))
	testing.expect(t, strings.contains(empty, "daemon_url = \"http://hub:1\""), "empty config gains daemon_url")
	testing.expect(t, strings.contains(empty, "[daemon]"), "empty config gains [daemon]")
	testing.expect(t, strings.contains(empty, "daemon_id = \"brg_new\""), "empty config gains daemon_id")

	// Existing content: matching keys replaced in place, everything else verbatim.
	existing := strings.concatenate({
		"# my heimdall config\n",
		"[wrapper]\n",
		"daemon_url = \"http://old:1\"\n",
		"extra = \"keep\"\n",
		"\n",
		"[ctl]\n",
		"daemon_url = \"http://ctl-keep\"\n",
		"\n",
		"[daemon]\n",
		"daemon_id = \"brg_old\"\n",
		"data_dir = \"~/d\"\n",
	})
	merged := manager_config_merge(existing, "http://new:2", "brg_new")
	testing.expect(t, !strings.contains(merged, "http://old:1"), "old [wrapper] url replaced")
	testing.expect(t, strings.contains(merged, "daemon_url = \"http://new:2\""), "new [wrapper] url present")
	testing.expect(t, !strings.contains(merged, "brg_old"), "old daemon_id replaced")
	testing.expect(t, strings.contains(merged, "daemon_id = \"brg_new\""), "new daemon_id present")
	testing.expect(t, strings.contains(merged, "# my heimdall config"), "comment preserved")
	testing.expect(t, strings.contains(merged, "extra = \"keep\""), "unknown [wrapper] key preserved")
	testing.expect(t, strings.contains(merged, "http://ctl-keep"), "unrelated [ctl] daemon_url untouched")
	testing.expect(t, strings.contains(merged, "data_dir = \"~/d\""), "unknown [daemon] key preserved")
	testing.expect(t, strings.count(merged, "daemon_url") == 2, "daemon_url appears exactly twice (new [wrapper] + [ctl])")
	testing.expect(t, strings.count(merged, "daemon_id") == 1, "daemon_id appears exactly once")

	// No-space assignment form is recognized and canonicalized.
	tight := manager_config_merge("[wrapper]\ndaemon_url=\"http://tight\"\n", "http://new:3", "brg_x")
	testing.expect(t, !strings.contains(tight, "http://tight"), "tight assignment replaced")
	testing.expect(t, strings.contains(tight, "daemon_url = \"http://new:3\""), "canonical assignment written")

	// A same-named key in the wrong section is left alone; [wrapper] is appended.
	wrong := manager_config_merge("[daemon]\ndaemon_url = \"http://wrong\"\n", "http://new:4", "brg_y")
	testing.expect(t, strings.contains(wrong, "http://wrong"), "wrong-section daemon_url untouched")
	testing.expect(t, strings.contains(wrong, "[wrapper]"), "[wrapper] appended when missing")
	testing.expect(t, strings.contains(wrong, "http://new:4"), "appended [wrapper] carries the new url")
}

@(test)
test_manager_token_file_write_and_mode :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("tokenfile")
	defer manager_test_cleanup(tmp)

	deep := fmt.tprintf("%s/a/b/bridge-token", tmp)
	testing.expect(t, manager_write_token_file(deep, "btk_abc"), "token write creates parent dirs")
	testing.expect(t, manager_read_token_file(deep) == "btk_abc", "token round-trips")
	testing.expect(t, manager_test_file_mode(deep) == 0o600, fmt.tprintf("new token file is 0600, got %s", manager_mode_string(manager_test_file_mode(deep))))

	// Re-enrolling over an existing, too-open token file must tighten the mode.
	loose := fmt.tprintf("%s/loose-token", tmp)
	testing.expect(t, os.write_entire_file(loose, "btk_old\n") == nil, "seed loose token file")
	testing.expect(t, manager_write_token_file(loose, "btk_new"), "re-enroll over existing file succeeds")
	testing.expect(t, manager_read_token_file(loose) == "btk_new", "token content updated")
	testing.expect(t, manager_test_file_mode(loose) == 0o600, fmt.tprintf("existing token file tightened to 0600, got %s", manager_mode_string(manager_test_file_mode(loose))))

	testing.expect(t, !manager_write_token_file("", "btk_x"), "empty path rejected")
	testing.expect(t, !manager_write_token_file(loose, "   "), "blank token rejected")
}

@(test)
test_manager_enroll_argument_validation :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("enrollargs")
	defer manager_test_cleanup(tmp)
	config_path := fmt.tprintf("%s/config.toml", tmp)

	testing.expect(t, !manager_enroll_command([]string{"heimdall", "enroll", "hbe_x", "--config", config_path}), "missing --hub rejected")
	testing.expect(t, !manager_enroll_command([]string{"heimdall", "enroll", "--hub", "ftp://hub.example.com", "hbe_x", "--config", config_path}), "non-http hub rejected")
	testing.expect(t, !manager_enroll_command([]string{"heimdall", "enroll", "--enrollment-token", "hbe_x", "--hub", "http://hub.example.com/path", "--config", config_path}), "hub url with path rejected")
	// No token: rejected before any network attempt.
	testing.expect(t, !manager_enroll_command([]string{"heimdall", "enroll", "--hub", "http://127.0.0.1:1", "--config", config_path}), "missing token rejected")
	testing.expect(t, !manager_path_exists(config_path), "failed validation writes no config")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/bridge-token", tmp)), "failed validation writes no token file")
}

@(test)
test_manager_enroll_round_trip_against_mock_hub :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("enroll-ok")
	defer manager_test_cleanup(tmp)
	config_path := fmt.tprintf("%s/config.toml", tmp)

	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	hub := fmt.tprintf("http://127.0.0.1:%d", port)
	body := strings.concatenate({`{"bridge_id":"brg_test1","bridge_token":"btk_testtoken1","hub_url":"`, hub, `"}`})
	defer delete(body)

	mock := new(Manager_Test_Mock_Hub)
	handle := manager_test_mock_hub_start(mock, listener, 201, body)
	testing.expect(t, handle != nil, "mock hub thread started")
	if handle == nil {
		net.close(listener)
		free(mock)
		return
	}
	// Trailing slash in --hub must be trimmed before it reaches the wire.
	enrolled := manager_enroll_command([]string{"heimdall", "enroll", "hbe_testtoken123", "--hub", fmt.tprintf("%s/", hub), "--config", config_path})
	manager_test_mock_hub_join(mock, handle)
	defer manager_test_mock_hub_free(mock)

	testing.expect(t, enrolled, "enroll succeeds against the mock hub")
	testing.expect(t, mock.served == 1, fmt.tprintf("mock hub captured exactly one request (%d)", mock.served))
	if mock.served == 1 {
		request := manager_test_mock_request(mock, 0)
		testing.expect(t, strings.contains(request, "POST /api/v1/bridges/enroll HTTP/1.1"), fmt.tprintf("enroll request line: %s", manager_first_line(request)))
		testing.expect(t, strings.contains(request, "Authorization: Bearer hbe_testtoken123"), "one-time enrollment token sent as Bearer")
		testing.expect(t, strings.contains(request, fmt.tprintf("\"hub_url\":\"%s\"", hub)), "trimmed hub_url in request body")
		testing.expect(t, strings.contains(request, "\"hostname\":") || strings.contains(request, "\"hostname\": "), "machine.hostname present in request body")
		testing.expect(t, strings.contains(request, fmt.tprintf("\"os\":\"%s\"", manager_os_string())), "machine.os present in request body")
	}

	// Token file: default location is a sibling of --config, mode 0600.
	token_path := fmt.tprintf("%s/bridge-token", tmp)
	testing.expect(t, manager_read_token_file(token_path) == "btk_testtoken1", "bridge token persisted from the Hub response")
	testing.expect(t, manager_test_file_mode(token_path) == 0o600, "persisted token file is 0600")

	data, cfg_err := os.read_entire_file(config_path, context.allocator)
	testing.expect(t, cfg_err == nil, "config.toml written")
	if cfg_err == nil {
		defer delete(data)
		config := string(data)
		testing.expect(t, strings.contains(config, "[wrapper]"), "config has [wrapper]")
		testing.expect(t, strings.contains(config, fmt.tprintf("daemon_url = \"%s\"", hub)), "config has [wrapper] daemon_url")
		testing.expect(t, strings.contains(config, "[daemon]"), "config has [daemon]")
		testing.expect(t, strings.contains(config, "daemon_id = \"brg_test1\""), "config has [daemon] daemon_id")
	}
}

@(test)
test_manager_enroll_rejects_non_201 :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("enroll-401")
	defer manager_test_cleanup(tmp)
	config_path := fmt.tprintf("%s/config.toml", tmp)

	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	hub := fmt.tprintf("http://127.0.0.1:%d", port)

	mock := new(Manager_Test_Mock_Hub)
	handle := manager_test_mock_hub_start(mock, listener, 401, `{"ok":false,"message":"invalid enrollment token"}`)
	testing.expect(t, handle != nil, "mock hub thread started")
	if handle == nil {
		net.close(listener)
		free(mock)
		return
	}
	enrolled := manager_enroll_command([]string{"heimdall", "enroll", "hbe_stale", "--hub", hub, "--config", config_path})
	manager_test_mock_hub_join(mock, handle)
	defer manager_test_mock_hub_free(mock)

	testing.expect(t, !enrolled, "401 enroll fails")
	testing.expect(t, !manager_path_exists(config_path), "no config written on 401")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/bridge-token", tmp)), "no token file written on 401")
}

@(test)
test_manager_enroll_rejects_201_without_token :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("enroll-notoken")
	defer manager_test_cleanup(tmp)
	config_path := fmt.tprintf("%s/config.toml", tmp)

	listener, port, lok := manager_test_loopback_listener()
	testing.expect(t, lok, "loopback listener bound")
	if !lok do return
	hub := fmt.tprintf("http://127.0.0.1:%d", port)

	mock := new(Manager_Test_Mock_Hub)
	handle := manager_test_mock_hub_start(mock, listener, 201, `{"bridge_id":"brg_x"}`)
	testing.expect(t, handle != nil, "mock hub thread started")
	if handle == nil {
		net.close(listener)
		free(mock)
		return
	}
	enrolled := manager_enroll_command([]string{"heimdall", "enroll", "hbe_x", "--hub", hub, "--config", config_path})
	manager_test_mock_hub_join(mock, handle)
	defer manager_test_mock_hub_free(mock)

	testing.expect(t, !enrolled, "201 without bridge_token fails (nothing to persist)")
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/bridge-token", tmp)), "no token file written")
}
