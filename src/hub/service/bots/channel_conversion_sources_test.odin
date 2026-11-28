package bots

import "core:crypto"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

CONVERSION_AT :: "2026-11-17T12:00:00Z"

make_conversion_binding :: proc(t: ^testing.T, f: ^Activation_Fixture, id, provider: string, generation: i64, fresh := true) -> bool {
	repo := &f.repos.bots
	pair_code := strings.concatenate({id,"-",provider, "-fresh" if fresh else "-legacy"})
	pairing := domain.Channel_Pairing{
		code_hash=pair_code,owner_user_id="alice",bot_id="bot_a",provider=provider,created_at=CONVERSION_AT,expires_at="2027-01-01",
	}
	issued: domain.Domain_Error
	if fresh {
		issued = iface.bot_channel_conversion_pairing_insert_fresh(repo,pairing,1)
	} else {
		issued = iface.pairing_insert(repo,pairing)
	}
	if !testing.expect(t,issued.code == .None,issued.message) do return false
	b := domain.Channel_Binding{
		binding_id=id,owner_user_id="alice",bot_id="bot_a",provider=provider,
		external_chat_id="fake-recipient",external_user_id="fake-sender",state=.Active,created_at=CONVERSION_AT,
	}
	err: domain.Domain_Error
	if fresh {
		_, _, err = iface.bot_channel_conversion_binding_activate_fresh(repo,b,pair_code,CONVERSION_AT,1,generation)
	} else {
		_, _, err = iface.binding_activate(repo,b,pair_code,CONVERSION_AT)
	}
	return testing.expect(t,err.code == .None,err.message)
}

@(test)
test_channel_conversion_ingress_only_uses_fresh_pairing_and_current_assignment :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t,&f,true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	if !make_conversion_binding(t,&f,"chb_legacy","telegram",1,fresh=false) do return
	state, active_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,active_err.code == .None,active_err.message) do return
	_, legacy_err := prepare_channel_ingress_seal(s,"alice","chb_legacy","update-a","msg_proposed")
	testing.expect(t, legacy_err.code == .Forbidden, "existing active pairing without a fresh grant is ineligible")

	// Attempting to attest the legacy ID by inserting it again must fail
	// atomically, leaving the old pairing and no grant.
	repo := &f.repos.bots
	testing.expect_value(t, iface.bot_channel_conversion_pairing_insert_fresh(repo,{
		code_hash="repeat-old",owner_user_id="alice",bot_id="bot_a",provider="telegram",created_at=CONVERSION_AT,expires_at="2027-01-01",
	},1).code,domain.Error_Code.None)
	_, _, retrofit_err := iface.bot_channel_conversion_binding_activate_fresh(repo,{
		binding_id="chb_legacy",owner_user_id="alice",bot_id="bot_a",provider="telegram",
		external_chat_id="fake-recipient",external_user_id="fake-sender",state=.Active,created_at=CONVERSION_AT,
	},"repeat-old",CONVERSION_AT,1,1)
	testing.expect(t, retrofit_err.code != .None, "legacy binding cannot be retroactively granted conversion")
	_, old_grant, _ := iface.bot_channel_conversion_binding_get(repo,"chb_legacy")
	binding, still_active, _ := iface.binding_get_active_by_owner(repo,"alice","telegram")
	testing.expect(t, !old_grant && still_active && binding.binding_id == "chb_legacy")
	if !make_conversion_binding(t,&f,"chb_fresh","telegram",2) do return

	p, err := prepare_channel_ingress_seal(s,"alice","chb_fresh","update-a","msg_proposed")
	if !testing.expect(t,err.code == .None,err.message) do return
	testing.expect(t,p.request.operation == "seal" && p.request.body == "" && p.request.source_proof == "" &&
		p.request.activation_generation == 1 && p.request.binding_generation == 2 && p.request.input_message_id == "msg_proposed" &&
		p.request.conversation_id == state.conversation_id && p.request.agent_instance_id == state.agent_instance_id &&
		p.provider == "telegram" && p.recipient == "fake-recipient" && p.external_user_id == "fake-sender",
		"seal carries exact scoped identities, no payload or open proof")
	testing.expect_value(t,recheck_channel_conversion(s,p).code,domain.Error_Code.None)
	_, denied := prepare_channel_ingress_seal(s,"bob","chb_fresh","update-a","msg_proposed")
	testing.expect(t,denied.code == .Forbidden,"other owner cannot use a known binding ID")

	// Change an admissible placement preference without changing the selected
	// destination. Authorization still captures the monotonic policy revision.
	_, changed := iface.placement_replace(repo,"bot_a",p.placement_revision,{{bridge_id="b",provider="beta",model="m2",tier=.Allowed}},"now")
	testing.expect_value(t,changed.code,domain.Error_Code.None)
	testing.expect_value(t,recheck_channel_conversion(s,p).code,domain.Error_Code.Conflict)
	new_p, new_err := prepare_channel_ingress_seal(s,"alice","chb_fresh","update-a","msg_proposed")
	if !testing.expect(t,new_err.code == .None,new_err.message) do return
	off, off_err := set_web_activation(s,"alice",false,1)
	testing.expect_value(t,off_err.code,domain.Error_Code.None)
	_, on_err := set_web_activation(s,"alice",true,off.generation)
	testing.expect_value(t,on_err.code,domain.Error_Code.None)
	testing.expect_value(t,recheck_channel_conversion(s,new_p).code,domain.Error_Code.Forbidden)
}

