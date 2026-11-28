package bots

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import platform "odin_test:hub/platform"

// The existing poller owns the only cursor. A canonical failure withholds the
// whole batch, including legacy rows. Previously committed canonical events
// are receipts on retry and do not wake the runtime a second time.
bots_telegram_canonical_batch :: proc(s: ^Bots_Service, batch: []channel.Inbound, now: string) -> ([]channel.Inbound,domain.Domain_Error) {
	context.allocator = context.temp_allocator
	legacy := make([dynamic]channel.Inbound,context.temp_allocator)
	for update in batch {
		if update.chat_is_private && update.kind==.Start && update.text!="" {
			p, found, err := iface.pairing_get(s.repo,bots_pairing_hash(update.text))
			defer domain.channel_pairing_destroy(&p)
			if err.code!=.None do return nil,err
			if found && p.provider==domain.CHANNEL_PROVIDER_TELEGRAM {
				activation, active, state_err := iface.bot_web_activation_get(s.repo,p.owner_user_id)
				defer domain.bot_web_activation_destroy(&activation)
				if state_err.code!=.None do return nil,state_err
				if active {
					if activation.enabled && p.consumed_at=="" && p.expires_at>now {
						if pair_err := bots_pairing_start(s,s.adapter,update,now); pair_err.code!=.None do return nil,pair_err
					}
					continue
				}
			}
		}
		if update.chat_is_private && update.kind==.Disconnect {
			handled, err := bots_disconnect_canonical_chat(s,domain.CHANNEL_PROVIDER_TELEGRAM,update)
			if err.code!=.None do return nil,err
			if handled do continue
		}
		disposition, err := accept_canonical_channel_text(s,s.canonical_content,domain.CHANNEL_PROVIDER_TELEGRAM,update)
		defer delete(disposition.message_id)
		switch disposition.disposition {
		case .Handled: continue
		case .Retry:
			if err.code==.None do err=bots_detail_error(.Internal_Error,"channel_input_not_accepted")
			return nil,err
		case .Legacy: append(&legacy,update)
		}
	}
	return legacy[:],{}
}

bots_disconnect_canonical_chat :: proc(s: ^Bots_Service, provider: string, event: channel.Inbound) -> (bool,domain.Domain_Error) {
	binding, found, err := bots_find_binding(s,provider,event.external_chat_id,event.external_user_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code!=.None || !found do return false,err
	_, fresh, grant_err := iface.bot_channel_conversion_binding_get(s.repo,binding.binding_id)
	if grant_err.code!=.None || !fresh do return false,grant_err
	if !canonical_channel_sender_matches(provider,binding.external_chat_id,binding.external_user_id,event) do return true,{}
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	// Revoke the exact original ID. A concurrent re-pair is never revoked.
	if err=iface.binding_revoke(s.repo,binding.binding_id,platform.clock_now(s.clock)); err.code!=.None do return true,err
	bots_publish_changed(s,binding.owner_user_id,binding.bot_id)
	return true,{}
}

// Fixed pairing copy is not a reply to authored content. The legacy sender
// refuses opted-in owners, so send only this bounded notice on the verified
// chat after the activation transaction commits.
bots_canonical_pairing_notice :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, update: channel.Inbound, owner, reply: string) {
	if a.send_text==nil || reply!=bots_channel_copy(a.provider).paired do return
	if !admit_canonical_pairing_notice(s,a.provider,update,owner) do return
	id, _ := a.send_text(a.ctx,update.external_chat_id,reply)
	delete(id)
}

@(private="file")
admit_canonical_pairing_notice :: proc(s: ^Bots_Service, provider: string, update: channel.Inbound, owner: string) -> bool {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	binding, found, err := bots_find_binding(s,provider,update.external_chat_id,update.external_user_id)
	defer domain.channel_binding_destroy(&binding)
	if err.code!=.None || !found || binding.owner_user_id!=owner || binding.external_user_id!=update.external_user_id do return false
	grant, have, grant_err := iface.bot_channel_conversion_binding_get(s.repo,binding.binding_id)
	if grant_err.code!=.None || !have do return false
	generation, mode_err := pairing_activation_generation(s,owner,provider)
	entitled, entitlement_err := bots_channel_entitled(s,provider,owner)
	return mode_err.code==.None && generation>0 && generation==grant.activation_generation && bots_gate_on(s.experiments,owner) &&
		entitled && entitlement_err.code==.None && !bots_window_closed(bots_adapter(s,provider),binding,bots_now_ms(s))
}

bots_disconnect_canonical_owner :: proc(s: ^Bots_Service, owner, provider: string) -> domain.Domain_Error {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	b, found, err := iface.binding_get_active_by_owner(s.repo,owner,provider)
	defer domain.channel_binding_destroy(&b)
	if err.code!=.None do return err
	if !found do return bots_detail_error(.Not_Found,"binding_not_found")
	_, fresh, grant_err := iface.bot_channel_conversion_binding_get(s.repo,b.binding_id)
	if grant_err.code!=.None do return grant_err
	if !fresh do return bots_detail_error(.Not_Found,"binding_not_found")
	if err=iface.binding_revoke(s.repo,b.binding_id,platform.clock_now(s.clock)); err.code!=.None do return err
	bots_publish_changed(s,owner,b.bot_id)
	return {}
}
