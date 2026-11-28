package bots

import "core:fmt"
import "core:log"
import "core:sync"
import iface "odin_test:hub/repository/iface"
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

// Provider calls happen under the dedicated re-engagement lock, never s.mutex.
// Call only outside a UoW: this lock precedes the binding write gate, and
// provider delivery (including its callback) belongs after transaction commit.
bots_reengage :: proc(s: ^Bots_Service, binding_id: string) {
	sync.mutex_lock(&s.reengage_mutex); defer sync.mutex_unlock(&s.reengage_mutex)
	binding, found, err := iface.binding_get(s.repo, binding_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None || !found || binding.state != .Active || binding.reengage_sent_at != "" do return
	a := bots_adapter(s, binding.provider)
	if a == nil || a.send_reengage == nil || !bots_gate_on(s.experiments, binding.owner_user_id) do return
	if !bots_legacy_provider_admit(s, binding.owner_user_id) do return
	id, result := a.send_reengage(a.ctx, binding.external_chat_id)
	delete(id)
	sent, failure := "", ""
	if result.kind == .None {
		sent = platform.clock_now(s.clock)
		log.info(fmt.tprintf("bots: reengage sent binding=%s", binding_id))
	} else {
		failure = "send_failed"
		if result.kind == .Template_Unavailable do failure = "template_unavailable"
		log.warn(fmt.tprintf("bots: reengage failed binding=%s kind=%v code=%d", binding_id, result.kind, result.provider_code))
	}
	_ = iface.binding_set_reengage(s.repo, binding_id, sent, failure)
	bots_publish_changed(s, binding.owner_user_id, binding.bot_id)
}

bots_release_held :: proc(s: ^Bots_Service, binding_id: string) {
	binding, found, err := iface.binding_get(s.repo, binding_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None || !found || binding.state != .Active || !bots_gate_on(s.experiments, binding.owner_user_id) do return
	a := bots_adapter(s, binding.provider)
	if a == nil || bots_window_closed(a, binding, bots_now_ms(s)) do return
	if bots_legacy_guard(s, binding.owner_user_id).code != .None do return
	rows, list_err := iface.messages_held(s.repo, binding_id)
	defer {for &m in rows do domain.channel_message_destroy(&m); delete(rows)}
	if list_err.code != .None do return
	sent, failed := 0, 0
	for row in rows {
		id, result := bots_send_chunk(s, a, binding.external_chat_id, row.body, binding.owner_user_id)
		defer delete(id)
		if result.kind == .Window_Closed || result.kind == .Aborted do break
		if result.kind == .None {
			if e := iface.message_set_send_result(s.repo, row.message_id, .Sent, id, ""); e.code != .None do break
			sent += 1
		} else {
			if e := iface.message_set_send_result(s.repo, row.message_id, .Failed, "", fmt.tprintf("%v", result.kind)); e.code != .None do break
			failed += 1
		}
	}
	log.info(fmt.tprintf("bots: held released binding=%s sent=%d failed=%d kept=%d", binding_id, sent, failed, len(rows)-sent-failed))
	if sent + failed > 0 do bots_publish_changed(s, binding.owner_user_id, binding.bot_id)
}

bots_on_delivery_failed :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, update: channel.Inbound) {
	if a == nil do return
	binding, found, err := bots_find_binding(s, a.provider, update.external_chat_id, "")
	defer domain.channel_binding_destroy(&binding)
	if err.code != .None || !found do return
	msg, exists, get_err := iface.message_get_outbound_by_external(s.repo, binding.binding_id, update.external_message_id)
	defer domain.channel_message_destroy(&msg)
	if get_err.code != .None || !exists || msg.send_state != .Sent do return
	kind: channel.Channel_Error_Kind = .Invalid_Request
	if a.failure_kind != nil do kind = a.failure_kind(update.provider_code)
	if kind == .Window_Closed {
		if e := iface.message_set_send_result(s.repo, msg.message_id, .Held, "", ""); e.code != .None do return
		log.info(fmt.tprintf("bots: reply held binding=%s chunks=1", binding.binding_id))
		bots_reengage(s, binding.binding_id)
	} else {
		_ = iface.message_set_send_result(s.repo, msg.message_id, .Failed, msg.external_message_id, fmt.tprintf("%v", kind))
	}
}