conversion_store_chat :: proc(t: ^testing.T, f: ^Activation_Fixture, a: domain.Bot_Web_Activation, id, direction, token: string, metadata := "") -> bool {
	_, stored, err := iface.content_save_message(&f.repos.content,{
		message_id=id,owner_user_id=domain.User_ID(a.owner_user_id),conversation_id=a.conversation_id,
		sender_agent_instance_id=a.agent_instance_id,direction=direction,
		body=token,metadata_json=metadata,created_at=CONVERSION_AT,
	})
	return testing.expect(t,stored,err.message)
}

@(test)
test_channel_conversion_open_uses_immutable_source_and_rechecks_purge :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t,&f,true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	a, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code == .None,activation_err.message) do return
	if !make_conversion_binding(t,&f,"chb_fresh","whatsapp",3) do return

	key_material: [32]byte
	if !testing.expect(t,random.fill(key_material[:]),"generated disposable fixture key") do return
	key, created := vault.keyring_from_single_key("alice",{1,2,3,4,5,6,7,8},1,key_material[:])
	crypto.zero_explicit(&key_material,size_of(key_material))
	defer vault.keyring_wipe(&key)
	if !testing.expect(t,created) do return
	input, _ := vault.seal_string("synthetic inbound marker",&key)
	reply, _ := vault.seal_string("synthetic reply marker",&key)
	if !conversion_store_chat(t,&f,a,"msg_input","user_to_agent",input) do return
	if !conversion_store_chat(t,&f,a,"msg_reply","agent_to_user",reply,`{"reply_to":"msg_input","binding_id":"chb_fresh"}`) do return
	_, claimed := prepare_channel_bound_open(s,"alice","msg_reply")
	testing.expect_value(t,claimed.code,domain.Error_Code.Forbidden)

	repo := &f.repos.bots
	if !testing.expect_value(t,iface.bot_channel_conversion_origin_insert(repo,{
		inbound_message_id="msg_input",binding_id="chb_fresh",provider_update_key="fake-event",
	}).code,domain.Error_Code.None) {
		return
	}
	_, event_used := prepare_channel_ingress_seal(s,"alice","chb_fresh","fake-event","msg_new")
	testing.expect_value(t,event_used.code,domain.Error_Code.Conflict)
	_, id_used := prepare_channel_ingress_seal(s,"alice","chb_fresh","other-event","msg_reply")
	testing.expect_value(t,id_used.code,domain.Error_Code.Conflict)
	proof := strings.repeat("a",64,context.temp_allocator)
	if !testing.expect_value(t,iface.bot_channel_conversion_reply_insert(repo,"msg_reply","msg_input",proof).code,domain.Error_Code.None) do return
	p, err := prepare_channel_bound_open(s,"alice","msg_reply")
	if !testing.expect(t,err.code == .None,err.message) do return
	testing.expect(t,p.request.operation == "open" && p.request.body == reply && p.request.source_proof == proof &&
		p.request.binding_generation == 3 && p.request.provider_event_id == "" && p.origin_event_id == "fake-event" && p.request.input_message_id == "msg_input" && p.request.reply_message_id == "msg_reply" &&
		p.provider == "whatsapp" && p.recipient == "fake-recipient" && !strings.contains(p.request.body,"synthetic"),
		"open uses repository ciphertext and an immutable proof, with exact route")
	testing.expect_value(t,recheck_channel_conversion(s,p).code,domain.Error_Code.None)

	// Ciphertext substitution (even another valid value) invalidates the whole
	// pre-exchange snapshot. The bridge independently verifies authorship.
	replacement, _ := vault.seal_string("replacement marker",&key)
	_, changed, _ := iface.content_update_message(&f.repos.content,"alice",a.conversation_id,"msg_reply",replacement,"complete","")
	testing.expect(t,changed)
	testing.expect_value(t,recheck_channel_conversion(s,p).code,domain.Error_Code.Conflict)
	_, restored, _ := iface.content_update_message(&f.repos.content,"alice",a.conversation_id,"msg_reply",reply,"complete","")
	testing.expect(t,restored)
	_, purged, _ := iface.content_update_message(&f.repos.content,"alice",a.conversation_id,"msg_input","","complete","")
	testing.expect(t,purged)
	testing.expect_value(t,recheck_channel_conversion(s,p).code,domain.Error_Code.Forbidden)
	_, later := prepare_channel_bound_open(s,"alice","msg_reply")
	testing.expect_value(t,later.code,domain.Error_Code.Forbidden)
	_, restored_input, _ := iface.content_update_message(&f.repos.content,"alice",a.conversation_id,"msg_input",input,"complete","")
	testing.expect(t,restored_input)
	testing.expect_value(t,iface.binding_revoke(repo,"chb_fresh",CONVERSION_AT).code,domain.Error_Code.None)
	testing.expect_value(t,recheck_channel_conversion(s,p).code,domain.Error_Code.Forbidden)
}

