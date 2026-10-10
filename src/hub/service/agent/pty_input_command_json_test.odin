package agent

import base64 "core:encoding/base64"
import "core:strings"
import "core:testing"
import jsonx "odin_test:lib/jsonx"

@(test)
agent_pty_input_command_json_formats_payload :: proc(t: ^testing.T) {
	original := "\x03\x1b[A\"hello\\world\"\n"
	got := agent_pty_input_command_json("cmd_123", "inst_456", original)
	defer delete(got)
	data := jsonx.extract_string(got, "data_b64")
	defer delete(data)
	decoded, err := base64.decode(data)
	defer delete(decoded)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(decoded), original)
	testing.expect(t, strings.contains(got, "\"is_encrypted\":false"))
	testing.expect(t, strings.contains(got, "\"agent_instance_id\":\"inst_456\""))
	testing.expect(t, !strings.contains(got, "enc_b64"))
}

@(test)
agent_pty_input_command_json_relays_one_ciphertext :: proc(t: ^testing.T) {
	got := agent_pty_input_command_json("cmd_enc", "inst_enc", "", "QUJDREVG")
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"data_b64\":\"QUJDREVG\""))
	testing.expect(t, strings.contains(got, "\"is_encrypted\":true"))
	testing.expect(t, !strings.contains(got, "enc_b64"))
	testing.expect(t, !strings.contains(got, "vault:v1:"))
	testing.expect(t, !strings.contains(got, "\"data\":"))
}
