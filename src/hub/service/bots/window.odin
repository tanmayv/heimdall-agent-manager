package bots

import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

BOT_REPLY_WINDOW_MARGIN_MS :: 600_000

bots_window_closed :: proc(a: ^channel.Channel_Adapter, binding: domain.Channel_Binding, now_ms: i64) -> bool {
	if a == nil || a.reply_window_ms <= 0 do return false
	last, ok := platform.rfc3339_to_unix_ms(binding.last_inbound_at)
	if !ok do return true
	return now_ms >= last + a.reply_window_ms - BOT_REPLY_WINDOW_MARGIN_MS
}