@(test)
test_channel_conversion_pairing_codes_cannot_cross_activation_generations :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t,&f,true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	repo := &f.repos.bots
	p := domain.Channel_Pairing{
		code_hash="old-invitation",owner_user_id="alice",bot_id="bot_a",provider="telegram",
		created_at=CONVERSION_AT,expires_at="2027-01-01",
	}
	if !testing.expect_value(t,iface.pairing_insert(repo,p).code,domain.Error_Code.None) do return
	a, act_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,act_err.code == .None,act_err.message) do return
	if !make_conversion_binding(t,&f,"original","telegram",1) do return
	dest := domain.Channel_Binding{
		binding_id="replacement",owner_user_id="alice",bot_id="bot_a",provider="telegram",
		external_chat_id="fake-recipient",external_user_id="fake-sender",state=.Active,created_at=CONVERSION_AT,
	}
	_, _, old_err := iface.bot_channel_conversion_binding_activate_fresh(repo,dest,p.code_hash,CONVERSION_AT,a.generation,2)
	testing.expect_value(t,old_err.code,domain.Error_Code.Conflict)
	old_code, found_old, _ := iface.pairing_get(repo,p.code_hash)
	testing.expect(t,found_old && old_code.consumed_at == "", "rejected legacy code was not consumed")
	original, active, _ := iface.binding_get_active_by_owner(repo,"alice","telegram")
	testing.expect(t,active && original.binding_id == "original", "rejection did not revoke active binding")

	p.code_hash = "generation-one-code"
	if !testing.expect_value(t,iface.bot_channel_conversion_pairing_insert_fresh(repo,p,a.generation).code,domain.Error_Code.None) do return
	_, _, legacy_attempt := iface.binding_activate(repo,dest,p.code_hash,CONVERSION_AT)
	testing.expect_value(t,legacy_attempt.code,domain.Error_Code.Conflict)
	consumed_by_legacy, legacy_err := iface.pairing_consume(repo,p.code_hash,CONVERSION_AT)
	testing.expect(t,!consumed_by_legacy && legacy_err.code == .None,"plain legacy consume cannot burn a fresh invitation")
	off, off_err := set_web_activation(s,"alice",false,a.generation)
	if !testing.expect(t,off_err.code == .None,off_err.message) do return
	on, on_err := set_web_activation(s,"alice",true,off.generation)
	if !testing.expect(t,on_err.code == .None,on_err.message) do return
	_, _, stale := iface.bot_channel_conversion_binding_activate_fresh(repo,dest,p.code_hash,CONVERSION_AT,on.generation,2)
	testing.expect_value(t,stale.code,domain.Error_Code.Conflict)
	stale_code, found_stale, _ := iface.pairing_get(repo,p.code_hash)
	testing.expect(t,found_stale && stale_code.consumed_at == "", "stale code was not consumed")
	unchanged, still_active, _ := iface.binding_get_active_by_owner(repo,"alice","telegram")
	testing.expect(t,still_active && unchanged.binding_id == "original", "stale code did not revoke original binding")

	p.code_hash = "generation-three-code"
	if !testing.expect_value(t,iface.bot_channel_conversion_pairing_insert_fresh(repo,p,on.generation).code,domain.Error_Code.None) do return
	_, _, replacement_err := iface.bot_channel_conversion_binding_activate_fresh(repo,dest,p.code_hash,CONVERSION_AT,on.generation,2)
	testing.expect_value(t,replacement_err.code,domain.Error_Code.None)
	grant, granted, _ := iface.bot_channel_conversion_binding_get(repo,dest.binding_id)
	testing.expect(t,granted && grant.activation_generation == on.generation,"only a current fresh invitation attests a new binding")
}

