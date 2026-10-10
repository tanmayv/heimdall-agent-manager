package http

// Golden WebCrypto keystroke bytes pin the UI → Hub → Bridge payload layout.
// Only the envelope changed: one data_b64 field plus is_encrypted=true.

import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"

C1_GOLDEN_KEY_HEX :: "4f1c2a9d8e7b6a5c4d3e2f10112233445566778899aabbccddeeff0011223344"
C1_GOLDEN_PLAINTEXT :: "ls -la\n"
C1_GOLDEN_ENC_B64 :: "vFQrdD8pfrvPMg80AH82Q+0Ryd+5fD++WZUYiGUzlU+BsSo="
C1_GOLDEN_FRAME :: `{"type":"input","data_b64":"vFQrdD8pfrvPMg80AH82Q+0Ryd+5fD++WZUYiGUzlU+BsSo=","is_encrypted":true}`

@(test)
test_agent_pane_relays_real_browser_armored_frame :: proc(t: ^testing.T) {
	frame := shell_stream_decode_input_frame(C1_GOLDEN_FRAME)
	defer shell_stream_input_destroy(&frame)

	testing.expect_value(t, frame.kind, Shell_Stream_Input_Kind.Armored)
	testing.expect_value(t, frame.armored, C1_GOLDEN_ENC_B64)
	// REQ-PANE-INPUT-6: the Hub holds no vault key, so it must never claim a plaintext.
	testing.expect_value(t, frame.plain, "")

	cmd := agent_service.agent_pty_input_command_json("cmd_golden", "inst_golden", frame.plain, frame.armored)
	defer delete(cmd)

	testing.expect(t, strings.contains(cmd, "\"type\":\"shell_pty_input\""), "bridge command type")
	// The bridge resolves the pty from shell_id, falling back to agent_instance_id
	// (src/bridge/hub_runtime_client.odin:1334-1337); the agent pane supplies both.
	testing.expect(t, strings.contains(cmd, "\"agent_instance_id\":\"inst_golden\""), "pty addressed by agent_instance_id")
	testing.expect(
		t,
		strings.contains(cmd, strings.concatenate({"\"data_b64\":\"", C1_GOLDEN_ENC_B64, "\""}, context.temp_allocator)),
		"ciphertext relayed byte-for-byte",
	)
	testing.expect(t, strings.contains(cmd, "\"is_encrypted\":true"))
	testing.expect(t, !strings.contains(cmd, "enc_b64"))
	testing.expect(t, !strings.contains(cmd, "vault:v1:"))
	testing.expect(t, !strings.contains(cmd, "\"data\":"))
}
