package bots

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"

Canonical_Push_Admission :: struct {legacy: []channel.Inbound, inserted: int}

// Called only after signature and account verification. Opted-in bytes may
// flow to the scoped converter, but never to the legacy push staging table.
// A failed bridge exchange withholds acknowledgement for the entire batch.
admit_canonical_whatsapp_push :: proc(s: ^Bots_Service,batch: []channel.Inbound,now: string) -> (Canonical_Push_Admission,domain.Domain_Error) {
	context.allocator=context.temp_allocator
	provider := domain.CHANNEL_PROVIDER_WHATSAPP
	legacy := make([dynamic]channel.Inbound,0,len(batch),context.temp_allocator)
	inserted := 0
	for event in batch {
		event := event
		if event.kind==.Delivery_Failed {
			handled, err := bots_canonical_whatsapp_failure(s,event)
			if err.code!=.None do return {},err
			if !handled do append(&legacy,event)
			continue
		}
		if event.kind==.Start && event.text!="" {
			p, found, err := iface.pairing_get(s.repo,bots_pairing_hash(event.text))
			if err.code!=.None do return {},err
			if found && p.provider==provider {
				activity, activated, activity_err := iface.bot_web_activation_get(s.repo,p.owner_user_id)
				if activity_err.code!=.None do return {},activity_err
				if activated {
					if activity.enabled && canonical_channel_enabled(s,provider,p.owner_user_id) &&
					   p.consumed_at=="" && p.expires_at>now {
						if pair_err := bots_pairing_start(s,s.whatsapp,event,now); pair_err.code!=.None do return {},pair_err
					}
					// Never spool a fresh pairing token or consume an old one.
					continue
				}
			} else {
				// The legacy worker can keep its invalid-code notice without
				// staging an arbitrary body from an unbound sender.
				event.text="invalid"
			}
		}
		if event.update_key!="" {
			used, err := iface.bot_channel_conversion_origin_exists(s.repo,"",event.update_key,"")
			if err.code!=.None do return {},err
			if used do continue
		}
		binding, bound, bind_err := bots_find_binding(s,provider,event.external_chat_id,event.external_user_id)
		if bind_err.code!=.None do return {},bind_err
		if bound && binding.external_user_id!=event.external_user_id {
			// An address owned by a different stable identity never
			// discloses this input to either owner, including via the spool.
			continue
		}
		if !bound {
			// Unsupported traffic cannot be delivered without a verified
			// binding. Preserve legacy not-connected handling but drop any
			// ordinary payload before putting a record in the old spool.
			safe := event
			if safe.kind!=.Start {safe.text=""; safe.media={}; safe.sender_display=""}
			append(&legacy,safe)
			continue
		}
		state, active, state_err := iface.bot_web_activation_get(s.repo,binding.owner_user_id)
		if state_err.code!=.None do return {},state_err
		if !active {append(&legacy,event); continue}
		if !state.enabled || !canonical_channel_enabled(s,provider,binding.owner_user_id) do continue
		entitled, entitlement_err := bots_channel_entitled(s,provider,binding.owner_user_id)
		if entitlement_err.code!=.None do return {},entitlement_err
		if !entitled {
			if err := bots_disconnect_canonical_owner(s,binding.owner_user_id,provider); err.code!=.None && err.code!=.Not_Found do return {},err
			continue
		}
		switch event.kind {
		case .Text,.Media:
			result, err := accept_canonical_channel_text(s,s.canonical_content,provider,event)
			if result.disposition==.Retry do return {},err
			if result.message_id!="" do inserted += 1
		case .Disconnect:
			if _, err := bots_disconnect_canonical_chat(s,provider,event); err.code!=.None do return {},err
		case .Start,.Unsupported,.Delivery_Failed:
			// Position- and window-sensitive side effects are not legacy work.
		}
	}
	return {legacy[:],inserted},{}
}