// No plaintext enters this step. The caller already owns a freshly admitted
// provider event and supplies its immutable identity and reserved canonical ID.
prepare_channel_ingress_seal :: proc(s: ^Bots_Service, owner, binding_id, provider_update_key, inbound_message_id: string) -> (Channel_Vault_Prepared, domain.Domain_Error) {
	return prepare_channel_conversion_source(s,owner,binding_id,provider_update_key,inbound_message_id,"")
}

// The only request input is the scoped canonical reply ID. A chat row's
// arbitrary metadata (including a claimed reply-to) never confers authority.
prepare_channel_bound_open :: proc(s: ^Bots_Service, owner, reply_message_id: string) -> (Channel_Vault_Prepared, domain.Domain_Error) {
	return prepare_channel_conversion_source(s,owner,"","","",reply_message_id)
}

prepare_channel_conversion_source :: proc(s: ^Bots_Service, owner, binding_id, event_id, input_id, reply_id: string) -> (Channel_Vault_Prepared, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	uow, begun, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {}, begin_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	prepared, err := read_channel_conversion_source(s,uow.repos,owner,binding_id,event_id,input_id,reply_id)
	if err.code != .None do return {}, err
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed do return {}, commit_err
	return prepared, {}
}

// Repeat the full canonical lookup after the bridge responds. Comparison also
// fences changes to recipient, source token, activation, assignment and policy.
recheck_channel_conversion :: proc(s: ^Bots_Service, previous: Channel_Vault_Prepared) -> domain.Domain_Error {
	req := previous.request
	refreshed: Channel_Vault_Prepared
	err: domain.Domain_Error
	switch req.operation {
	case "seal": refreshed,err = prepare_channel_ingress_seal(s,req.owner_user_id,req.binding_id,req.provider_event_id,req.input_message_id)
	case "open": refreshed,err = prepare_channel_bound_open(s,req.owner_user_id,req.reply_message_id)
	case: return channel_conversion_denied()
	}
	if err.code != .None do return err
	if refreshed != previous do return bots_detail_error(.Conflict,"channel_conversion_source_changed")
	return {}
}
