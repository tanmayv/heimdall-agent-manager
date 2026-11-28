package bots

import "core:strings"
import "core:encoding/json"
import "core:strconv"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"

Canonical_Intake_Disposition :: enum { Legacy, Handled, Retry }

Canonical_Intake :: struct {
	disposition: Canonical_Intake_Disposition,
	message_id: string,
	delivery: content.Message_Delivery,
}

// Verified providers share this admission. No raw text is committed or put in
// a legacy queue. The caller may not advance its cursor on a Retry result.
accept_canonical_channel_text :: proc(s: ^Bots_Service, svc: ^content.Content_Service, provider: string, event: channel.Inbound) -> (Canonical_Intake, domain.Domain_Error) {
	if !event.chat_is_private || (event.kind != .Text && event.kind != .Media) do return {.Legacy,"",{}},{}
	binding, bound, binding_err := bots_find_binding(s,provider,event.external_chat_id,event.external_user_id)
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return {.Retry,"",{}},binding_err
	if !bound do return {.Legacy,"",{}},{}
	owner := binding.owner_user_id
	activation, activated, read_err := iface.bot_web_activation_get(s.repo,owner)
	defer domain.bot_web_activation_destroy(&activation)
	if read_err.code != .None do return {.Retry,"",{}},read_err
	if !activated do return {.Legacy,"",{}},{}
	if !activation.enabled || binding.external_chat_id!=event.external_chat_id || binding.external_user_id!=event.external_user_id ||
	   !bots_gate_on(s.experiments,owner) {
		return {.Handled,"",{}},{}
	}
	grant, current, grant_err := iface.bot_channel_conversion_binding_get(s.repo,binding.binding_id)
	if grant_err.code != .None do return {.Retry,"",{}},grant_err
	if !current || grant.activation_generation != activation.generation do return {.Handled,"",{}},{}
	if event.update_key == "" || (len(event.text)==0 && event.kind==.Text) || len(event.text)>contracts.BOT_CHANNEL_VAULT_MAX_PLAINTEXT || !utf8.valid_string(event.text) {
		return {.Handled,"",{}},bots_detail_error(.Validation_Failed,"channel_text_invalid")
	}
	received_ms, time_valid := platform.rfc3339_to_unix_ms(event.provider_time)
	bound_ms, bind_time_valid := platform.rfc3339_to_unix_ms(binding.created_at)
	// Provider timestamps can be second-resolution. Accept the binding second;
	// the durable provider update identity then prevents cross-binding replay.
	if !time_valid || !bind_time_valid || received_ms/1000 < bound_ms/1000 do return {.Handled,"",{}},{}
	if provider==domain.CHANNEL_PROVIDER_TELEGRAM && received_ms/1000==bound_ms/1000 && grant.pairing_update_key!="" &&
	   !telegram_update_after_pairing(event.update_key,grant.pairing_update_key) {
		return {.Handled,"",{}},{}
	}
	id := content.scoped_message_id("msg_channel_",activation.conversation_id,event.update_key)
	defer delete(id)
	if used, used_err := iface.bot_channel_conversion_origin_exists(s.repo,binding.binding_id,event.update_key,id); used_err.code != .None {
		return {.Retry,"",{}},used_err
	} else if used {
		return {.Handled,strings.clone(id),{}},{}
	}
	media: Canonical_Media_Seal
	defer delete(media.token)
	message := event
	if event.kind==.Media {
		media_note: string
		media_err: domain.Domain_Error
		media,media_note,media_err = seal_canonical_channel_media(s,owner,binding.binding_id,id,provider,event)
		if media_err.code!=.None do return {.Retry,"",{}},media_err
		message.kind=.Text
		if media_note!="" {
			message.text=media_note if event.text=="" else strings.concatenate({event.text,"\n\n",media_note},context.temp_allocator)
		} else if message.text=="" {
			message.text="Attachment"
		}
	}
	sealed_source: Channel_Vault_Prepared
	token, seal_err := seal_channel_input(s,owner,binding.binding_id,id,provider,message,&sealed_source)
	defer delete(token)
	if seal_err.code != .None {
		if used,used_err := iface.bot_channel_conversion_origin_exists(s.repo,binding.binding_id,event.update_key,id); used && used_err.code==.None {
			return {.Handled,strings.clone(id),{}},{}
		}
		return {.Retry,"",{}},seal_err
	}

	if media.token!="" && media.source!=sealed_source {
		return {.Retry,"",{}},bots_detail_error(.Conflict,"channel_media_source_changed")
	}
	uow, begun, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {.Retry,"",{}},begin_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	if used,used_err := iface.bot_channel_conversion_origin_exists(&uow.repos.bots,binding.binding_id,event.update_key,id); used_err.code != .None {
		return {.Retry,"",{}},used_err
	} else if used {
		return {.Handled,strings.clone(id),{}},{}
	}
	prepared, source_err := read_channel_conversion_source(s,uow.repos,owner,binding.binding_id,event.update_key,id,"")
	if source_err.code != .None do return {.Retry,"",{}},source_err
	if prepared != sealed_source || prepared.request.activation_generation != activation.generation || prepared.request.binding_generation != grant.binding_generation ||
	   prepared.request.conversation_id != activation.conversation_id || prepared.provider != provider ||
	   prepared.recipient != event.external_chat_id || prepared.external_user_id != event.external_user_id {
		return {.Retry,"",{}},bots_detail_error(.Conflict,"channel_origin_changed")
	}
	local := svc^
	local.content=&uow.repos.content
	local.agents=&uow.repos.agents
	auth := contracts.Auth_Context{kind=.Internal_User,user_id=owner}
	artifacts: string
	if media.token!="" {
		kind := domain.channel_media_kind_text(domain.Channel_Media_Kind(event.media.kind))
		art, created, art_err := content.create_artifact(&local,auth,{
			kind=kind,name="Channel attachment",mime=media.mime,content=media.token,
			origin_kind="conversation_chat",origin_ref=activation.conversation_id,
			agent_instance_id=activation.agent_instance_id,
		})
		if !created do return {.Retry,"",{}},art_err
		raw, enc_err := json.marshal([]string{art.artifact_id},allocator=context.temp_allocator)
		if enc_err!=nil do return {.Retry,"",{}},bots_detail_error(.Internal_Error,"channel_attachment_encode_failed")
		artifacts=string(raw)
	}
	m, saved, save_err := content.persist_user_message(&local,auth,activation.conversation_id,{body=token,artifact_ids_json=artifacts},id)
	if !saved do return {.Retry,"",{}},save_err
	if origin_err := iface.bot_channel_conversion_origin_insert(&uow.repos.bots,{id,binding.binding_id,event.update_key,event.external_message_id}); origin_err.code != .None {
		return {.Retry,"",{}},origin_err
	}
	if updated, update_err := iface.content_set_authenticated_channel_origin(local.content,m.owner_user_id,m.conversation_id,id,provider,binding.binding_id); !updated {
		return {.Retry,"",{}},update_err
	}
	committed, commit_err := bots_uow_commit(&uow)
	if !committed do return {.Retry,"",{}},commit_err
	publish_canonical_channel_change(s,m,"message_created")
	delivery := deliver_canonical_message(s,svc,auth,m,activation.generation)
	if delivery.state==.Pending && s.repo.channel_queue_feedback!=nil {
		_ = s.repo.channel_queue_feedback(s.repo.ctx,id)
	}
	return {.Handled,strings.clone(id),delivery},{}
}

// Telegram's bot-scoped update counter prevents a delayed pre-pair event in
// the same second from being admitted after a replacement pairing.
telegram_update_after_pairing :: proc(event, paired: string) -> bool {
	e := strings.last_index_byte(event,':')
	p := strings.last_index_byte(paired,':')
	if e<0 || p<0 || event[:e]!=paired[:p] || !strings.has_prefix(event[:e],"telegram:") do return false
	next, ok_next := strconv.parse_u64(event[e+1:])
	last, ok_last := strconv.parse_u64(paired[p+1:])
	return ok_next && ok_last && next>last
}
