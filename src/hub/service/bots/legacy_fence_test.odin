
package bots

import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import channel "odin_test:hub/service/channel"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

legacy_fence_test_activate :: proc(f: ^Pairing_Fixture) -> domain.Domain_Error {
	sync.mutex_lock(&f.service.mutex)
	defer sync.mutex_unlock(&f.service.mutex)
	sync.mutex_lock(&f.service.legacy_fence_mutex)
	defer sync.mutex_unlock(&f.service.legacy_fence_mutex)
	return iface.bot_web_activation_insert(&f.repo, {
		owner_user_id = "alice", bot_id = "bot_a",
		agent_instance_id = "fresh_instance", conversation_id = "fresh_conversation",
		enabled = true, generation = 1,
	})
}

@(test)
test_legacy_fence_ignores_old_worker_after_flag_cycle :: proc(t: ^testing.T) {
	f := delivery_fixture(t)
	defer delivery_destroy(f)
	delivery_seed(t, f, .Sent)
	before := len(f.frames)

	activation_err := legacy_fence_test_activate(f.pair)
	if !testing.expect_value(t, activation_err.code, domain.Error_Code.None) do return
	for enabled, i in ([]bool{false, true}) {
		changed, err := iface.bot_web_activation_set_enabled(&f.pair.repo, "alice", enabled, i64(i + 1))
		testing.expect(t, changed && err.code == .None)
		old := delivery_attempt_test(f)
		defer domain.bot_delivery_attempt_destroy(&old)
		delivery_report_test(t, f, "acted")
		bots_on_bridge_hello(&f.pair.service, "b1")
		bots_supervisor_tick(&f.pair.service)
		testing.expect_value(t, len(f.frames), before)
		bots_on_command_result(&f.pair.service, "b1", strings.concatenate({"cmd_bot_", old.attempt_id}, context.temp_allocator), "accepted", "")
		current := delivery_attempt_test(f)
		defer domain.bot_delivery_attempt_destroy(&current)
		testing.expect_value(t, current.attempt_id, old.attempt_id)
		testing.expect_value(t, current.state, domain.Bot_Attempt_State.Sent)
		testing.expect_value(t, current.report_seq, old.report_seq)
		legacy_msg, _, rejected := bots_web_send(&f.pair.service, "alice", "late", "legacy-request")
		defer domain.channel_message_destroy(&legacy_msg)
		testing.expect_value(t, rejected.code, domain.Error_Code.Conflict)
		testing.expect(t, strings.contains(rejected.details_json, "bot_generation_inactive"))
	}
}

@(test)
test_legacy_fence_leaves_held_reply_and_drops_late_mobile_intake :: proc(t: ^testing.T) {
	s: Window_Test_State
	window_test_setup(t, &s)
	defer window_test_destroy(&s)
	window_test_close(&s)
	b := window_test_binding(&s)
	defer domain.channel_binding_destroy(&b)
	ids, held, send_err := channel_send(&s.f.service, b, "old held reply", true)
	defer window_test_ids_free(ids)
	if !testing.expect(t, held && send_err.code == .None && len(ids) == 1) do return
	push_test_enqueue(t, s.f)
	before := len(s.sent)
	activation_err := legacy_fence_test_activate(s.f)
	if !testing.expect_value(t, activation_err.code, domain.Error_Code.None) do return
	s.f.adapter.push_parse = push_test_parse
	result, events, inserted := bots_push_receive(&s.f.service, "whatsapp", "", "")
	testing.expect(t, result == .Stored && events == 1 && inserted == 0)
	rt := Bots_Runtime{service = &s.f.service}
	_, delay := bots_push_intake_iteration(&rt)
	testing.expect_value(t, int(delay), 0)
	testing.expect_value(t, len(s.sent), before)
	rows, err := iface.messages_history(&s.f.repo, "bot_a", -1)
	defer {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}
	if !testing.expect(t, err.code == .None && len(rows) == 1) do return
	testing.expect_value(t, rows[0].message_id, ids[0])
	testing.expect_value(t, rows[0].body, "old held reply")
	testing.expect_value(t, rows[0].send_state, domain.Channel_Send_State.Held)
}

