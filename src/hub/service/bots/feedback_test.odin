package bots

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import channel "odin_test:hub/service/channel"

Feedback_Test_State :: struct {
	t: ^testing.T,
	conn: ^sqlite.Conn,
	reactions: int,
	fail_react: bool,
}

feedback_assert_committed :: proc(state: ^Feedback_Test_State) {
	// A fresh SQLite write transaction succeeds only after the read
	// transaction has committed. Provider callbacks must never run inside it.
	if testing.expect(state.t, sqlite.exec(state.conn, "BEGIN IMMEDIATE;")) {
		testing.expect(state.t, sqlite.exec(state.conn, "ROLLBACK;"))
	}
}

feedback_test_react :: proc(ctx: rawptr, chat, message_id, emoji: string) -> channel.Channel_Error {
	state := (^Feedback_Test_State)(ctx)
	feedback_assert_committed(state)
	testing.expect_value(state.t, chat, "111")
	testing.expect_value(state.t, emoji, BOT_READ_REACTION)
	testing.expect(state.t, message_id == "301" || message_id == "302" || message_id == "303")
	state.reactions += 1
	if state.fail_react do return {kind = .Transient}
	return {}
}

feedback_test_insert :: proc(t: ^testing.T, f: ^Delivery_Fixture, id, external_id: string, read_at := "") {
	binding, found, err := iface.binding_get_active_by_owner(&f.pair.repo, "alice", "telegram")
	defer domain.channel_binding_destroy(&binding)
	testing.expect(t, found && err.code == .None)
	rows := []domain.Channel_Message{{message_id = id, binding_id = binding.binding_id, bot_id = "bot_a",
		owner_user_id = "alice", direction = .Inbound, provider_update_key = id, external_message_id = external_id,
		body = "hello", created_at = delivery_clock(f), read_at = read_at}}
	inserted, e := iface.inbound_store_batch(&f.pair.repo, "telegram", rows, id, delivery_clock(f))
	defer {for value in inserted do delete(value); delete(inserted)}
	testing.expect_value(t, e.code, domain.Error_Code.None)
	// inbound_store_batch intentionally normalizes new rows to unread.
	if read_at != "" do testing.expect_value(t, iface.messages_mark_read(&f.pair.repo, "bot_a", {id}, read_at).code, domain.Error_Code.None)
}

feedback_test_read :: proc(t: ^testing.T, f: ^Delivery_Fixture, limit: int) -> int {
	binding, found, err := iface.binding_get_active_by_owner(&f.pair.repo, "alice", "telegram")
	defer domain.channel_binding_destroy(&binding)
	testing.expect(t, found && err.code == .None)
	rows, total, e := bots_channel_read(&f.pair.service, "bot_a", binding, limit)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	testing.expect_value(t, e.code, domain.Error_Code.None)
	testing.expect(t, len(rows) <= limit)
	return total
}

@(test)
test_read_reacts_once_per_newly_read_message :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	state := Feedback_Test_State{t = t, conn = &f.pair.conn}
	f.pair.adapter.ctx = &state
	f.pair.adapter.react = feedback_test_react
	feedback_test_insert(t, f, "chm_a", "301")
	feedback_test_insert(t, f, "chm_b", "302")
	feedback_test_insert(t, f, "chm_c", "303", "earlier")
	testing.expect_value(t, feedback_test_read(t, f, 1), 3)
	testing.expect_value(t, state.reactions, 1)
	testing.expect_value(t, feedback_test_read(t, f, 50), 3)
	testing.expect_value(t, state.reactions, 2)
	testing.expect_value(t, feedback_test_read(t, f, 50), 3)
	testing.expect_value(t, state.reactions, 2)
}

@(test)
test_read_react_failure_does_not_fail_read :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	state := Feedback_Test_State{t = t, conn = &f.pair.conn, fail_react = true}
	f.pair.adapter.ctx = &state
	f.pair.adapter.react = feedback_test_react
	feedback_test_insert(t, f, "chm_a", "301")
	testing.expect_value(t, feedback_test_read(t, f, 50), 1)
	testing.expect_value(t, state.reactions, 1)
	testing.expect_value(t, feedback_test_read(t, f, 50), 1)
	testing.expect_value(t, state.reactions, 1)
	rows, e := iface.messages_history(&f.pair.repo, "bot_a", -1)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	testing.expect_value(t, e.code, domain.Error_Code.None)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 do testing.expect_value(t, rows[0].read_at, delivery_clock(f))
}

@(test)
test_adapter_without_react_is_skipped :: proc(t: ^testing.T) {
	f := delivery_fixture(t); defer delivery_destroy(f)
	state := Feedback_Test_State{t = t, conn = &f.pair.conn}
	f.pair.adapter.ctx = &state
	f.pair.adapter.react = nil
	feedback_test_insert(t, f, "chm_a", "301")
	testing.expect_value(t, feedback_test_read(t, f, 50), 1)
	testing.expect_value(t, state.reactions, 0)
	feedback_test_insert(t, f, "chm_b", "302")
	testing.expect_value(t, feedback_test_read(t, f, 50), 2)
}
