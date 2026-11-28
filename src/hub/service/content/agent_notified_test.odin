package content

import "core:mem/virtual"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

// agent_notified_at: the bridge's agent_notice_typed report stamps one
// monotonic time per conversation, clamped to the Hub's clock, and only the
// bridge that owns the instance may report it.

AN_TEST_NOW :: "2026-01-01T00:01:00Z"
AN_TEST_BRIDGE :: "brg_an"

an_test_clock_now :: proc(ctx: rawptr) -> string { return AN_TEST_NOW }

@(test)
test_agent_notified_time_clamps_to_hub_now :: proc(t: ^testing.T) {
	now := AN_TEST_NOW
	testing.expect_value(t, agent_notified_time(now, 0), now)
	testing.expect_value(t, agent_notified_time(now, 1767225630000), "2026-01-01T00:00:30Z") // bridge behind
	testing.expect_value(t, agent_notified_time(now, 1767225690000 + 60_000), now)       // bridge ahead
}

@(test)
test_note_agent_notice_typed_is_owner_bridge_only_and_monotonic :: proc(t: ^testing.T) {
	arena := reply_test_arena(); defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
	db, ok := reply_test_open(t); if !ok do return
	defer sqlite.close(&db)
	f: Reply_Origin_Test; reply_test_wire(&f, &db)
	f.clock = platform.Clock{now = an_test_clock_now}
	reply_test_seed_conversation(t, &f)
	_, saved, _ := iface.agent_save_instance(&f.repos.agents, domain.Agent_Instance{agent_instance_id = REPLY_TEST_INSTANCE, owner_user_id = REPLY_TEST_OWNER, agent_id = "agt_reply", bridge_id = AN_TEST_BRIDGE, runtime_status = "running", conversation_id = REPLY_TEST_CONVERSATION, created_at = AN_TEST_NOW, updated_at = AN_TEST_NOW})
	if !testing.expect(t, saved) do return
	stored :: proc(f: ^Reply_Origin_Test) -> string {
		at, _ := iface.content_agent_notified_at(&f.repos.content, REPLY_TEST_OWNER, REPLY_TEST_CONVERSATION)
		return at
	}
	t30 := i64(1767225630000) // 00:00:30Z

	// Another bridge, an unknown instance or a missing identity changes nothing.
	_, moved, err := note_agent_notice_typed(&f.svc, "brg_other", REPLY_TEST_INSTANCE, t30)
	testing.expect(t, !moved && err.code == .Not_Found)
	_, moved, err = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, "inst_unknown", t30)
	testing.expect(t, !moved && err.code == .Not_Found)
	_, moved, err = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, "", t30)
	testing.expect(t, !moved && err.code == .Validation_Failed)
	testing.expect_value(t, stored(&f), "")

	// The owning bridge's report lands, on the instance's conversation.
	c, moved2, err2 := note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, t30)
	testing.expect(t, moved2 && err2.code == .None)
	testing.expect_value(t, c.conversation_id, REPLY_TEST_CONVERSATION)
	testing.expect_value(t, stored(&f), "2026-01-01T00:00:30Z")
	// Idempotent; an older report never moves it back.
	_, moved, _ = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, t30)
	testing.expect(t, !moved, "same time is a no-op")
	_, moved, _ = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, t30 - 20_000)
	testing.expect(t, !moved, "older is ignored")
	testing.expect_value(t, stored(&f), "2026-01-01T00:00:30Z")
	// A bridge clock ahead of the Hub is clamped to the Hub's now.
	_, moved, _ = note_agent_notice_typed(&f.svc, AN_TEST_BRIDGE, REPLY_TEST_INSTANCE, t30 + 3_600_000)
	testing.expect(t, moved)
	testing.expect_value(t, stored(&f), AN_TEST_NOW)
}