@(test)
test_legacy_fence_allows_outstanding_provider_result_but_not_next_chunk :: proc(t: ^testing.T) {
	f := pairing_fixture(t)
	defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	b, found, bind_err := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram")
	defer domain.channel_binding_destroy(&b)
	if !testing.expect(t, found && bind_err.code == .None) do return
	st := Legacy_Fence_Send_State{fixture = f}
	f.adapter.ctx = &st
	f.adapter.send_text = legacy_fence_activate_after_send
	ids, _, err := channel_send(&f.service, b, strings.repeat("x", 4500, context.temp_allocator), true)
	defer window_test_ids_free(ids)
	testing.expect_value(t, st.calls, 1)
	testing.expect_value(t, st.activation_err.code, domain.Error_Code.None)
	if !testing.expect(t, len(ids) == 2 && err.code != .None) do return
	rows, lookup_err := iface.messages_by_ids(&f.repo, "alice", "bot_a", ids)
	defer {for &row in rows do domain.channel_message_destroy(&row); delete(rows)}
	if !testing.expect(t, len(rows) == 2 && lookup_err.code == .None) do return
	first, second := rows[0], rows[1]
	if first.message_id != ids[0] do first, second = second, first
	testing.expect_value(t, first.send_state, domain.Channel_Send_State.Sent)
	testing.expect_value(t, first.external_message_id, "accepted_on_old_side")
	testing.expect_value(t, second.send_state, domain.Channel_Send_State.Failed)
	testing.expect_value(t, second.external_message_id, "")
}

Legacy_Fence_Send_State :: struct {
	fixture: ^Pairing_Fixture,
	calls: int,
	activation_err: domain.Domain_Error,
}

legacy_fence_activate_after_send :: proc(ctx: rawptr, _, _: string) -> (string, channel.Channel_Error) {
	state := (^Legacy_Fence_Send_State)(ctx)
	state.calls += 1
	state.activation_err = legacy_fence_test_activate(state.fixture)
	return strings.clone("accepted_on_old_side"), {}
}

@(test)
test_legacy_fence_telegram_batch_in_flight_at_activation :: proc(t: ^testing.T) {
	f := pairing_fixture(t)
	defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	pairing_test_code(t, f, "old_pairing")
	before := len(f.sent)
	st := Legacy_Fence_Send_State{fixture = f}
	f.adapter.ctx = &st
	f.adapter.poll = legacy_fence_activate_after_poll
	f.adapter.send_text = legacy_fence_poll_notice
	rt := Bots_Runtime{service = &f.service}
	backoff := time.Second
	_, _ = bots_poller_iteration(&rt, &backoff)
	testing.expect_value(t, st.activation_err.code, domain.Error_Code.None)
	messages, err := iface.messages_history(&f.repo, "bot_a", -1)
	defer {for &message in messages do domain.channel_message_destroy(&message); delete(messages)}
	testing.expect(t, err.code == .None && len(messages) == 0)
	cursor, found, cursor_err := iface.cursor_get(&f.repo, "telegram")
	defer delete(cursor)
	testing.expect(t, found && cursor_err.code == .None)
	testing.expect_value(t, cursor, "93")
	pairing_test_start(t, f, "old_pairing", "333")
	testing.expect_value(t, len(f.sent), before)
	other, other_found, other_err := iface.binding_get_active_by_chat(&f.repo, "telegram", "333")
	defer domain.channel_binding_destroy(&other)
	testing.expect(t, !other_found && other_err.code == .None)
}

legacy_fence_activate_after_poll :: proc(ctx: rawptr, _: string, _: ^bool, allocator := context.allocator) -> ([]channel.Inbound, string, channel.Channel_Error) {
	state := (^Legacy_Fence_Send_State)(ctx)
	state.activation_err = legacy_fence_test_activate(state.fixture)
	batch := make([]channel.Inbound, 1, allocator)
	batch[0] = {
		update_key = strings.clone("telegram:1:92", allocator),
		external_chat_id = strings.clone("111", allocator),
		external_user_id = strings.clone("222", allocator),
		external_message_id = strings.clone("92", allocator),
		chat_is_private = true, kind = .Text,
		text = strings.clone("late legacy mobile input", allocator),
	}
	return batch, strings.clone("93", allocator), {}
}

legacy_fence_poll_notice :: proc(ctx: rawptr, chat, text: string) -> (string, channel.Channel_Error) {
	return pairing_test_send((^Legacy_Fence_Send_State)(ctx).fixture, chat, text)
}
