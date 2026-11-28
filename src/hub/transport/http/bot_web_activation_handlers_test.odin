package http

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import project "odin_test:hub/service/project"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content "odin_test:hub/service/content"
import vault "odin_test:lib/vault"

Fresh_Web_Race :: struct {
	handlers: ^Content_Handlers,
	request: Request,
	barrier: ^sync.Barrier,
	status: int,
}
fresh_web_race_send :: proc(data: rawptr) {
	r := (^Fresh_Web_Race)(data)
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	_ = sync.barrier_wait(r.barrier)
	r.status = send_chat_message_handler(r.handlers, r.request).status
}
fresh_web_notify_count :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	if strings.contains(command.body_json, "notify_agent_message") do sync.atomic_add((^i32)(ctx), 1)
	return true, {}
}

@(test)
test_web_activation_owner_route_and_generation_receipt :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f := bot_http_fixture(t)
	defer bot_http_destroy(f)
	w := f.wire
	repos := iface.Repositories{content=f.content_repo, bots=f.bot_repo, agents=w.ag_repo}
	f.uow = sqlite.new_unit_of_work_factory(&f.uow_impl, &w.conn, &repos)
	svc := content.Content_Service{content=&repos.content, agents=&repos.agents, uow_factory=&f.uow, ids=&w.ids, clock=&w.clock}
	notified: i32
	svc.bridge_command_sink = {ctx=&notified, send_runtime_command=fresh_web_notify_count}
	h := Content_Handlers{auth=&w.auth_svc, content=&svc, write_policy={ctx=&f.service, read=bot_conversation_write_state}}
	path :: "/api/v1/bots/me/web-conversation"
	cid :: "chat_fresh"
	owner := string(w.owner)
	initial := bot_web_activation_handler(&f.handlers, bot_http_request(f, "GET", path, ""))
	testing.expect(t, initial.status == 200 && strings.contains(initial.body, `"generation":0`), initial.body)
	for malformed in ([]string{`{}`, `null`, `{"enabled":true,"expected_generation":-1}`, `{"enabled":"true","expected_generation":0}`}) {
		response := bot_web_activation_handler(&f.handlers, bot_http_request(f, "PUT", path, malformed))
		testing.expect(t, response.status == 422 || response.status == 400, response.body)
	}
	state := domain.Bot_Web_Activation{owner_user_id=owner, bot_id="bot_http_fresh", agent_instance_id=w.instance_id, conversation_id=cid, enabled=true, generation=1}
	testing.expect_value(t, iface.bot_web_activation_insert(&repos.bots, state).code, domain.Error_Code.None)
	_, chat_saved, chat_err := iface.content_save_conversation(&repos.content, {owner_user_id=w.owner, agent_id="agt_wire_tb2", agent_instance_id=w.instance_id, conversation_id=cid, created_at="now", updated_at="now"})
	testing.expect(t, chat_saved, chat_err.message)
	pane_req := bot_http_request(f, "GET", "/api/v1/chats/by-instance/inst_wire_tb2", "")
	pane := get_chat_by_instance_handler(&h, pane_req)
	testing.expect(t, pane.status == 200 && strings.contains(pane.body, `"write_generation":1`) && strings.contains(pane.body, `"writes_enabled":true`), pane.body)
	foreign_request := bot_http_request(f, "GET", path, "")
	foreign_request.headers = http_test_login(t, &w.auth_svc, "other_web_owner")
	response := bot_web_activation_handler(&f.handlers, foreign_request)
	testing.expect(t, response.status == 200 && !strings.contains(response.body, cid), response.body)

	material: [32]byte
	vid, _ := vault.vault_id_from_root_sign_pub(acp_chat_root())
	key, key_ok := vault.keyring_from_single_key(owner, vid, 1, material[:])
	if !testing.expect(t, key_ok) do return
	defer vault.keyring_wipe(&key)
	sealed, sealed_ok := vault.seal_string("fresh input", &key)
	if !testing.expect(t, sealed_ok) do return
	_, stored, art_err := iface.content_save_artifact(&repos.content, {
		artifact_id="art_fresh", owner_user_id=w.owner, kind="file", name="sealed attachment",
		content_type="text/plain", content=sealed, size_bytes=len(sealed), created_at="now", updated_at="now",
	})
	if !testing.expect(t, stored, art_err.message) do return
	input := struct {body, idempotency_key: string, activation_generation: int, artifact_ids: []string}{sealed, "browser-request", 1, {"art_fresh"}}
	body, _ := json.marshal(input, allocator=context.temp_allocator)
	send := bot_http_request(f, "POST", "/api/v1/chats/chat_fresh/messages", string(body))
	other := send
	other.headers = foreign_request.headers
	testing.expect(t, send_chat_message_handler(&h, other).status >= 400)
	barrier: sync.Barrier
	sync.barrier_init(&barrier, 2)
	races := [2]Fresh_Web_Race{{handlers=&h, request=send, barrier=&barrier}, {handlers=&h, request=send, barrier=&barrier}}
	left := thread.create_and_start_with_data(&races[0], fresh_web_race_send)
	right := thread.create_and_start_with_data(&races[1], fresh_web_race_send)
	defer thread.destroy(left)
	defer thread.destroy(right)
	thread.join(left)
	thread.join(right)
	testing.expectf(t, (races[0].status == 201 && races[1].status == 200) || (races[1].status == 201 && races[0].status == 200), "concurrent statuses %d and %d", races[0].status, races[1].status)
	first := send_chat_message_handler(&h, send)
	if !testing.expect(t, first.status == 200 && strings.contains(first.body, "art_fresh"), first.body) do return
	id := json_string(first.body, "message_id")
	testing.expect(t, strings.has_prefix(id, "msg_web_"))
	retry := send_chat_message_handler(&h, send)
	testing.expect(t, retry.status == 200 && json_string(retry.body, "message_id") == id, retry.body)

	pause := bot_web_activation_handler(&f.handlers, bot_http_request(f, "PUT", path, `{"enabled":false,"expected_generation":1}`))
	testing.expect(t, pause.status == 200 && strings.contains(pause.body, `"generation":2`), pause.body)
	testing.expect_value(t, send_chat_message_handler(&h, send).status, 200)
	changed := input
	changed.idempotency_key = "later-request"
	stale_body, _ := json.marshal(changed)
	stale := send
	stale.body = string(stale_body)
	testing.expect_value(t, send_chat_message_handler(&h, stale).status, 409)
	resumed := bot_web_activation_handler(&f.handlers, bot_http_request(f, "PUT", path, `{"enabled":true,"expected_generation":2}`))
	testing.expect(t, resumed.status == 200 && strings.contains(resumed.body, `"generation":3`), resumed.body)
	testing.expect_value(t, send_chat_message_handler(&h, stale).status, 409)
	changed.activation_generation = 3
	changed.body = "unsealed text"
	clear_body, _ := json.marshal(changed)
	stale.body = string(clear_body)
	testing.expect(t, send_chat_message_handler(&h, stale).status >= 400)
	changed.body, _ = vault.seal_string("a different input", &key)
	changed.idempotency_key = input.idempotency_key
	conflict, _ := json.marshal(changed)
	stale.body = string(conflict)
	testing.expect_value(t, send_chat_message_handler(&h, stale).status, 409)
	rows, list_err := iface.content_list_messages(&repos.content, cid, w.owner, 10, "")
	testing.expect(t, list_err.code == .None && len(rows) == 1 && rows[0].body == sealed)
	// Simulate retention removing the content. Its ID-only receipt must still
	// prevent a lost-ack retry from repopulating the transcript.
	testing.expect(t, sqlite.exec(&w.conn, "DELETE FROM chat_messages WHERE conversation_id='chat_fresh'"))
	testing.expect_value(t, send_chat_message_handler(&h, send).status, 404)
	_, exp_err := iface.experiment_set(&f.experiments, {owner_user_id=owner, key="bots", enabled=false, updated_at="later"})
	testing.expect_value(t, exp_err.code, domain.Error_Code.None)
	off := bot_web_activation_handler(&f.handlers, bot_http_request(f, "GET", path, ""))
	testing.expect(t, off.status == 200 && strings.contains(off.body, cid) && strings.contains(off.body, `"enabled":false`), off.body)
	pane = get_chat_by_instance_handler(&h, pane_req)
	testing.expect(t, pane.status == 200 && strings.contains(pane.body, `"write_generation":3`) && strings.contains(pane.body, `"writes_enabled":false`), pane.body)
	testing.expect_value(t, send_chat_message_handler(&h, send).status, 403)
	testing.expect_value(t, sync.atomic_load(&notified), i32(1))
}
