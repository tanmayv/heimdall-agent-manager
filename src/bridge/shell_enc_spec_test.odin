package main

import "base:runtime"
import base64 "core:encoding/base64"
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

@(test)
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

@(test)
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

@(test)
test_shell_enc_spec_parser_invalid_json :: proc(t: ^testing.T) {
	_, ok := bridge_shell_parse_enc_spec(`not-json{`, context.temp_allocator)
	testing.expect(t, !ok, "invalid json must fail parse_enc_spec")

	_, ok_arr := bridge_shell_parse_enc_spec(`["not an object"]`, context.temp_allocator)
	testing.expect(t, !ok_arr, "json array at root must fail parse_enc_spec")
}

@(test)
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

@(test)
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

@(test)
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

@(test)
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

@(test)
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

@(test)
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

@(test)
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

@(test)
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

// ---------------------------------------------------------------------------
// REQ-SHELL-ENC-2, REQ-SHELL-ENC-3, REQ-SHELL-ENC-4:
// AES-256-GCM encrypted PTY output streaming, input decryption, and catch-up snapshots.
// ---------------------------------------------------------------------------

@(private = "file")
test_shell_stream_mutex: sync.Mutex

@(test)
test_pty_stream_emit_frame_encrypted_when_vault_active :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_shell_stream_mutex)
	defer sync.mutex_unlock(&test_shell_stream_mutex)
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

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

	worker := Bridge_PTY_Stream_Worker{
		session_id = "sh_stream_enc_1",
		shell_id = "sh_stream_enc_1",
		active = true,
		salt = [4]byte{0x11, 0x22, 0x33, 0x44},
		seq = 0,
	}

	test_data := "hello encrypted pty stream\r\n"
	bridge_pty_stream_emit_frame(&worker, "sh_stream_enc_1", transmute([]byte)test_data)

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f, runtime.heap_allocator())
		delete(frames)
	}

	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		frame := frames[0]
		testing.expect(t, strings.contains(frame, `"type":"shell_pty_output"`), "frame type is shell_pty_output")
		testing.expect(t, strings.contains(frame, `"session_id":"sh_stream_enc_1"`), "frame has session_id")
		testing.expect(t, strings.contains(frame, `"enc_b64":`), "frame contains enc_b64 field")
		testing.expect(t, strings.contains(frame, `"data_b64":"vault:v1:`), "frame contains armored data_b64")

		enc_b64 := extract_json_string(frame, "enc_b64", "")
		testing.expect(t, enc_b64 != "", "enc_b64 must not be empty")

		data_b64 := extract_json_string(frame, "data_b64", "")
		testing.expect(t, strings.has_prefix(data_b64, VAULT_ARMOR_PREFIX), "data_b64 must start with vault:v1:")

		decrypted, dec_ok := bridge_pty_stream_decrypt_chunk(data_b64, TEST_ENC_VAULT_KEY, context.temp_allocator)
		testing.expect(t, dec_ok, "decryption of emitted frame from data_b64 must succeed")
		testing.expect_value(t, string(decrypted), test_data)
	}
}

@(test)
test_pty_stream_emit_frame_plaintext_when_vault_unconfigured :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_shell_stream_mutex)
	defer sync.mutex_unlock(&test_shell_stream_mutex)
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

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

	test_data := "hello plaintext pty stream\r\n"
	bridge_pty_stream_emit_frame(nil, "sh_stream_plain_1", transmute([]byte)test_data)

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f, runtime.heap_allocator())
		delete(frames)
	}

	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		frame := frames[0]
		testing.expect(t, strings.contains(frame, `"type":"shell_pty_output"`), "frame type is shell_pty_output")
		testing.expect(t, strings.contains(frame, `"session_id":"sh_stream_plain_1"`), "frame has session_id")
		testing.expect(t, strings.contains(frame, `"data_b64":`), "frame contains data_b64 field")
		testing.expect(t, !strings.contains(frame, `"enc_b64":`), "frame does not contain enc_b64")

		data_b64 := extract_json_string(frame, "data_b64", "")
		decoded, err := base64.decode(data_b64, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "base64 decode of data_b64 must succeed")
		testing.expect_value(t, string(decoded), test_data)
	}
}

