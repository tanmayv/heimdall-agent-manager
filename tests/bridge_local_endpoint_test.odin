package bridge_local_endpoint_test

import "core:fmt"
import "core:os"
import "core:strings"
import bridge "odin_test:bridge"

main :: proc() {
	bridge.bridge_runtime_init()
	bridge.bridge_agent_token_store_init()
	unix_cfg := bridge.bridge_local_endpoint_config_default("/tmp/heimdall-bridge-local-endpoint-test", 0)
	check(bridge.bridge_local_endpoint_env_value(unix_cfg, true) == "unix:/tmp/heimdall-bridge-local-endpoint-test/bridge.sock", "unix endpoint env must use run_dir bridge.sock")
	check(bridge.bridge_local_endpoint_start_unix(unix_cfg), "unix socket endpoint must start with owner-only mode")
	issued := bridge.bridge_agent_token_issue("inst_local", "hit_bridge_held", .Agent)
	check(strings.has_prefix(issued.plaintext_token, "hlat_"), "local token prefix missing")
	rec, ok := bridge.bridge_agent_token_verify(issued.plaintext_token)
	check(ok && rec.agent_instance_id == "inst_local" && rec.instance_token == "hit_bridge_held", "local token verify must resolve instance and Bridge-held instance token")
	check(!strings.contains(rec.token_hash, issued.plaintext_token) && strings.has_prefix(rec.token_hash, "sha1:"), "local token must be hashed at rest")
	check(bridge.bridge_local_method_allowed("agent.chat.send_to_user", .Agent), "agent allowlist missing chat")
	check(!bridge.bridge_local_method_allowed("wrapper.exited", .Agent), "agent token must not call wrapper methods")
	check(bridge.bridge_local_method_allowed("wrapper.startup.report", .Wrapper), "wrapper allowlist missing startup")
	check(!bridge.bridge_local_method_allowed("agent.tasks.comment", .Wrapper), "wrapper token must not call agent methods")
	ctx := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"ctx\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.context.get\",\"params\":{}}"}))
	check(strings.contains(ctx, "\"ok\":true") && strings.contains(ctx, "inst_local") && !strings.contains(ctx, "MISSING"), "context.get should resolve identity and return valid JSON")
	spaced_ctx := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{ \"v\" : 1, \"id\" : \"spaced\", \"token\" : \"", issued.plaintext_token, "\", \"method\" : \"agent.context.get\", \"params\" : { } }"}))
	check(strings.contains(spaced_ctx, "\"id\":\"spaced\"") && strings.contains(spaced_ctx, "\"ok\":true") && strings.contains(spaced_ctx, "inst_local"), "JSONL request parsing must accept normal whitespace")
	spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"spoof\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"wrapper.exited\",\"params\":{}}"}))
	check(strings.contains(spoof, "\"ok\":false") && strings.contains(spoof, "forbidden"), "local callers cannot cross role allowlists")
	identity_spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"spoof_identity\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.chat.send_to_user\",\"params\":{\"body\":\"bad\",\"sender_agent_instance_id\":\"inst_other\"}}"}))
	check(strings.contains(identity_spoof, "\"ok\":false") && strings.contains(identity_spoof, "forbidden"), "local callers cannot spoof sender identity")
	rotated, rotated_ok := bridge.bridge_agent_token_rotate(issued.plaintext_token)
	check(rotated_ok && rotated.plaintext_token != issued.plaintext_token, "rotation must issue a replacement token")
	_, old_ok := bridge.bridge_agent_token_verify(issued.plaintext_token)
	_, new_ok := bridge.bridge_agent_token_verify(rotated.plaintext_token)
	check(!old_ok && new_ok, "rotation must invalidate old token and verify new token")
	check(bridge.bridge_agent_token_invalidate(rotated.plaintext_token), "invalidate should accept active token")
	_, invalid_ok := bridge.bridge_agent_token_verify(rotated.plaintext_token)
	check(!invalid_ok, "invalidated token must fail verify")
	fmt.println("PASS: bridge local endpoint/token store")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
