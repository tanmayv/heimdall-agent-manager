package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import ws "odin_test:lib/ws"

// REQ-SHELL-ENC-1: Secure command execution and spawn authorization on Bridge.

TEST_ENC_VAULT_KEY :: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
TEST_ALT_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

@(private = "file")
test_create_fake_ws_connection :: proc() -> (conn: ws.Connection, read_fd: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) != .OK {
		return {}, -1, false
	}
	conn = ws.Connection{connected = true, socket = net.TCP_Socket(fds[1])}
	return conn, fds[0], true
}

@(private = "file")
test_read_ws_text :: proc(fd: posix.FD) -> string {
	buf: [4096]byte
	n := posix.read(fd, &buf[0], len(buf))
	if n <= 0 do return ""
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@test
test_shell_enc_spec_parser_all_fields :: proc(t: ^testing.T) {
	raw := `{"cmd":"make test","cwd":"/tmp/work","env":[["FOO","bar"],["BAZ","qux"]],"timestamp":1700000000000,"nonce":"nonce_123"}`
	spec, ok := bridge_shell_parse_enc_spec(raw, context.temp_allocator)
	testing.expect(t, ok, "parse_enc_spec must succeed on valid json")
	testing.expect_value(t, spec.cmd, "make test")
	testing.expect_value(t, spec.cwd, "/tmp/work")
	testing.expect_value(t, spec.nonce, "nonce_123")
	testing.expect_value(t, spec.timestamp, i64(1700000000000))
	testing.expect(t, spec.has_env, "has_env should be true")
	testing.expect_value(t, len(spec.env), 2)
	if len(spec.env) == 2 {
		testing.expect_value(t, spec.env[0][0], "FOO")
		testing.expect_value(t, spec.env[0][1], "bar")
		testing.expect_value(t, spec.env[1][0], "BAZ")
		testing.expect_value(t, spec.env[1][1], "qux")
	}
}

@test
test_shell_enc_spec_parser_alt_env_formats :: proc(t: ^testing.T) {
	// Object format for env
	raw_obj := `{"cmd":"echo 1","cwd":"/","env":{"K1":"V1","K2":"V2"},"timestamp":100}`
	spec_obj, ok_obj := bridge_shell_parse_enc_spec(raw_obj, context.temp_allocator)
	testing.expect(t, ok_obj, "parse_enc_spec with object env must succeed")
	testing.expect(t, spec_obj.has_env, "spec_obj has_env")
	testing.expect_value(t, len(spec_obj.env), 2)

	// String array format for env
	raw_arr := `{"cmd":"echo 2","cwd":"/","env":["A=1","B=2"],"timestamp":200}`
	spec_arr, ok_arr := bridge_shell_parse_enc_spec(raw_arr, context.temp_allocator)
	testing.expect(t, ok_arr, "parse_enc_spec with array string env must succeed")
	testing.expect(t, spec_arr.has_env, "spec_arr has_env")
	testing.expect_value(t, len(spec_arr.env), 2)
}

@test
test_shell_enc_spec_parser_invalid_json :: proc(t: ^testing.T) {
	_, ok := bridge_shell_parse_enc_spec(`not-json{`, context.temp_allocator)
	testing.expect(t, !ok, "invalid json must fail parse_enc_spec")

	_, ok_arr := bridge_shell_parse_enc_spec(`["not an object"]`, context.temp_allocator)
	testing.expect(t, !ok_arr, "json array at root must fail parse_enc_spec")
}

@test
test_shell_start_rejects_missing_enc_spec_when_vault_active :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := `{"type":"shell_start","session_id":"sh_enc_missing","command_id":"cmd_1","cmd":"echo 1"}`
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(t, strings.contains(reply, `"error_code":"invalid_vault_key"`), "must include invalid_vault_key code")
	testing.expect(t, strings.contains(reply, "unauthorized: missing or invalid vault enc_spec"), "must specify missing enc_spec reason")
}

@test
test_shell_start_rejects_unarmored_enc_spec_when_vault_active :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := `{"type":"shell_start","session_id":"sh_enc_unarmored","command_id":"cmd_2","enc_spec":"plain:text:payload"}`
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(t, strings.contains(reply, `"error_code":"invalid_vault_key"`), "must include invalid_vault_key code")
	testing.expect(t, strings.contains(reply, "unauthorized: missing or invalid vault enc_spec"), "must specify unarmored enc_spec reason")
}

@test
test_shell_start_rejects_tampered_enc_spec :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	ts_str := fmt.tprintf("%d", bridge_now_unix_ms())
	payload := strings.concatenate({"{\"cmd\":\"echo hi\",\"cwd\":\"/tmp\",\"timestamp\":", ts_str, ",\"nonce\":\"abc\"}"})
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(payload, TEST_ENC_VAULT_KEY)
	testing.expect(t, enc_ok, "encryption should succeed")
	defer delete(armored)

	// Tamper with ciphertext by modifying base64 characters
	tampered := strings.concatenate({armored[:len(VAULT_ARMOR_PREFIX) + 4], "AAAA", armored[len(VAULT_ARMOR_PREFIX) + 8:]})

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := strings.concatenate({"{\"type\":\"shell_start\",\"session_id\":\"sh_enc_tampered\",\"command_id\":\"cmd_3\",\"enc_spec\":\"", tampered, "\"}"})
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(t, strings.contains(reply, `"error_code":"invalid_vault_key"`), "must include invalid_vault_key code")
	testing.expect(t, strings.contains(reply, "unauthorized: invalid vault encryption"), "must specify invalid vault encryption")
}