@(test)
test_pty_stream_monotonic_nonce_counter_no_reuse :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_shell_stream_mutex)
	defer sync.mutex_unlock(&test_shell_stream_mutex)
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

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

	fixed_salt := [4]byte{0xDE, 0xAD, 0xBE, 0xEF}
	worker := Bridge_PTY_Stream_Worker{
		session_id = "sh_stream_nonce_test",
		shell_id = "sh_stream_nonce_test",
		active = true,
		salt = fixed_salt,
		seq = 0,
	}

	NUM_FRAMES :: 5
	for i in 1..=NUM_FRAMES {
		chunk := fmt.tprintf("chunk %d\r\n", i)
		bridge_pty_stream_emit_frame(&worker, "sh_stream_nonce_test", transmute([]byte)chunk)
	}

	testing.expect_value(t, worker.seq, u64(NUM_FRAMES))

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f, runtime.heap_allocator())
		delete(frames)
	}

	testing.expect_value(t, len(frames), NUM_FRAMES)
	nonces: [NUM_FRAMES][VAULT_NONCE_BYTES]byte

	for i in 0..<NUM_FRAMES {
		enc_b64 := extract_json_string(frames[i], "enc_b64", "")
		payload, err := base64.decode(enc_b64, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "base64 decode of payload must succeed")
		testing.expect(t, len(payload) >= VAULT_HEADER_BYTES, "payload must contain header")

		copy(nonces[i][:], payload[0:VAULT_NONCE_BYTES])

		// Salt check: fixed field matches across all frames
		testing.expect_value(t, nonces[i][0], fixed_salt[0])
		testing.expect_value(t, nonces[i][1], fixed_salt[1])
		testing.expect_value(t, nonces[i][2], fixed_salt[2])
		testing.expect_value(t, nonces[i][3], fixed_salt[3])

		// Monotonic sequence counter check (big-endian 64-bit integer)
		expected_seq := u64(i + 1)
		seq_in_nonce := (u64(nonces[i][4]) << 56) |
			(u64(nonces[i][5]) << 48) |
			(u64(nonces[i][6]) << 40) |
			(u64(nonces[i][7]) << 32) |
			(u64(nonces[i][8]) << 24) |
			(u64(nonces[i][9]) << 16) |
			(u64(nonces[i][10]) << 8) |
			u64(nonces[i][11])
		testing.expect_value(t, seq_in_nonce, expected_seq)
	}

	// Verify all nonces are distinct (strictly no nonce reuse)
	for i in 0..<NUM_FRAMES {
		for j in (i + 1)..<NUM_FRAMES {
			same := true
			for b in 0..<VAULT_NONCE_BYTES {
				if nonces[i][b] != nonces[j][b] {
					same = false
					break
				}
			}
			testing.expect(t, !same, fmt.tprintf("nonce %d and %d must not match", i, j))
		}
	}
}

@(test)
test_pty_stream_screen_payload_encryption :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_shell_stream_mutex)
	defer sync.mutex_unlock(&test_shell_stream_mutex)
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()

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

	worker := Bridge_PTY_Stream_Worker{
		session_id = "sh_stream_screen_test",
		shell_id = "sh_stream_screen_test",
		active = true,
		salt = [4]byte{0x55, 0x66, 0x77, 0x88},
		seq = 0,
	}

	screen_rows := []string{"row 1", "row 2", "row 3"}
	payload_str := bridge_pty_stream_screen_payload(screen_rows)
	defer delete(payload_str)

	bridge_pty_stream_emit_frame(&worker, "sh_stream_screen_test", transmute([]byte)payload_str)

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f, runtime.heap_allocator())
		delete(frames)
	}

	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		frame := frames[0]
		enc_b64 := extract_json_string(frame, "enc_b64", "")
		testing.expect(t, enc_b64 != "", "screen snapshot must be emitted as enc_b64")

		decrypted, dec_ok := bridge_pty_stream_decrypt_chunk(enc_b64, TEST_ENC_VAULT_KEY, context.temp_allocator)
		testing.expect(t, dec_ok, "screen snapshot decryption must succeed")
		testing.expect_value(t, string(decrypted), "row 1\r\nrow 2\r\nrow 3")
	}
}

@(test)
test_shell_pty_input_decrypts_valid_enc_b64 :: proc(t: ^testing.T) {
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

	input_keystrokes := "uname -a\n"
	enc_b64, enc_ok := bridge_pty_stream_encrypt_chunk(
		transmute([]byte)input_keystrokes,
		[4]byte{0x01, 0x02, 0x03, 0x04},
		100,
		TEST_ENC_VAULT_KEY,
		context.temp_allocator,
	)
	testing.expect(t, enc_ok, "encryption of input keystrokes must succeed")

	cmd := fmt.tprintf(`{{"type":"shell_pty_input","command_id":"cmd_input_valid","shell_id":"sh_nonexistent_valid","enc_b64":"%s"}}`, enc_b64)
	bridge_hub_handle_shell_pty_input(nil, cmd)

	res, res_ok := bridge_runtime_cached_command("cmd_input_valid")
	testing.expect(t, res_ok, "command result cached")
	testing.expect(t, strings.contains(res, "succeeded"), "valid encrypted input is decrypted and dispatched to pty")
}

