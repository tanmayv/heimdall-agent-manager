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
	// Agent instance lifecycle verbs (agents launching/relaunching/stopping agents
	// they own) must be on the .Agent allow-list and off the .Wrapper one.
	check(bridge.bridge_local_method_allowed("agent.instances.launch", .Agent), "agent allowlist missing instances.launch")
	check(bridge.bridge_local_method_allowed("agent.instances.restart", .Agent), "agent allowlist missing instances.restart")
	check(bridge.bridge_local_method_allowed("agent.instances.stop", .Agent), "agent allowlist missing instances.stop")
	check(!bridge.bridge_local_method_allowed("agent.instances.launch", .Wrapper), "wrapper token must not launch instances")
	// Pure method+params -> hub path mapping.
	check(bridge.bridge_local_instance_lifecycle_path("agent.instances.launch", "{\"agent_id\":\"agt_x\"}") == "/api/v1/agent-instances", "launch must map to POST /api/v1/agent-instances")
	check(bridge.bridge_local_instance_lifecycle_path("agent.instances.restart", "{\"instance_id\":\"inst_z\"}") == "/api/v1/agent-instances/inst_z/restart", "restart must map to /<id>/restart")
	check(bridge.bridge_local_instance_lifecycle_path("agent.instances.stop", "{\"agent_instance_id\":\"inst_z\"}") == "/api/v1/agent-instances/inst_z/stop", "stop must accept agent_instance_id and map to /<id>/stop")
	check(bridge.bridge_local_instance_lifecycle_path("agent.instances.restart", "{}") == "", "restart without an instance id must yield empty path (rejected)")
	// H5 coordinator team-bootstrap admin verbs: allowlist (.Agent only) + pure
	// method -> (http_method, hub path) mapping. Same-owner scoping is enforced
	// hub-side via the instance token; the bridge only maps and relays.
	check(bridge.bridge_local_is_admin_method("agent.agents.list"), "admin: agents.list must be recognized")
	check(bridge.bridge_local_is_admin_method("agent.agents.create"), "admin: agents.create must be recognized")
	check(bridge.bridge_local_is_admin_method("agent.templates.list"), "admin: templates.list must be recognized")
	check(bridge.bridge_local_is_admin_method("agent.templates.create"), "admin: templates.create must be recognized")
	check(bridge.bridge_local_is_admin_method("agent.bridges.list"), "admin: bridges.list must be recognized")
	check(bridge.bridge_local_is_admin_method("agent.projects.list"), "admin: projects.list must be recognized")
	check(!bridge.bridge_local_is_admin_method("agent.chat.send_to_user"), "admin: non-admin method must not be classified as admin")
	check(bridge.bridge_local_method_allowed("agent.agents.list", .Agent), "agent allowlist missing agents.list")
	check(bridge.bridge_local_method_allowed("agent.templates.create", .Agent), "agent allowlist missing templates.create")
	check(bridge.bridge_local_method_allowed("agent.bridges.list", .Agent), "agent allowlist missing bridges.list")
	check(bridge.bridge_local_method_allowed("agent.projects.list", .Agent), "agent allowlist missing projects.list")
	check(!bridge.bridge_local_method_allowed("agent.agents.create", .Wrapper), "wrapper token must not create agents")
	check(!bridge.bridge_local_method_allowed("agent.templates.list", .Wrapper), "wrapper token must not list templates")
	m_list, p_list := bridge.bridge_local_admin_method_route("agent.agents.list")
	check(m_list == "GET" && p_list == "/api/v1/agents", "admin route: agents.list must map to GET /api/v1/agents")
	m_ac, p_ac := bridge.bridge_local_admin_method_route("agent.agents.create")
	check(m_ac == "POST" && p_ac == "/api/v1/agents", "admin route: agents.create must map to POST /api/v1/agents")
	m_tl, p_tl := bridge.bridge_local_admin_method_route("agent.templates.list")
	check(m_tl == "GET" && p_tl == "/api/v1/templates", "admin route: templates.list must map to GET /api/v1/templates")
	m_tc, p_tc := bridge.bridge_local_admin_method_route("agent.templates.create")
	check(m_tc == "POST" && p_tc == "/api/v1/templates", "admin route: templates.create must map to POST /api/v1/templates")
	m_bl, p_bl := bridge.bridge_local_admin_method_route("agent.bridges.list")
	check(m_bl == "GET" && p_bl == "/api/v1/bridges", "admin route: bridges.list must map to GET /api/v1/bridges")
	m_pl, p_pl := bridge.bridge_local_admin_method_route("agent.projects.list")
	check(m_pl == "GET" && p_pl == "/api/v1/projects", "admin route: projects.list must map to GET /api/v1/projects")
	m_unknown, p_unknown := bridge.bridge_local_admin_method_route("agent.nope")
	check(m_unknown == "" && p_unknown == "", "admin route: unknown method must map to empty route")
	// Spoof-guard still blocks owner/token fields on an admin verb create body.
	admin_spoof := bridge.bridge_local_endpoint_handle_jsonl_line(strings.concatenate({"{\"v\":1,\"id\":\"admin_spoof\",\"token\":\"", issued.plaintext_token, "\",\"method\":\"agent.agents.create\",\"params\":{\"name\":\"x\",\"owner_user_id\":\"usr_other\"}}"}))
	check(strings.contains(admin_spoof, "\"ok\":false") && strings.contains(admin_spoof, "forbidden"), "admin verbs must not let callers spoof owner_user_id")
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
