package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_bridge_config_merge_empty :: proc(t: ^testing.T) {
	merged := bridge_config_merge("", "http://hub.example.test:8080", "tok_123", "brg_abc")
	testing.expect(t, strings.contains(merged, "[wrapper]"), "empty config gains [wrapper]")
	testing.expect(t, strings.contains(merged, "daemon_url = \"http://hub.example.test:8080\""), "empty config gains daemon_url")
	testing.expect(t, strings.contains(merged, "[daemon]"), "empty config gains [daemon]")
	testing.expect(t, strings.contains(merged, "daemon_id = \"brg_abc\""), "empty config gains daemon_id")
	testing.expect(t, strings.contains(merged, "bridge_token = \"tok_123\""), "empty config gains bridge_token")
}

@(test)
test_bridge_config_merge_existing_updates_daemon_url :: proc(t: ^testing.T) {
	existing := strings.concatenate({
		"# existing comment\n",
		"[wrapper]\n",
		"daemon_url = \"http://127.0.0.1:49322\"\n",
		"keep_me = true\n",
		"\n",
		"[daemon]\n",
		"daemon_id = \"old_id\"\n",
	})
	merged := bridge_config_merge(existing, "http://central-hub:9000", "", "new_id")
	testing.expect(t, !strings.contains(merged, "http://127.0.0.1:49322"), "old daemon_url was replaced")
	testing.expect(t, strings.contains(merged, "daemon_url = \"http://central-hub:9000\""), "new daemon_url present under [wrapper]")
	testing.expect(t, !strings.contains(merged, "old_id"), "old daemon_id was replaced")
	testing.expect(t, strings.contains(merged, "daemon_id = \"new_id\""), "new daemon_id present under [daemon]")
	testing.expect(t, strings.contains(merged, "keep_me = true"), "other keys preserved")
	testing.expect(t, strings.contains(merged, "# existing comment"), "comments preserved")
}

@(test)
test_bridge_config_merge_missing_wrapper_section :: proc(t: ^testing.T) {
	existing := strings.concatenate({
		"[daemon]\n",
		"daemon_id = \"old_id\"\n",
	})
	merged := bridge_config_merge(existing, "https://remote-hub.domain", "tok_999", "new_id")
	testing.expect(t, strings.contains(merged, "[wrapper]"), "missing [wrapper] appended")
	testing.expect(t, strings.contains(merged, "daemon_url = \"https://remote-hub.domain\""), "daemon_url present in appended [wrapper]")
	testing.expect(t, strings.contains(merged, "daemon_id = \"new_id\""), "daemon_id updated")
	testing.expect(t, strings.contains(merged, "bridge_token = \"tok_999\""), "bridge_token added")
}

@(test)
test_bridge_write_enrolled_config_file :: proc(t: ^testing.T) {
	tmp_path := fmt.tprintf("/tmp/ham-bridge-config-test-%d.toml", os.get_pid())
	defer os.remove(tmp_path)

	initial := "[wrapper]\ndaemon_url = \"http://old-hub:1111\"\n\n[daemon]\ndaemon_id = \"old_brg\"\n"
	_ = os.write_entire_file(tmp_path, transmute([]byte)initial)

	ok := bridge_write_enrolled_config(tmp_path, "http://new-hub:2222", "tok_new", "new_brg")
	testing.expect(t, ok, "bridge_write_enrolled_config succeeded")

	bytes, err := os.read_entire_file(tmp_path, context.allocator)
	testing.expect(t, err == nil, "read back config file")
	defer delete(bytes)

	content := string(bytes)
	testing.expect(t, strings.contains(content, "daemon_url = \"http://new-hub:2222\""), "file updated with new daemon_url")
	testing.expect(t, !strings.contains(content, "http://old-hub:1111"), "old url replaced in file")
	testing.expect(t, strings.contains(content, "daemon_id = \"new_brg\""), "file updated with new daemon_id")
}
