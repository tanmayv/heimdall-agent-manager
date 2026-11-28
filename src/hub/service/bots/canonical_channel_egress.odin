package bots

import "core:sync"
import "core:encoding/json"
import iface "odin_test:hub/repository/iface"
import channelvault "odin_test:lib/channelvault"
import "core:strings"
import domain "odin_test:hub/domain"
import channel "odin_test:hub/service/channel"

// Only the existing supervisor consumes canonical reply jobs. No provider
// call is made by content persistence, and no callback stores plaintext.
bots_canonical_egress_tick :: proc(s: ^Bots_Service, provider: string, now_ms: i64) {
	if !canonical_channel_enabled(s,provider) || s.repo.channel_reply_pending==nil do return
	a := bots_adapter(s,provider)
	if a==nil || a.send_text==nil do return
	// No other sender runs concurrently. An interrupted claim is uncertain
	// even if the bridge has not yet reconnected or the owner opted out.
	if err := s.repo.channel_reply_recover(s.repo.ctx,provider); err.code!=.None do return
	jobs, err := s.repo.channel_reply_pending(s.repo.ctx,provider,now_ms)
	if err.code!=.None do return
	for job in jobs {
		delivery := Canonical_Reply_Delivery{s=s,adapter=a,job=job}
		err := with_bound_channel_reply(s,job.owner_user_id,job.reply_message_id,{ctx=&delivery,accept_prepared=send_canonical_reply_parts})
		if err.code!=.None {
			#partial switch err.code {
			case .Forbidden,.Not_Found,.Conflict: delivery.status="stale"
			case .Validation_Failed: delivery.status="failed"
			case: // Locked/offline bridge is not a provider attempt.
				delivery.status="pending"
			}
		}
		if delivery.status=="" do delivery.status="pending"
		next := now_ms+5000 if delivery.status=="pending" else 0
		err = s.repo.channel_reply_finish(s.repo.ctx,job.reply_message_id,delivery.status,next)
		if err.code==.None && delivery.status!="pending" && s.event_bus!=nil && s.canonical_content!=nil {
			m, found, read_err := iface.content_get_message(s.canonical_content.content,job.reply_message_id)
			if read_err.code==.None && found && string(m.owner_user_id)==job.owner_user_id do publish_canonical_channel_change(s,m,"messages_delivery")
		}
	}
}

@(private="file")
Canonical_Reply_Delivery :: struct {
	s: ^Bots_Service,
	adapter: ^channel.Channel_Adapter,
	job: domain.Bot_Channel_Reply_Job,
	status: string,
}

@(private="file")
admit_canonical_part :: proc(d: ^Canonical_Reply_Delivery, expected: Channel_Vault_Prepared, expected_authority: Channel_Vault_Authority, index: int) -> (string,domain.Domain_Error) {
	// Pairing, revocation and opt-out all serialize with admission. Never
	// hold the service mutex or DB transaction over provider I/O.
	s := d.s
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	p, err := prepare_channel_bound_open(s,d.job.owner_user_id,d.job.reply_message_id)
	if err.code!=.None do return "",err
	if p!=expected || !canonical_channel_enabled(s,p.provider) do return "stale",{}
	authority, auth_err := channel_vault_authority(s,d.job.owner_user_id,p.bridge_id)
	if auth_err.code!=.None do return "",auth_err
	if authority!=expected_authority do return "stale",{}
	return s.repo.channel_reply_part_claim(s.repo.ctx,d.job.reply_message_id,index)
}

@(private="file")
send_canonical_reply_parts :: proc(raw:rawptr, expected: Channel_Vault_Prepared, authority: Channel_Vault_Authority, text: string) {
	d := (^Canonical_Reply_Delivery)(raw)
	s := d.s
	d.status="pending"
	// Existing artifacts remain encrypted. Send an authenticated web link
	// rather than widening the reply proof into arbitrary artifact decryption.
	parts := channel_text_chunks(text,context.temp_allocator)
	if s.canonical_content!=nil {
		row, found, err := iface.content_get_message(s.canonical_content.content,d.job.reply_message_id)
		if err.code!=.None || !found do return
		ids: []string
		if row.artifact_ids_json!="" {
			if json.unmarshal_string(row.artifact_ids_json,&ids,allocator=context.temp_allocator)!=nil do return
		}
		for id in ids {
			if !channelvault.valid_id(id) || !strings.has_prefix(id,"art_") do continue
			link := bots_media_link_text(s,"","Attachment",id)
			list := make([]string,len(parts)+1,context.temp_allocator)
			copy(list,parts)
			list[len(parts)]=link
			parts=list
		}
	}
	d.status="pending"
	for body, index in parts {
		state, err := admit_canonical_part(d,expected,authority,index)
		if err.code!=.None {
			if err.code==.Forbidden || err.code==.Not_Found || err.code==.Conflict do d.status="stale"
			return
		}
		switch state {
		case "sent": continue
		case "sending":
			// We do not know whether an earlier process reached the
			// provider after it durably claimed this part.
			_ = s.repo.channel_reply_part_finish(s.repo.ctx,d.job.reply_message_id,index,"unknown","")
			d.status="unknown"
			return
		case "failed","unknown","stale":
			d.status=state
			return
		case "claimed":
		case: return
		}
		external_id, result := d.adapter.send_text(d.adapter.ctx,expected.recipient,body)
		defer delete(external_id)
		part_status := "sent"
		if result.kind!=.None || external_id=="" {
			#partial switch result.kind {
			case .Chat_Unavailable,.Invalid_Request,.Unauthorized,.Rate_Limited,.Window_Closed,.Template_Unavailable,.Media_Too_Large,.Media_Unavailable:
				part_status="failed"
			case: part_status="unknown"
			}
		}
		if record_err := s.repo.channel_reply_part_finish(s.repo.ctx,d.job.reply_message_id,index,part_status,external_id if part_status=="sent" else ""); record_err.code!=.None {
			d.status="unknown"
			return
		}
		if part_status!="sent" {
			d.status=part_status
			return
		}
	}
	d.status="sent"
}