@(test)
test_shell_pty_input_decrypts_valid_armored_data_b64 :: proc(t: ^testing.T) {
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

	input_keystrokes := "echo armored\n"
	enc_b64, enc_ok := bridge_pty_stream_encrypt_chunk(
		transmute([]byte)input_keystrokes,
		[4]byte{0x05, 0x06, 0x07, 0x08},
		101,
		TEST_ENC_VAULT_KEY,
		context.temp_allocator,
	)
	testing.expect(t, enc_ok, "encryption of input keystrokes must succeed")

	armored := strings.concatenate({VAULT_ARMOR_PREFIX, enc_b64}, context.temp_allocator)
	cmd := fmt.tprintf(`{{"type":"shell_pty_input","command_id":"cmd_input_armored_valid","shell_id":"sh_nonexistent_valid","data_b64":"%s"}}`, armored)
	bridge_hub_handle_shell_pty_input(nil, cmd)

	res, res_ok := bridge_runtime_cached_command("cmd_input_armored_valid")
	testing.expect(t, res_ok, "command result cached")
	testing.expect(t, strings.contains(res, "succeeded"), "valid armored data_b64 input is decrypted and dispatched to pty")
}

@(test)
test_shell_pty_input_drops_tampered_enc_b64 :: proc(t: ^testing.T) {
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

	input_keystrokes := "rm -rf /\n"
	enc_b64, enc_ok := bridge_pty_stream_encrypt_chunk(
		transmute([]byte)input_keystrokes,
		[4]byte{0x01, 0x02, 0x03, 0x04},
		101,
		TEST_ENC_VAULT_KEY,
		context.temp_allocator,
	)
	testing.expect(t, enc_ok, "encryption of input keystrokes must succeed")

	// Tamper with ciphertext by replacing middle bytes
	tampered_bytes := transmute([]byte)strings.clone(enc_b64, context.temp_allocator)
	if len(tampered_bytes) > 20 {
		tampered_bytes[15] = (tampered_bytes[15] == 'A') ? 'B' : 'A'
		tampered_bytes[16] = (tampered_bytes[16] == 'A') ? 'B' : 'A'
	}
	tampered := string(tampered_bytes)

	cmd := fmt.tprintf(`{{"type":"shell_pty_input","command_id":"cmd_input_tampered","shell_id":"sh_nonexistent_tampered","enc_b64":"%s"}}`, tampered)
	bridge_hub_handle_shell_pty_input(nil, cmd)

	res, res_ok := bridge_runtime_cached_command("cmd_input_tampered")
	testing.expect(t, res_ok, "tampered command rejected and recorded")
	testing.expect(t, strings.contains(res, "failed"), "tampered input must fail validation and be dropped")
}

@(test)
test_shell_pty_input_drops_mismatched_key_enc_b64 :: proc(t: ^testing.T) {
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

	// Encrypted with ALT key, Bridge uses TEST key
	enc_b64, enc_ok := bridge_pty_stream_encrypt_chunk(
		transmute([]byte)string("whoami\n"),
		[4]byte{0xAA, 0xBB, 0xCC, 0xDD},
		102,
		TEST_ALT_VAULT_KEY,
		context.temp_allocator,
	)
	testing.expect(t, enc_ok, "encryption with alt key succeeds")

	cmd := fmt.tprintf(`{{"type":"shell_pty_input","command_id":"cmd_input_mismatched","shell_id":"sh_nonexistent_alt","enc_b64":"%s"}}`, enc_b64)
	bridge_hub_handle_shell_pty_input(nil, cmd)

	res, res_ok := bridge_runtime_cached_command("cmd_input_mismatched")
	testing.expect(t, res_ok, "mismatched key command rejected and recorded")
	testing.expect(t, strings.contains(res, "failed"), "mismatched key input must fail and be dropped")
}

@(test)
test_shell_pty_input_drops_plaintext_when_vault_active :: proc(t: ^testing.T) {
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

	// Plaintext data with no enc_b64 when vault is active
	cmd := `{"type":"shell_pty_input","command_id":"cmd_input_plain_rejected","shell_id":"sh_nonexistent_plain","data":"echo unencrypted"}`
	bridge_hub_handle_shell_pty_input(nil, cmd)

	res, res_ok := bridge_runtime_cached_command("cmd_input_plain_rejected")
	testing.expect(t, res_ok, "unencrypted input command rejected and recorded")
	testing.expect(t, strings.contains(res, "failed"), "plaintext input must be dropped when vault key is active")
}
