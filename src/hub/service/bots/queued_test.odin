package bots

import "core:strings"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"

Queued_Test_State :: struct {
	t: ^testing.T,
	f: ^Pairing_Fixture,
	calls: int,
	failure: channel.Channel_Error_Kind,
	emoji: string,
	batch: []channel.Inbound,
}

queued_test_react :: proc(ctx: rawptr, chat, message, emoji: string) -> channel.Channel_Error {
	s := (^Queued_Test_State)(ctx)
	feedback_assert_committed(&Feedback_Test_State{t = s.t, conn = &s.f.conn})
	unlocked := sync.mutex_try_lock(&s.f.service.mutex)
	testing.expect(s.t, unlocked, "provider call must run outside Bots_Service.mutex")
	if unlocked do sync.mutex_unlock(&s.f.service.mutex)
	testing.expect_value(s.t, chat, "111")
	testing.expect_value(s.t, message, "mid")
	s.calls += 1
	s.emoji = emoji
	return {kind = s.failure}
}

queued_test_poll :: proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> ([]channel.Inbound, string, channel.Channel_Error) {
	s := (^Queued_Test_State)(ctx)
	if s.batch != nil do return placement_clone(s.batch), strings.clone("2", allocator), {}
	return placement_clone([]channel.Inbound{{update_key = "queued-event", external_chat_id = "111",
		external_user_id = "222", external_message_id = "mid", kind = .Text, chat_is_private = true, text = "hello"}}),
		strings.clone("2", allocator), {}
}

@(test)
test_queued_reaction_intake_busy_idle_failure_duplicate :: proc(t: ^testing.T) {
	// Exercise the real poll and push intake paths, including their inserted-id
	// filters, in both busy states and every stop-on-failure category.
	for whatsapp in ([]bool{false, true}) {
		for scenario in 0..<8 {
			f := wa_pairing_fixture(t) if whatsapp else pairing_fixture(t)
			if whatsapp {wa_test_bind(t, f)} else {pairing_test_bound(t, f)}
			state := Queued_Test_State{t = t, f = f}
			f.adapter.ctx, f.adapter.react = &state, queued_test_react
			f.adapter.identity, f.adapter.poll = runtime_test_identity, queued_test_poll
			if scenario == 3 do f.adapter.react = nil
			switch scenario {
			case 4: state.failure = .Transient
			case 5: state.failure = .Aborted
			case 6: state.failure = .Rate_Limited
			case 7: state.failure = .Invalid_Request
			}
			if scenario != 0 {
				delivery_state := domain.Bot_Delivery_State.Dispatched
				if scenario == 2 do delivery_state = .Waiting
				testing.expect_value(t, iface.delivery_insert(&f.repo, {delivery_id = "bdl_busy", bot_id = "bot_a",
					owner_user_id = "alice", through_message_id = "earlier", state = delivery_state,
					round = 1, created_at = pairing_test_clock(nil), updated_at = pairing_test_clock(nil)}).code, domain.Error_Code.None)
			}
			rt := Bots_Runtime{service = &f.service}
			if whatsapp {
				push_test_enqueue(t, f)
				_, delay := bots_push_intake_iteration(&rt)
				testing.expect_value(t, delay, time.Duration(0))
				_, _ = bots_push_intake_iteration(&rt)
			} else {
				backoff := time.Second
				for _ in 0..<2 {
					delay, aborted := bots_poller_iteration(&rt, &backoff)
					testing.expect(t, delay == 0 && !aborted)
				}
			}
			expected := 0 if scenario == 0 || scenario == 3 else 1
			testing.expect_value(t, state.calls, expected)
			if expected > 0 do testing.expect_value(t, state.emoji, "⏳" if whatsapp else "✍")
			messages, err := iface.messages_history(&f.repo, "bot_a", -1)
			testing.expect(t, err.code == .None && len(messages) == 1, "intake succeeds even when reactions fail")
			for &m in messages do domain.channel_message_destroy(&m)
			delete(messages)
			if scenario == 1 || scenario == 2 {
				b, found, e := iface.binding_get_active_by_owner(&f.repo, "alice", f.adapter.provider)
				testing.expect(t, found && e.code == .None)
				rows, _, read_err := bots_channel_read(&f.service, "bot_a", b, 50)
				testing.expect_value(t, read_err.code, domain.Error_Code.None)
				testing.expect_value(t, state.calls, 2)
				testing.expect_value(t, state.emoji, BOT_READ_REACTION)
				for &m in rows do domain.channel_message_destroy(&m)
				delete(rows)
				domain.channel_binding_destroy(&b)
			}
			pairing_fixture_destroy(f)
		}
	}
}



