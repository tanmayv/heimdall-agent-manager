// MSG-1 coverage: chat MESSAGE bodies are searchable via chat_messages_fts
// (migration 031) through the 'message' search provider. Verifies a body match is
// found through the REAL insert path (content repo save_message => AI trigger),
// carries id=message_id + route=/conversations/<agent_instance_id> +
// sublabel=conversation title + a body preview, is owner-isolated, surfaces by
// DEFAULT (no explicit types filter), and EXCLUDES non-user-visible rows
// (direction=agent_to_agent and non-'text' message_type).
package hub_search_messages_test

import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

TS :: "2026-01-01T00:00:00Z"

seed_conversation :: proc(repo: ^iface.Content_Repository, id, owner, inst, title: string) {
	_, ok, err := iface.content_save_conversation(repo, domain.Chat_Conversation{
		conversation_id = id, owner_user_id = domain.User_ID(owner),
		agent_id = "agt", agent_instance_id = inst, title = title,
		created_at = TS, updated_at = TS,
	})
	check(ok, fmt.tprintf("seed conversation %s: %s", id, err.message))
}

seed_message :: proc(repo: ^iface.Content_Repository, id, conv, owner, direction, mtype, body: string) {
	_, ok, err := iface.content_save_message(repo, domain.Chat_Message{
		message_id = id, conversation_id = conv, owner_user_id = domain.User_ID(owner),
		direction = direction, message_type = mtype, message_status = "complete",
		body = body, created_at = TS,
	})
	check(ok, fmt.tprintf("seed message %s: %s", id, err.message))
}

search :: proc(repo: ^iface.Search_Repository, owner, q, types: string) -> iface.Search_Result {
	result, err := iface.search_resources(repo, iface.Search_Query{
		owner_user_id = domain.User_ID(owner), q = q, types_csv = types,
		response_limit = 50, hard_scan_cap = 200,
	})
	check(err.code == .None, fmt.tprintf("search error: %s", err.message))
	return result
}

find :: proc(hits: []iface.Search_Hit, id: string) -> (iface.Search_Hit, bool) {
	for hit in hits do if hit.id == id do return hit, true
	return {}, false
}

main :: proc() {
	db_path := "/tmp/hub_search_messages.db"
	_ = os.remove(db_path); defer _ = os.remove(db_path)
	conn, open_ok, open_err := sqlite.open(db_path)
	check(open_ok, fmt.tprintf("open db: %s", open_err.message))
	defer sqlite.close(&conn)
	check(sqlite.fts5_available(&conn), "FTS5 must be available")
	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	check(mig_ok, fmt.tprintf("run_migrations: %s", mig_err.message))
	check(sqlite.sqlite_object_exists(&conn, "chat_messages_fts"), "migration 031 must create chat_messages_fts")

	content_impl: sqlite.Content_Repo_SQLite
	crepo := sqlite.new_content_repository(&content_impl, &conn)

	// Owner u: one visible text message (should match) + two non-visible variants.
	seed_conversation(&crepo, "cid_u", "u", "inst_u", "Deploy chat")
	seed_message(&crepo, "msg_u", "cid_u", "u", "user_to_agent", "text", "please zephyrmatch the deploy runbook")
	seed_message(&crepo, "msg_u_a2a", "cid_u", "u", "agent_to_agent", "text", "zephyrmatch agent-to-agent chatter")
	seed_message(&crepo, "msg_u_status", "cid_u", "u", "agent_to_user", "status_update", "zephyrmatch status update")
	// Owner v: isolation control.
	seed_conversation(&crepo, "cid_v", "v", "inst_v", "Other chat")
	seed_message(&crepo, "msg_v", "cid_v", "v", "user_to_agent", "text", "zephyrmatch foreign body")

	repo_impl: sqlite.Search_Repo_SQLite
	repo := sqlite.new_search_repository(&repo_impl, &conn)

	// (1) body match found with the agreed hit shape (id/route/sublabel/preview).
	res := search(&repo, "u", "zephyrmatch", "message")
	hit, ok := find(res.hits, "msg_u")
	check(ok, "owner u must find their visible text message by body")
	check(hit.resource_type == "message", fmt.tprintf("resource_type must be 'message', got %q", hit.resource_type))
	check(hit.route == "/conversations/inst_u", fmt.tprintf("route must be /conversations/<agent_instance_id>, got %q", hit.route))
	check(hit.sublabel == "Deploy chat", fmt.tprintf("sublabel must be the conversation title, got %q", hit.sublabel))
	check(strings.contains(hit.preview, "zephyrmatch"), fmt.tprintf("preview must include the matched body term, got %q", hit.preview))

	// (2) non-user-visible rows are excluded (agent_to_agent + non-'text').
	_, a2a := find(res.hits, "msg_u_a2a")
	check(!a2a, "agent_to_agent messages must NOT be surfaced")
	_, sys := find(res.hits, "msg_u_status")
	check(!sys, "non-'text' (status_update) messages must NOT be surfaced")

	// (3) owner isolation both ways.
	_, leaked := find(res.hits, "msg_v")
	check(!leaked, "owner u must not see owner v's message")
	res_v := search(&repo, "v", "zephyrmatch", "message")
	_, v_ok := find(res_v.hits, "msg_v")
	check(v_ok, "owner v must find their own message")
	_, u_leak := find(res_v.hits, "msg_u")
	check(!u_leak, "owner v must not see owner u's message")

	// (4) messages surface by DEFAULT (no explicit types filter) — wired into
	// SEARCH_TYPE_ORDER + normalize_search_type so REST/RPC/ctl all include them.
	res_all := search(&repo, "u", "zephyrmatch", "")
	_, default_ok := find(res_all.hits, "msg_u")
	check(default_ok, "message hits must appear in an unfiltered (all-types) search")

	fmt.println("PASS: hub search messages (body match + shape + visibility filter + owner isolation + default type)")
}
