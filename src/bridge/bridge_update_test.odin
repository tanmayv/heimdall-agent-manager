package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// REQ-BUPD-4: bridge_update_progress_json frame serialization
@(test)
test_bridge_update_progress_json_format :: proc(t: ^testing.T) {
	frame := bridge_update_progress_json("cmd_upd_123", "brg_test", "downloading", 45, "Downloading update package")
	defer delete(frame)

	testing.expect(t, strings.contains(frame, "\"type\":\"bridge_update_progress\""), "type is bridge_update_progress")
	testing.expect(t, strings.contains(frame, "\"command_id\":\"cmd_upd_123\""), "command_id is correct")
	testing.expect(t, strings.contains(frame, "\"bridge_id\":\"brg_test\""), "bridge_id is correct")
	testing.expect(t, strings.contains(frame, "\"stage\":\"downloading\""), "stage is downloading")
	testing.expect(t, strings.contains(frame, "\"progress_percent\":45"), "progress_percent is 45")
	testing.expect(t, strings.contains(frame, "\"message\":\"Downloading update package\""), "message matches")
}

// REQ-BUPD-5: bridge_update command handler verifies checksum, preflights, and stages update
@(test)
test_bridge_update_command_dispatch_and_execution :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	tmp_dir := fmt.tprintf("/tmp/ham-bridge-update-unit-%d", bridge_now_unix_ms())
	_ = os.make_directory_all(tmp_dir)
	defer _ = os.remove_all(tmp_dir)

	saved_data := bridge_config.data_dir
	defer { bridge_config.data_dir = saved_data }
	bridge_config.data_dir = tmp_dir

	// Create a dummy bundle containing bin/ham-bridge
	bundle_stage := fmt.tprintf("%s/bundle_src", tmp_dir)
	_ = os.make_directory_all(fmt.tprintf("%s/bin", bundle_stage))
	dummy_bin := fmt.tprintf("%s/bin/ham-bridge", bundle_stage)
	bin_content := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'ham-bridge 0.2.0 (unit-test)'; exit 0; fi\nexit 0\n"
	_ = os.write_entire_file(dummy_bin, transmute([]byte)bin_content)
	_ = os.chmod(dummy_bin, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})

	tarball_path := fmt.tprintf("%s/bundle.tar.gz", tmp_dir)
	tar_argv := []string{"tar", "-czf", tarball_path, "-C", bundle_stage, "."}
	state, _, _, _ := os.process_exec(os.Process_Desc{command = tar_argv}, context.allocator)
	testing.expect(t, state.success, "bundle tarball created")

	// Compute sha256
	tar_data, _ := os.read_entire_file(tarball_path, context.allocator)
	defer delete(tar_data)
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, tar_data, digest[:])
	hex_bytes := hex.encode(digest[:])
	defer delete(hex_bytes)
	tar_sha256 := string(hex_bytes)

	// 1. Test dispatch with mismatched SHA-256
	cmd_fail_id := fmt.tprintf("cmd_upd_fail_%d", bridge_now_unix_ms())
	fail_json := fmt.tprintf(
		`{{"type":"bridge_update","command_id":"%s","target_version":"0.2.0","download_url":"%s","sha256":"0000000000000000000000000000000000000000000000000000000000000000","force":true}}`,
		cmd_fail_id, tarball_path,
	)
	bridge_hub_handle_command(nil, fail_json)

	cached_fail, has_fail := bridge_runtime_cached_command(cmd_fail_id)
	testing.expect(t, has_fail, "mismatched sha command result cached")
	testing.expect(t, strings.contains(cached_fail, "\"status\":\"failed\""), "mismatched sha fails command")

	// 2. Test dispatch with valid SHA-256
	cmd_succ_id := fmt.tprintf("cmd_upd_succ_%d", bridge_now_unix_ms())
	succ_json := fmt.tprintf(
		`{{"type":"bridge_update","command_id":"%s","target_version":"0.2.0","download_url":"%s","sha256":"%s","force":true}}`,
		cmd_succ_id, tarball_path, tar_sha256,
	)
	bridge_hub_handle_command(nil, succ_json)

	cached_succ, has_succ := bridge_runtime_cached_command(cmd_succ_id)
	testing.expect(t, has_succ, "valid command result cached")
	testing.expect(t, strings.contains(cached_succ, "\"status\":\"succeeded\""), "valid update succeeds and prepares restart")

	// 3. Test preflight failure (broken binary returning exit code 1)
	broken_stage := fmt.tprintf("%s/broken_src", tmp_dir)
	_ = os.make_directory_all(fmt.tprintf("%s/bin", broken_stage))
	broken_bin := fmt.tprintf("%s/bin/ham-bridge", broken_stage)
	broken_content := "#!/bin/sh\nexit 1\n"
	_ = os.write_entire_file(broken_bin, transmute([]byte)broken_content)
	_ = os.chmod(broken_bin, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})

	broken_tarball := fmt.tprintf("%s/broken.tar.gz", tmp_dir)
	tar_argv2 := []string{"tar", "-czf", broken_tarball, "-C", broken_stage, "."}
	state2, _, _, _ := os.process_exec(os.Process_Desc{command = tar_argv2}, context.allocator)
	testing.expect(t, state2.success, "broken tarball created")

	tar_data2, _ := os.read_entire_file(broken_tarball, context.allocator)
	defer delete(tar_data2)
	digest2: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, tar_data2, digest2[:])
	hex_bytes2 := hex.encode(digest2[:])
	defer delete(hex_bytes2)
	broken_sha256 := string(hex_bytes2)

	cmd_pf_fail_id := fmt.tprintf("cmd_upd_pf_fail_%d", bridge_now_unix_ms())
	pf_fail_json := fmt.tprintf(
		`{{"type":"bridge_update","command_id":"%s","target_version":"0.2.0","download_url":"%s","sha256":"%s","force":true}}`,
		cmd_pf_fail_id, broken_tarball, broken_sha256,
	)
	bridge_hub_handle_command(nil, pf_fail_json)

	cached_pf_fail, has_pf_fail := bridge_runtime_cached_command(cmd_pf_fail_id)
	testing.expect(t, has_pf_fail, "preflight failure command result cached")
	testing.expect(t, strings.contains(cached_pf_fail, "\"status\":\"failed\""), "preflight failure marks command failed")
}
