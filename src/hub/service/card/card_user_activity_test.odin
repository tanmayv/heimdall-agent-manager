package card

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"

Card_Activity_Capture :: struct { ids: [dynamic]string }

card_activity_capture :: proc(ctx: rawptr, instance_id: string) {
	c := (^Card_Activity_Capture)(ctx)
	append(&c.ids, strings.clone(instance_id))
}

// REQ-CIS-1: the user answering a coordinator's action card (sent with chat
// send --actions) resets that coordinator's idle stamp; a card no message
// carried, a snooze, and an agent acting on a card do not.
@(test)
test_user_answering_sent_action_card_reports_activity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened, "open") do return
	defer sqlite.close(&conn)
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated, "migrations") do return
	card_impl := sqlite.Card_Repo_SQLite{conn = &conn}
	card_repo := sqlite.new_card_repository(&card_impl, &conn)
	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)
	agent_impl := sqlite.Agent_Repo_SQLite{conn = &conn}
	agent_repo := sqlite.new_agent_repository(&agent_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	content := content_service.new_content_service(&content_repo, &agent_repo, nil, nil, nil, &clock, &ids)
	capture: Card_Activity_Capture
	content.user_activity = content_service.User_Activity_Hook{ctx = &capture, run = card_activity_capture}
	svc := new_card_service(cards = &card_repo, projects = nil, content = &content, clock = &clock, ids = &ids)
	user := contracts.Auth_Context{kind = .Session, user_id = "u_card_act"}
	agent := contracts.Auth_Context{kind = .Instance_Token, user_id = "u_card_act", agent_instance_id = "inst_card_coord"}
	now := platform.clock_now(&clock)
	carry := proc(t: ^testing.T, repo: ^iface.Content_Repository, id, action_ids, now: string) {
		_, ok, err := iface.content_save_message(repo, domain.Chat_Message{message_id = id, conversation_id = "chat_card_coord", owner_user_id = "u_card_act", direction = "agent_to_user", sender_agent_id = "agt_card", sender_agent_instance_id = "inst_card_coord", body = "please approve", artifact_ids_json = "[]", message_type = "text", message_status = "complete", metadata_json = fmt.tprintf(`{{"action_ids":%s}}`, action_ids), created_at = now})
		testing.expectf(t, ok, "save carrying message: %s", err.message)
	}
	make_card := proc(t: ^testing.T, svc: ^Card_Service, auth: contracts.Auth_Context, title: string) -> domain.Card {
		card, ok, err := create_card(svc, auth, Card_Input{project_id = "proj_card", title = title, scope = "project", provider = "agent", operations_json = "[]"})
		testing.expectf(t, ok, "create card: %s", err.message)
		return card
	}

	sent := make_card(t, &svc, user, "sent by the coordinator")
	carry(t, &content_repo, "msg_card_sent", fmt.tprintf(`["%s"]`, sent.card_id), now)
	accepted, ok, err := accept_card(&svc, user, sent.card_id)
	if !testing.expectf(t, ok, "accept: %s", err.message) do return
	note_card_answered(&svc, user, "accept", accepted)
	if !testing.expect_value(t, len(capture.ids), 1) do return
	testing.expect_value(t, capture.ids[0], "inst_card_coord")

	// Snoozing is not an answer; an agent acting on a card is not a user event.
	note_card_answered(&svc, user, "snooze", accepted)
	note_card_answered(&svc, agent, "accept", accepted)
	testing.expect_value(t, len(capture.ids), 1)

	// A card no message carried (only a near-miss id is carried) has no addressee.
	orphan := make_card(t, &svc, user, "curator card")
	carry(t, &content_repo, "msg_card_near", fmt.tprintf(`["%s9"]`, orphan.card_id), now)
	discarded, dok, derr := discard_card(&svc, user, orphan.card_id)
	if !testing.expectf(t, dok, "discard: %s", derr.message) do return
	note_card_answered(&svc, user, "discard", discarded)
	testing.expect_value(t, len(capture.ids), 1)
}
