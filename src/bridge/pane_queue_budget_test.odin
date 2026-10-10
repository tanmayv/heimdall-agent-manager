package main

import "base:runtime"
import "core:strings"
import "core:os"
import "core:sync"
import "core:testing"

@(test)
pane_overflow_detaches_only_affected_stream_and_requests_resync :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	slow := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	healthy := Bridge_PTY_Stream_Worker{active = true, fd = -1}
	heap := runtime.heap_allocator()
	chunk := strings.repeat("x", 32 * 1024, heap)
	defer delete(chunk, heap)
	_bridge_pty_stream_deliver_or_queue(&healthy, strings.clone("healthy", heap), heap, "healthy")
	for i in 0..<12 do _bridge_pty_stream_deliver_or_queue(&slow, strings.clone(chunk, heap), heap, "slow")
	testing.expect(t, !sync.atomic_load(&slow.active))
	testing.expect(t, sync.atomic_load(&healthy.active))
	testing.expect(t, bridge_pty_stream_outgoing_bytes <= BRIDGE_PANE_QUEUE_BYTES)
	frames := bridge_pty_stream_take_outgoing()
	defer { for frame in frames do delete(frame, heap); delete(frames) }
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		testing.expect_value(t, frames[0], "healthy")
		testing.expect(t, strings.contains(frames[1], "pane_resync_required"))
	}
	testing.expect_value(t, bridge_pty_stream_outgoing_bytes, 0)
}

@(test)
pane_large_encrypted_snapshot_splits_before_encryption :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	bridge_pty_stream_reset()
	defer bridge_pty_stream_reset()
	prev_key, found := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer { if found { _ = os.set_env("HEIMDALL_VAULT_KEY", prev_key); delete(prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEY") } }
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ENC_VAULT_KEY)
	worker := Bridge_PTY_Stream_Worker{active = true, emitting_snapshot = true, fd = -1}
	source := strings.repeat("λ", 256 * 1024)
	defer delete(source)
	bridge_pty_stream_emit_frame(&worker, "pane", transmute([]byte)source)
	frames := bridge_pty_stream_take_outgoing()
	defer { for frame in frames do delete(frame, runtime.heap_allocator()); delete(frames) }
	result := make([dynamic]byte)
	defer delete(result)
	testing.expect_value(t, len(frames), 64)
	for frame in frames {
		testing.expect(t, strings.contains(frame, "\"is_encrypted\":true"))
		testing.expect(t, strings.contains(frame, "\"is_snapshot\":true"))
		testing.expect(t, !strings.contains(frame, "enc_b64"))
		payload := extract_json_string(frame, "data_b64", "")
		bytes, ok := bridge_pty_stream_decrypt_chunk(payload, TEST_ENC_VAULT_KEY)
		testing.expect(t, ok)
		append(&result, ..bytes)
		delete(bytes)
		delete(payload)
	}
	testing.expect_value(t, string(result[:]), source)
}

@(test)
pane_decrypts_real_browser_golden_input :: proc(t: ^testing.T) {
 ciphertext := "vault:v1:vFQrdD8pfrvPMg80AH82Q+0Ryd+5fD++WZUYiGUzlU+BsSo="
 key := "4f1c2a9d8e7b6a5c4d3e2f10112233445566778899aabbccddeeff0011223344"
 plain, ok := bridge_decrypt_vault_ciphertext_hex(ciphertext, key)
 defer if ok do delete(plain)
 testing.expect(t, ok)
 testing.expect_value(t, plain, "ls -la\n")
}