@(test)
test_queued_reaction_batch_failure_and_gating :: proc(t: ^testing.T) {
	for scenario in 0..<9 {
		f := pairing_fixture(t)
		pairing_test_bound(t, f)
		batch := [2]channel.Inbound{
			{update_key = "one", external_chat_id = "111", external_user_id = "222", external_message_id = "mid", kind = .Text, chat_is_private = true, text = "one"},
			{update_key = "two", external_chat_id = "111", external_user_id = "222", external_message_id = "mid", kind = .Text, chat_is_private = true, text = "two"},
		}
		state := Queued_Test_State{t = t, f = f, batch = batch[:]}
		f.adapter.ctx, f.adapter.react = &state, queued_test_react
		f.adapter.identity, f.adapter.poll, f.adapter.send_text = runtime_test_identity, queued_test_poll, poller_test_notice
		delivery_state := domain.Bot_Delivery_State.Dispatched
		switch scenario {
		case 1: state.failure = .Transient
		case 2: state.failure = .Invalid_Request
		case 3: delivery_state = .Pending
		case 4:
			_, e := iface.experiment_set(&f.experiments, {owner_user_id = "alice", key = "bots", enabled = false, updated_at = "now"})
			testing.expect_value(t, e.code, domain.Error_Code.None)
		case 5: for &u in batch do u.external_user_id = "stranger"
		case 6: for &u in batch do u.kind = .Unsupported
		case 7: for &u in batch do u.chat_is_private = false
		case 8:
			b, _, _ := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram")
			testing.expect_value(t, iface.binding_revoke(&f.repo, b.binding_id, pairing_test_clock(nil)).code, domain.Error_Code.None)
			domain.channel_binding_destroy(&b)
		}
		testing.expect_value(t, iface.delivery_insert(&f.repo, {delivery_id = "bdl_busy", bot_id = "bot_a",
			owner_user_id = "alice", through_message_id = "earlier", state = delivery_state,
			round = 1, created_at = pairing_test_clock(nil), updated_at = pairing_test_clock(nil)}).code, domain.Error_Code.None)
		rt := Bots_Runtime{service = &f.service}
		backoff := time.Second
		for _ in 0..<2 {
			delay, aborted := bots_poller_iteration(&rt, &backoff)
			testing.expect(t, delay == 0 && !aborted)
		}
		expected := 2 if scenario == 0 || scenario == 2 else (1 if scenario == 1 else 0)
		testing.expect_value(t, state.calls, expected)
		pairing_fixture_destroy(f)
	}
}

// An invalid provider reaction is reported through the production diagnostic
// writer without aborting feedback for the next queued message.
@(test)
test_queued_provider_reaction_invalid_logged_nonfatal :: proc(t: ^testing.T) {
	testing.expect_value(t, bots_queued_reaction("telegram"), "✍")
	testing.expect_value(t, bots_queued_reaction("whatsapp"), "⏳")
	testing.expect_value(t, bots_queued_reaction("web"), "")
	f := pairing_fixture(t)
	defer pairing_fixture_destroy(f)
	pairing_test_bound(t, f)
	state := Queued_Test_State{t = t, f = f, failure = .Invalid_Request}
	f.adapter.ctx, f.adapter.react = &state, queued_invalid_test_react
	binding, found, err := iface.binding_get_active_by_owner(&f.repo, "alice", "telegram")
	defer domain.channel_binding_destroy(&binding)
	if !testing.expect(t, found && err.code == .None) do return
	reader, writer, pipe_err := os.pipe()
	if !testing.expect(t, pipe_err == nil) do return
	defer os.close(reader)
	fresh := [2]domain.Channel_Message{
		{binding_id = binding.binding_id, external_message_id = "mid"},
		{binding_id = binding.binding_id, external_message_id = "mid"},
	}
	bots_queued_feedback(&f.service, fresh[:], writer)
	os.close(writer)
	buffer: [2048]byte
	n, read_err := os.read(reader, buffer[:])
	testing.expect(t, read_err == nil)
	output := string(buffer[:n])
	testing.expect_value(t, state.calls, 2)
	testing.expect_value(t, state.emoji, "✍")
	testing.expect_value(t, strings.count(output, "provider=telegram operation=queued_reaction kind=Invalid_Request http_status=400 provider_code=400 description=Bad Request: REACTION_INVALID"), 2)
	testing.expect(t, !strings.contains(output, "111") && !strings.contains(output, "mid"))
}

queued_invalid_test_react :: proc(ctx: rawptr, chat, message, emoji: string) -> channel.Channel_Error {
	_ = queued_test_react(ctx, chat, message, emoji)
	return {kind = .Invalid_Request, http_status = 400, provider_code = 400, message = "Bad Request: REACTION_INVALID"}
}