@test
test_shell_start_rejects_mismatched_vault_key :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	// Encrypt with ALT key
	ts_str := fmt.tprintf("%d", bridge_now_unix_ms())
	payload := strings.concatenate({"{\"cmd\":\"echo hi\",\"cwd\":\"/tmp\",\"timestamp\":", ts_str, ",\"nonce\":\"abc\"}"})
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(payload, TEST_ALT_VAULT_KEY)
	testing.expect(t, enc_ok, "encryption should succeed")
	defer delete(armored)

	// Bridge has TEST key active
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := strings.concatenate({"{\"type\":\"shell_start\",\"session_id\":\"sh_enc_mismatch\",\"command_id\":\"cmd_4\",\"enc_spec\":\"", armored, "\"}"})
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(t, strings.contains(reply, `"error_code":"invalid_vault_key"`), "must include invalid_vault_key code")
	testing.expect(t, strings.contains(reply, "unauthorized: invalid vault encryption"), "must specify invalid vault encryption")
}

@test
test_shell_start_rejects_expired_timestamp :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	// 70 seconds in the past (> 60s window)
	expired_ts := bridge_now_unix_ms() - 70_000
	ts_str := fmt.tprintf("%d", expired_ts)
	payload := strings.concatenate({"{\"cmd\":\"echo hi\",\"cwd\":\"/tmp\",\"timestamp\":", ts_str, ",\"nonce\":\"abc\"}"})
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(payload, TEST_ENC_VAULT_KEY)
	testing.expect(t, enc_ok, "encryption should succeed")
	defer delete(armored)

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := strings.concatenate({"{\"type\":\"shell_start\",\"session_id\":\"sh_enc_expired\",\"command_id\":\"cmd_5\",\"enc_spec\":\"", armored, "\"}"})
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(t, strings.contains(reply, `"error_code":"invalid_vault_key"`), "must include invalid_vault_key code")
	testing.expect(t, strings.contains(reply, "unauthorized: expired execution timestamp"), "must specify expired timestamp")
}

@test
test_shell_start_rejects_future_skewed_timestamp :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	// 70 seconds in the future (> 60s window)
	future_ts := bridge_now_unix_ms() + 70_000
	ts_str := fmt.tprintf("%d", future_ts)
	payload := strings.concatenate({"{\"cmd\":\"echo hi\",\"cwd\":\"/tmp\",\"timestamp\":", ts_str, ",\"nonce\":\"abc\"}"})
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(payload, TEST_ENC_VAULT_KEY)
	testing.expect(t, enc_ok, "encryption should succeed")
	defer delete(armored)

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := strings.concatenate({"{\"type\":\"shell_start\",\"session_id\":\"sh_enc_future\",\"command_id\":\"cmd_6\",\"enc_spec\":\"", armored, "\"}"})
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(t, strings.contains(reply, `"error_code":"invalid_vault_key"`), "must include invalid_vault_key code")
	testing.expect(t, strings.contains(reply, "unauthorized: expired execution timestamp"), "must specify expired timestamp")
}

@test
test_shell_start_accepts_and_decrypts_valid_enc_spec :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)

	// Supply a valid enc_spec where decrypted cwd is a non-existent path.
	// Wire cmd_wire.cwd is "/tmp" (valid).
	// If authorization and decryption succeed, the handler will inspect decrypted cwd
	// and reject with "cwd does not exist: /nonexistent_enc_spec_test_dir".
	// This proves that decrypted enc_spec parameters were parsed and used.
	ts_str := fmt.tprintf("%d", bridge_now_unix_ms())
	payload := strings.concatenate({
		"{\"cmd\":\"echo decrypted_cmd\",\"cwd\":\"/nonexistent_enc_spec_test_dir\",\"timestamp\":",
		ts_str,
		",\"nonce\":\"valid_nonce\"}",
	})
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(payload, TEST_ENC_VAULT_KEY)
	testing.expect(t, enc_ok, "encryption should succeed")
	defer delete(armored)

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	cmd := strings.concatenate({
		"{\"type\":\"shell_start\",\"session_id\":\"sh_enc_valid\",\"command_id\":\"cmd_7\",\"cwd\":\"/tmp\",\"enc_spec\":\"",
		armored,
		"\"}",
	})
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(
		t,
		strings.contains(reply, "cwd does not exist: /nonexistent_enc_spec_test_dir"),
		"must use decrypted cwd from enc_spec rather than plaintext cwd",
	)
}

@test
test_shell_start_fallback_when_vault_key_unconfigured :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	// Explicit invalid env ensures bridge_read_vault_key() returns false (does not fall through to file)
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_key)
			delete(prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	_ = os.set_env("HEIMDALL_VAULT_KEY", "unconfigured_key")

	conn, read_fd, ok := test_create_fake_ws_connection()
	testing.expect(t, ok, "fake ws connection created")
	defer posix.close(read_fd)
	defer posix.close(posix.FD(conn.socket))

	// Plaintext cmd with non-existent cwd
	cmd := `{"type":"shell_start","session_id":"sh_fallback","command_id":"cmd_8","cmd":"echo 1","cwd":"/nonexistent_plaintext_fallback_dir"}`
	bridge_hub_handle_shell_start(&conn, cmd)

	reply := test_read_ws_text(read_fd)
	testing.expect(
		t,
		strings.contains(reply, "cwd does not exist: /nonexistent_plaintext_fallback_dir"),
		"must fall back to plaintext cmd and cwd when vault key is unconfigured",
	)
}
