package bots

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"

bots_canonical_whatsapp_failure :: proc(s: ^Bots_Service,event: channel.Inbound) -> (bool,domain.Domain_Error) {
	if s.repo.canonical_whatsapp_receipt_store==nil || event.update_key=="" ||
	   event.external_message_id=="" || event.external_chat_id=="" {
		return false,{}
	}
	return s.repo.canonical_whatsapp_receipt_store(s.repo.ctx,event.update_key,event.external_message_id,
		event.external_chat_id,event.provider_code,platform.clock_now(s.clock))
}

bots_canonical_whatsapp_receipt_tick :: proc(s: ^Bots_Service) {
	if !canonical_channel_enabled(s,domain.CHANNEL_PROVIDER_WHATSAPP) || s.whatsapp==nil ||
	   s.repo.canonical_whatsapp_receipt_pending==nil {
		return
	}
	rows, err := s.repo.canonical_whatsapp_receipt_pending(s.repo.ctx)
	if err.code!=.None do return
	for r in rows {
		if !apply_canonical_whatsapp_receipt(s,r) || s.event_bus==nil || s.canonical_content==nil do continue
		m, found, read_err := iface.content_get_message(s.canonical_content.content,r.reply_message_id)
		if read_err.code==.None && found && string(m.owner_user_id)==r.owner_user_id do publish_canonical_channel_change(s,m,"messages_delivery")
	}
}

@(private="file")
apply_canonical_whatsapp_receipt :: proc(s: ^Bots_Service,r: domain.Bot_Channel_Provider_Receipt) -> bool {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	uow, begun, err := iface.unit_of_work_begin(s.uow_factory)
	if !begun || err.code!=.None do return false
	defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
	repos:=uow.repos
	// A callback may update its original record, but only a currently valid
	// binding may turn a rejected part into a future send.
	_, source_err := read_channel_conversion_source(s,repos,r.owner_user_id,"","","",r.reply_message_id)
	part_status,job_status := "failed","failed"
	if source_err.code==.Forbidden || source_err.code==.Not_Found || !canonical_channel_enabled(s,domain.CHANNEL_PROVIDER_WHATSAPP,r.owner_user_id) {
		job_status="stale"
	} else if source_err.code!=.None {
		return false
	} else if s.whatsapp.failure_kind!=nil && s.whatsapp.failure_kind(r.provider_code)==.Window_Closed {
		part_status,job_status="held","held"
	}
	bot:=&repos.bots
	changed, write_err := bot.canonical_whatsapp_receipt_apply(bot.ctx,r,part_status,job_status)
	if write_err.code!=.None do return false
	committed, commit_err := bots_uow_commit(&uow)
	return committed && commit_err.code==.None && changed
}
