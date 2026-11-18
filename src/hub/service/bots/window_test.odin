package bots

import "core:testing"
import domain "odin_test:hub/domain"
import channel "odin_test:hub/service/channel"

@(test)
test_bots_window_closed_margin_and_invalid_timestamp :: proc(t: ^testing.T) {
	a := channel.Channel_Adapter{reply_window_ms = 86_400_000}
	b := domain.Channel_Binding{last_inbound_at = "2026-11-17T12:00:00Z"}
	last := bots_stamp_ms(b.last_inbound_at)
	testing.expect(t, !bots_window_closed(&a, b, last + 85_799_999))
	testing.expect(t, bots_window_closed(&a, b, last + 85_800_000))
	testing.expect(t, bots_window_closed(&a, {}, last))
	a.reply_window_ms = 0
	testing.expect(t, !bots_window_closed(&a, {}, last))
	testing.expect(t, !bots_window_closed(nil, {}, last))
}
