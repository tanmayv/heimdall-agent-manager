package domain

import "core:testing"

@(test)
test_bot_enum_text_roundtrip :: proc(t: ^testing.T) {
	{
		testing.expect_value(t, bot_placement_tier_text(Bot_Placement_Tier.Preferred), "preferred")
		testing.expect_value(t, bot_placement_tier_text(Bot_Placement_Tier.Allowed), "allowed")
		for value in Bot_Placement_Tier {
			parsed, ok := bot_placement_tier_from_text(bot_placement_tier_text(value))
			testing.expect(t, ok)
			testing.expect_value(t, parsed, value)
		}
		_, ok := bot_placement_tier_from_text("invalid")
		testing.expect(t, !ok)
	}
	{
		testing.expect_value(t, channel_binding_state_text(Channel_Binding_State.Active), "active")
		testing.expect_value(t, channel_binding_state_text(Channel_Binding_State.Revoked), "revoked")
		for value in Channel_Binding_State {
			parsed, ok := channel_binding_state_from_text(channel_binding_state_text(value))
			testing.expect(t, ok)
			testing.expect_value(t, parsed, value)
		}
		_, ok := channel_binding_state_from_text("invalid")
		testing.expect(t, !ok)
	}
	{
		testing.expect_value(t, channel_direction_text(Channel_Direction.Inbound), "inbound")
		testing.expect_value(t, channel_direction_text(Channel_Direction.Outbound), "outbound")
		for value in Channel_Direction {
			parsed, ok := channel_direction_from_text(channel_direction_text(value))
			testing.expect(t, ok)
			testing.expect_value(t, parsed, value)
		}
		_, ok := channel_direction_from_text("invalid")
		testing.expect(t, !ok)
	}
	{
		testing.expect_value(t, channel_send_state_text(Channel_Send_State.None), "")
		testing.expect_value(t, channel_send_state_text(Channel_Send_State.Pending), "pending")
		testing.expect_value(t, channel_send_state_text(Channel_Send_State.Sent), "sent")
		testing.expect_value(t, channel_send_state_text(Channel_Send_State.Failed), "failed")
		for value in Channel_Send_State {
			parsed, ok := channel_send_state_from_text(channel_send_state_text(value))
			testing.expect(t, ok)
			testing.expect_value(t, parsed, value)
		}
		_, ok := channel_send_state_from_text("invalid")
		testing.expect(t, !ok)
	}
	{
		testing.expect_value(t, bot_delivery_state_text(Bot_Delivery_State.Pending), "pending")
		testing.expect_value(t, bot_delivery_state_text(Bot_Delivery_State.Dispatched), "dispatched")
		testing.expect_value(t, bot_delivery_state_text(Bot_Delivery_State.Waiting), "waiting")
		testing.expect_value(t, bot_delivery_state_text(Bot_Delivery_State.Acted), "acted")
		testing.expect_value(t, bot_delivery_state_text(Bot_Delivery_State.Abandoned), "abandoned")
		for value in Bot_Delivery_State {
			parsed, ok := bot_delivery_state_from_text(bot_delivery_state_text(value))
			testing.expect(t, ok)
			testing.expect_value(t, parsed, value)
		}
		_, ok := bot_delivery_state_from_text("invalid")
		testing.expect(t, !ok)
	}
	{
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Relocating), "relocating")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Sent), "sent")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Accepted), "accepted")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Acted), "acted")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Exhausted), "exhausted")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Busy), "busy")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Disconnected), "disconnected")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Deadline), "deadline")
		testing.expect_value(t, bot_attempt_state_text(Bot_Attempt_State.Cancelled), "cancelled")
		for value in Bot_Attempt_State {
			parsed, ok := bot_attempt_state_from_text(bot_attempt_state_text(value))
			testing.expect(t, ok)
			testing.expect_value(t, parsed, value)
		}
		_, ok := bot_attempt_state_from_text("invalid")
		testing.expect(t, !ok)
	}
}

@(test)
test_bot_attempt_state_open :: proc(t: ^testing.T) {
	for value in Bot_Attempt_State do testing.expect_value(t, bot_attempt_state_open(value), value == .Relocating || value == .Sent || value == .Accepted)
	for value in Bot_Delivery_State do testing.expect_value(t, bot_delivery_state_open(value), value == .Pending || value == .Dispatched || value == .Waiting)
}

@(test)
test_channel_push_kind_text_roundtrip :: proc(t: ^testing.T) {
	texts := [6]string{"text", "start", "disconnect", "unsupported", "delivery_failed", "media"}
	for value in Channel_Push_Kind {
		text := channel_push_kind_text(value)
		testing.expect_value(t, text, texts[int(value)])
		parsed, ok := channel_push_kind_from_text(text)
		testing.expect(t, ok)
		testing.expect_value(t, parsed, value)
	}
	_, ok := channel_push_kind_from_text("bogus")
	testing.expect(t, !ok)
}

@(test)
test_channel_send_state_held_roundtrip :: proc(t: ^testing.T) {
	testing.expect_value(t, channel_send_state_text(.Held), "held")
	value, ok := channel_send_state_from_text("held")
	testing.expect(t, ok)
	testing.expect_value(t, value, Channel_Send_State.Held)
}

@(test)
test_channel_media_kind_text_roundtrip :: proc(t: ^testing.T) {
	texts := [?]string{"", "image", "document", "voice", "audio"}
	for value in Channel_Media_Kind {
		text := channel_media_kind_text(value)
		testing.expect_value(t, text, texts[int(value)])
		parsed, ok := channel_media_kind_from_text(text)
		testing.expect(t, ok)
		testing.expect_value(t, parsed, value)
	}
	_, ok := channel_media_kind_from_text("invalid")
	testing.expect(t, !ok)
}

@(test)
test_channel_attachment_state_text_roundtrip :: proc(t: ^testing.T) {
	texts := [?]string{"pending", "stored", "too_large", "unavailable", "native", "link"}
	for value in Channel_Attachment_State {
		text := channel_attachment_state_text(value)
		testing.expect_value(t, text, texts[int(value)])
		parsed, ok := channel_attachment_state_from_text(text)
		testing.expect(t, ok)
		testing.expect_value(t, parsed, value)
	}
	_, ok := channel_attachment_state_from_text("invalid")
	testing.expect(t, !ok)
}
