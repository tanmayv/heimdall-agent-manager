package hub_agent_to_agent_recency_test

// Regression: agent_to_agent chat messages must bump the target conversation's
// last_message_at / last_message_preview / updated_at so recency-sorted clients
// (TUI/UI list_conversations) surface the conversation instead of leaving it
// stale at the bottom. Mirrors send_message (user_to_agent) semantics.

import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"

// Deterministic monotonic clock: each read advances one second so ordering is
// stable regardless of wall-clock resolution.
fake_clock_seconds: int

fake_clock_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	fake_clock_seconds += 1
	return fmt.aprintf("2026-07-23T00:%02d:%02dZ", fake_clock_seconds / 60, fake_clock_seconds % 60)
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }

main :: proc() {
	db_path := "/tmp/heimdall-hub-a2a-recency-test.db"
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, app.Hub_Config{database_path = db_path, migrations_dir = "src/hub/repository/sqlite/migrations", bind_host = "127.0.0.1", port = 49691, username_header = "X-authentik-username", display_name_header = "X-authentik-name", email_header = "X-authentik-email", trusted_proxy_cidrs = cidrs[:], auto_provision_users = true, logout_url = "/_dev/logout"})
	check(ok, message)
	// Install the deterministic clock (services hold &graph.clock, so mutating
	// its fields in place takes effect for all subsequent clock_now reads).
	graph.clock.now = fake_clock_now
	graph.clock.ctx = nil

	owner := domain.User_ID("alice")
	seed := "2026-07-23T00:00:00Z"

	// Sender agent + instance.
	sender_agent := "agent_sender"
	sender_inst := "inst_sender"
	_, sa_ok, sa_err := iface.agent_save(&graph.repos.agents, domain.Agent{agent_id = sender_agent, owner_user_id = owner, name = "Sender", slug = "sender", default_provider = "claude", default_tier = "normal", state = .Active, created_at = seed, updated_at = seed})
	check(sa_ok, sa_err.message)
	_, si_ok, si_err := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{agent_instance_id = sender_inst, owner_user_id = owner, agent_id = sender_agent, bridge_id = "bridge_x", provider = "claude", tier = "normal", chain_id = "chain_x", runtime_status = "running", startup_status = "ready", activity_status = "idle", created_at = seed, updated_at = seed, started_at = seed, last_seen_at = seed})
	check(si_ok, si_err.message)

	// Target agent + instance (recipient of the agent_to_agent message).
	target_agent := "agent_target"
	target_inst := "inst_target"
	_, ta_ok, ta_err := iface.agent_save(&graph.repos.agents, domain.Agent{agent_id = target_agent, owner_user_id = owner, name = "Target", slug = "target", default_provider = "claude", default_tier = "normal", state = .Active, created_at = seed, updated_at = seed})
	check(ta_ok, ta_err.message)
	_, ti_ok, ti_err := iface.agent_save_instance(&graph.repos.agents, domain.Agent_Instance{agent_instance_id = target_inst, owner_user_id = owner, agent_id = target_agent, bridge_id = "bridge_x", provider = "claude", tier = "normal", chain_id = "chain_x", runtime_status = "running", startup_status = "ready", activity_status = "idle", created_at = seed, updated_at = seed, started_at = seed, last_seen_at = seed})
	check(ti_ok, ti_err.message)

	user_auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = string(owner), name = string(owner)}

	// Target conversation is created FIRST (oldest last_message_at).
	target_conv, tc_ok, tc_err := content_service.create_conversation(&graph.content, user_auth, content_service.Chat_Input{agent_id = target_agent, agent_instance_id = target_inst, title = "Target Chat"})
	check(tc_ok, tc_err.message)

	// A second, newer conversation created AFTER the target so it sorts ahead
	// until the target receives an agent_to_agent message.
	other_conv, oc_ok, oc_err := content_service.create_conversation(&graph.content, user_auth, content_service.Chat_Input{agent_id = sender_agent, agent_instance_id = sender_inst, title = "Other Chat"})
	check(oc_ok, oc_err.message)

	// Capture the target conversation's pre-message recency baseline.
	before, before_ok, _ := content_service.get_conversation(&graph.content, user_auth, target_conv.conversation_id)
	check(before_ok, "target conversation must be readable before a2a send")

	// Sender (instance token) sends an agent_to_agent message to the target.
	sender_auth := contracts.Auth_Context{kind = .Instance_Token, agent_instance_id = sender_inst, user_id = string(owner)}
	body := "worker status: build green, handing off"
	msg, sent, send_err := content_service.send_agent_to_agent(&graph.content, sender_auth, target_inst, content_service.Message_Input{body = body})
	check(sent, send_err.message)
	check(msg.direction == "agent_to_agent" && msg.body == body, "message must persist as agent_to_agent with the sent body")

	// Recency fields on the target conversation must advance to the sent body.
	after, after_ok, _ := content_service.get_conversation(&graph.content, user_auth, target_conv.conversation_id)
	check(after_ok, "target conversation must be readable after a2a send")
	check(after.last_message_preview == body, fmt.tprintf("last_message_preview must equal sent body, got %q", after.last_message_preview))
	check(after.last_message_at > before.last_message_at, fmt.tprintf("last_message_at must advance (%q -> %q)", before.last_message_at, after.last_message_at))
	check(after.updated_at > before.updated_at, fmt.tprintf("updated_at must advance (%q -> %q)", before.updated_at, after.updated_at))
	// unread_count must NOT be bumped: the agent inbox unread is derived from
	// read receipts (read_at=''), not this counter; matches send_message.
	check(after.unread_count == before.unread_count, fmt.tprintf("unread_count must not change on a2a (%d -> %d)", before.unread_count, after.unread_count))

	// list_conversations is recency-sorted DESC by last_message_at; the target,
	// though created before "Other Chat", must now sort ahead of it.
	convs, list_err := content_service.list_conversations(&graph.content, user_auth, 50, "")
	check(list_err.code == .None, list_err.message)
	target_idx := -1
	other_idx := -1
	for c, i in convs {
		if c.conversation_id == target_conv.conversation_id do target_idx = i
		if c.conversation_id == other_conv.conversation_id do other_idx = i
	}
	check(target_idx >= 0 && other_idx >= 0, "both conversations must appear in list_conversations")
	check(target_idx < other_idx, fmt.tprintf("target (a2a-updated) must sort ahead of older other conversation (target_idx=%d other_idx=%d)", target_idx, other_idx))

	fmt.println("PASS: hub agent_to_agent conversation recency bump")
	app.shutdown_graph(&graph)
	_ = os.remove(db_path)
	os.exit(0)
}
