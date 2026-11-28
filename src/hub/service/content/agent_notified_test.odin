package content

import "core:mem/virtual"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

// The bridge's agent_notice_typed report moves the conversation's message
// high-water mark: only the owning bridge, only a user->agent message of the
// instance's conversation, only forward. No clock is involved.

AN_TEST_BRIDGE :: "brg_an"

@(test)
test_note_agent_notice_typed_is_owner_bridge_only_and_monotonic :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t); if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test; reply_test_wire(&f, &db)
	reply_test_seed_conversation(t, &f)
	reply_test_seed_conversation(t, &f, "chat_other", "inst_other")
	_, saved, _ := iface.agent_save_instance(&f.repos.agents, domain.Agent_Instance{agent_instance_id = REPLY_TEST_INSTANCE, owner_user_id = REPLY_TEST_OWNER, agent_id = "agt_reply", bridge_id = AN_TEST_BRIDGE, runtime_status = "running", conversation_id = REPLY_TEST_CONVERSATION})
	if !testing.expect(t, saved) do return
	reply_test_user_message(t, &f, "msg_1")
	reply_test_user_message(t, &f, "msg_2")
	reply_test_user_message(t, &f, "msg_agent", direction = "agent_to_user")
	reply_test_user_message(t, &f, "msg_elsewhere", cid = "chat_other")
	stored :: proc(f: ^Reply_Origin_Test) -> string {
		through, _ := iface.content_agent_notified_through(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION)
		return through.message_id
	}

	// Another bridge, an unknown instance or a missing identity changes nothing.
	_, moved, err := note_agent_notice_typed(&f.svc, "brg_other", REPLY_TEST_INSTANCE, "msg_1")
	testing.expect(t, !moved && err.code == .Not_Found)
	_, moved, err = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, "inst_unknown", "msg_1")
	testing.expect(t, !moved && err.code == .Not_Found)
	_, moved, err = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, "")
	testing.expect(t, !moved && err.code == .Validation_Failed)
	// Another conversation's message or an agent->user message is rejected.
	_, moved, err = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, "msg_elsewhere")
	testing.expect(t, !moved && err.code == .Not_Found)
	_, moved, err = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, "msg_agent")
	testing.expect(t, !moved && err.code == .Not_Found)
	testing.expect_value(t, stored(&f), "")

	// The owning bridge's report lands on the instance's conversation.
	c, moved2, err2 := note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, "msg_2")
	testing.expect(t, moved2 && err2.code == .None)
	testing.expect_value(t, c.conversation_id, REPLY_TEST_CONVERSATION)
	testing.expect_value(t, stored(&f), "msg_2")
	// Idempotent; an earlier message never moves it back.
	_, moved, _ = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, "msg_2")
	testing.expect(t, !moved)
	_, moved, _ = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, "msg_1")
	testing.expect(t, !moved)
	testing.expect_value(t, stored(&f), "msg_2")
	// A later message moves it; a delivered notice Send now stamps the latest.
	reply_test_user_message(t, &f, "msg_3")
	testing.expect(t, note_agent_notified_latest(&f.svc, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION))
	testing.expect_value(t, stored(&f), "msg_3")
}
