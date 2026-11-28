package bots

import "core:fmt"
import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"
import platform "odin_test:hub/platform"
import vault "odin_test:lib/vault"
import channelvault "odin_test:lib/channelvault"

Canonical_WA_Fake :: struct {
	batch: []channel.Inbound,
	now: string,
	calls: int,
	fail_call: int,
	fail_kind: channel.Channel_Error_Kind,
	recipient: string,
	entitled: bool,
}
canonical_wa_clock :: proc(raw: rawptr) -> string {return (^Canonical_WA_Fake)(raw).now}
canonical_wa_push :: proc(raw: rawptr, sig, body: string, allocator := context.allocator) -> ([]channel.Inbound,channel.Push_Verdict) {
	if sig!="verified-fixture" do return nil,.Bad_Signature
	return (^Canonical_WA_Fake)(raw).batch,.Accepted
}
canonical_wa_send :: proc(raw: rawptr, chat, body: string) -> (string,channel.Channel_Error) {
	f := (^Canonical_WA_Fake)(raw)
	f.calls+=1
	f.recipient=chat
	if f.calls==f.fail_call do return "",{kind=f.fail_kind}
	return strings.clone(fmt.tprintf("wamid.synthetic.%d",f.calls)),{}
}
canonical_wa_failure :: proc(code: int) -> channel.Channel_Error_Kind {return .Window_Closed if code==131047 else .Invalid_Request}

canonical_wa_text :: proc(key, stamp: string, text := "canonical WhatsApp input") -> channel.Inbound {
	return {kind=.Text,chat_is_private=true,update_key=key,external_chat_id="signed-address-alias",
		external_message_id=key,external_user_id="fake-sender",provider_time=stamp,text=text}
}

canonical_wa_setup :: proc(f: ^Vault_Roundtrip, fake: ^Canonical_WA_Fake, adapter: ^channel.Channel_Adapter, svc: ^content.Content_Service, clock: ^platform.Clock) {
	af:=&f.fixture
	s:=&af.pair.service
	adapter^={ctx=fake,provider="whatsapp",push_parse=canonical_wa_push,send_text=canonical_wa_send,
		reply_window_ms=channel.WHATSAPP_REPLY_WINDOW_MS,failure_kind=canonical_wa_failure,identity=pairing_test_identity}
	clock^={ctx=fake,now=canonical_wa_clock}
	s.whatsapp=adapter
	s.clock=clock
	s.canonical_whatsapp_owner="alice"
	s.canonical_content=svc
	svc^={content=&af.repos.content,agents=&af.repos.agents,uow_factory=&af.pair.uow,clock=clock,ids=&af.ids,
		reply_proof={ctx=s,commit=record_canonical_reply_proof}}
}

@(test)
test_canonical_whatsapp_mixed_webhook_retries_without_plaintext_spool :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena)
	context.temp_allocator=context.allocator
	f: Vault_Roundtrip
	if !testing.expect(t,roundtrip_boot(t,&f)) do return
	defer activation_fixture_close(&f.fixture)
	defer vault.keyring_wipe(&f.kr)
	af:=&f.fixture
	s:=&af.pair.service
	fake := Canonical_WA_Fake{now="2026-11-17T12:01:30Z"}
	adapter: channel.Channel_Adapter
	svc: content.Content_Service
	clock: platform.Clock
	canonical_wa_setup(&f,&fake,&adapter,&svc,&clock)
	a, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code==.None,activation_err.message) do return
	if !make_conversion_binding(t,af,"wa_fresh","whatsapp",1) do return
	repo:=&af.repos.bots
	_, exp_err := iface.experiment_set(s.experiments,{owner_user_id="bob",key="bots",enabled=true,updated_at=CONVERSION_AT})
	testing.expect_value(t,exp_err.code,domain.Error_Code.None)
	testing.expect_value(t,iface.bot_insert(repo,{bot_id="wa_legacy_bot",agent_id="agt_b",owner_user_id="bob",created_at=CONVERSION_AT,updated_at=CONVERSION_AT}).code,domain.Error_Code.None)
	testing.expect_value(t,iface.pairing_insert(repo,{code_hash="wa-legacy",owner_user_id="bob",bot_id="wa_legacy_bot",provider="whatsapp",created_at=CONVERSION_AT,expires_at="2027-01-01"}).code,domain.Error_Code.None)
	_, _, pair_err := iface.binding_activate(repo,{binding_id="wa_legacy",owner_user_id="bob",bot_id="wa_legacy_bot",provider="whatsapp",
		external_chat_id="legacy-address",external_user_id="legacy-user",state=.Active,created_at=CONVERSION_AT},"wa-legacy",CONVERSION_AT)
	testing.expect_value(t,pair_err.code,domain.Error_Code.None)
	// Existing spool payload is a time capsule. It must never become a
	// new canonical conversation row, even with the same owner and address.
	_, old_err := iface.push_events_insert(repo,{{provider="whatsapp",event_key="wa-old-pending",kind=.Text,external_chat_id="fake-recipient",
		external_user_id="fake-sender",provider_time=CONVERSION_AT,received_at=CONVERSION_AT,body="pre-cutover local legacy bytes"}})
	testing.expect_value(t,old_err.code,domain.Error_Code.None)
	fake.batch=[]channel.Inbound{
		canonical_wa_text("whatsapp:pn:42","2026-11-17T12:01:00Z","NeverStageCanonicalFjord"),
		{kind=.Text,chat_is_private=true,update_key="whatsapp:pn:43",external_chat_id="legacy-address",external_user_id="legacy-user",
			provider_time="2026-11-17T12:01:00Z",text="continue serving the other owner"},
	}
	invalid,_,_ := bots_push_receive(s,"whatsapp","wrong-signature","")
	testing.expect_value(t,invalid,Push_Receive_Result.Bad_Signature)
	f.locked=true
	blocked,_,_ := bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect_value(t,blocked,Push_Receive_Result.Store_Failed)
	n0,_:=sqlite.scalar_count(&af.pair.conn,"SELECT count(*) FROM channel_push_events;")
	testing.expect_value(t,n0,1)
	f.locked=false
	good, _, count := bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect(t,good==.Stored && count==2)
	retry, _, replay_count := bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect(t,retry==.Stored && replay_count==0)
	n1,_:=sqlite.scalar_count(&af.pair.conn,"SELECT count(*) FROM channel_push_events WHERE body='NeverStageCanonicalFjord';")
	testing.expect_value(t,n1,0)
	rt:=Bots_Runtime{service=s}
	_,_ = bots_push_intake_iteration(&rt)
	rows, msg_err := iface.content_list_messages(&af.repos.content,a.conversation_id,"alice",10,"")
	if !testing.expect(t,msg_err.code==.None && len(rows)==1,msg_err.message) do return
	plain, open_err := vault.open(rows[0].body,&f.kr)
	testing.expect(t,open_err==.Ok && plain=="NeverStageCanonicalFjord")
	bound, found, _ := iface.binding_get(repo,"wa_fresh")
	testing.expect(t,found && bound.last_inbound_at=="2026-11-17T12:01:00Z" && bound.external_chat_id=="fake-recipient",
		"a verified stable alias opens the window but does not change the reply destination")
	legacy,_:=iface.messages_pending(repo,"wa_legacy_bot",-1)
	testing.expect(t,len(legacy)==1 && legacy[0].body=="continue serving the other owner")
}

canonical_wa_entitlement :: proc(raw:rawptr,owner: string) -> (domain.User_Entitlements,domain.Domain_Error) {
	return {whatsapp_enabled=(^Canonical_WA_Fake)(raw).entitled},{}
}

canonical_wa_author :: proc(t:^testing.T,s:^Bots_Service,svc:^content.Content_Service,kr:^vault.Vault_Keyring,inst: domain.Agent_Instance,input,body: string) -> string {
	scope, _, err := prepare_canonical_reply(s,inst,input)
	if !testing.expect(t,err.code==.None && scope.provider=="whatsapp",err.message) do return ""
	token, proof, sealed := channelvault.seal_authored(scope,body,kr)
	if !testing.expect(t,sealed) do return ""
	snapshot:=inst
	auth:=contracts.Auth_Context{kind=.Instance_Token,user_id=string(inst.owner_user_id),agent_instance_id=inst.agent_instance_id}
	msg, saved, save_err := content.send_agent_message_with_id(svc,auth,inst.agent_instance_id,{body=token,reply_to_message_id=input},
		scope.reply_message_id,&snapshot,{input,proof})
	if !testing.expect(t,saved && save_err.code==.None,save_err.message) do return ""
	return msg.message_id
}

@(test)
test_canonical_whatsapp_holds_partial_sends_and_applies_exact_callbacks :: proc(t:^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena)
	context.temp_allocator=context.allocator
	f: Vault_Roundtrip
	if !testing.expect(t,roundtrip_boot(t,&f)) do return
	defer activation_fixture_close(&f.fixture)
	defer vault.keyring_wipe(&f.kr)
	af:=&f.fixture
	s:=&af.pair.service
	fake:=Canonical_WA_Fake{now="2026-11-17T12:01:30Z",entitled=true}
	adapter: channel.Channel_Adapter
	svc: content.Content_Service
	clock: platform.Clock
	canonical_wa_setup(&f,&fake,&adapter,&svc,&clock)
	s.entitlements={ctx=&fake,lookup=canonical_wa_entitlement}
	a, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code==.None,activation_err.message) do return
	if !make_conversion_binding(t,af,"wa_fresh","whatsapp",1) do return
	accepted, intake_err := accept_canonical_channel_text(s,&svc,"whatsapp",canonical_wa_text("whatsapp:pn:initial","2026-11-17T12:01:00Z"))
	if !testing.expect(t,accepted.message_id!="" && intake_err.code==.None,intake_err.message) do return
	inst, inst_found, inst_err := iface.agent_get_instance(&af.repos.agents,a.agent_instance_id)
	if !testing.expect(t,inst_found && inst_err.code==.None,inst_err.message) do return
	repo:=&af.repos.bots
	reply:=canonical_wa_author(t,s,&svc,&f.kr,inst,accepted.message_id,strings.repeat("x",6500,context.temp_allocator))
	if reply=="" do return
	fake.now="2026-11-18T12:20:00Z"
	before_open:=f.exchanges
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_:=repo.channel_reply_state(repo.ctx,reply,"alice")
	testing.expect_value(t,status,"held")
	testing.expect(t,fake.calls==0 && f.exchanges==before_open,"an expired window never opens ciphertext or calls the provider")
	fake.now="2026-11-18T12:20:30Z"
	reopened, _ := accept_canonical_channel_text(s,&svc,"whatsapp",canonical_wa_text("whatsapp:pn:reopen","2026-11-18T12:20:05Z"))
	if !testing.expect(t,reopened.message_id!="") do return
	fake.fail_call,fake.fail_kind=2,.Window_Closed
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_=repo.channel_reply_state(repo.ctx,reply,"alice")
	testing.expect_value(t,status,"held")
	testing.expect(t,fake.calls==2 && fake.recipient=="fake-recipient","the provider rejected the second part and the paired address was retained")
	fake.now="2026-11-18T12:21:00Z"
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	testing.expect_value(t,fake.calls,2)
	fake.now="2026-11-18T12:22:00Z"
	newer, _ := accept_canonical_channel_text(s,&svc,"whatsapp",canonical_wa_text("whatsapp:pn:newer","2026-11-18T12:21:59Z"))
	if !testing.expect(t,newer.message_id!="") do return
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_=repo.channel_reply_state(repo.ctx,reply,"alice")
	testing.expect_value(t,status,"sent")
	testing.expect_value(t,fake.calls,3)

	channel_failure := channel.Inbound{kind=.Delivery_Failed,update_key="whatsapp:pn:failed:3",external_chat_id="not-the-paired-sender",
		external_message_id="wamid.synthetic.3",provider_code=131047}
	fake.batch=[]channel.Inbound{channel_failure}
	_,_,_=bots_push_receive(s,"whatsapp","verified-fixture","")
	bots_canonical_whatsapp_receipt_tick(s)
	status,_=repo.channel_reply_state(repo.ctx,reply,"alice")
	testing.expect_value(t,status,"sent")
	channel_failure.update_key="whatsapp:pn:failed:known-recipient-1"
	channel_failure.external_message_id="wamid.synthetic.1"
	channel_failure.external_chat_id="fake-sender"
	fake.batch=[]channel.Inbound{channel_failure}
	_,_,_=bots_push_receive(s,"whatsapp","verified-fixture","")
	_,_,_=bots_push_receive(s,"whatsapp","verified-fixture","")
	bots_canonical_whatsapp_receipt_tick(s)
	status,_=repo.channel_reply_state(repo.ctx,reply,"alice")
	testing.expect_value(t,status,"held")
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_=repo.channel_reply_state(repo.ctx,reply,"alice")
	testing.expect_value(t,status,"sent")
	testing.expect_value(t,fake.calls,4)
	bots_canonical_whatsapp_receipt_tick(s)
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	testing.expect_value(t,fake.calls,4)

	unknown:=canonical_wa_author(t,s,&svc,&f.kr,inst,newer.message_id,"lost-provider-ack")
	if unknown=="" do return
	fake.fail_call,fake.fail_kind=5,.Transient
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_=repo.channel_reply_state(repo.ctx,unknown,"alice")
	testing.expect_value(t,status,"unknown")
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	testing.expect_value(t,fake.calls,5)

	queued:=canonical_wa_author(t,s,&svc,&f.kr,inst,newer.message_id,"keep on web after losing eligibility")
	if queued=="" do return
	fake.entitled=false
	bots_whatsapp_entitlement_sweep(s)
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_=repo.channel_reply_state(repo.ctx,queued,"alice")
	testing.expect_value(t,status,"stale")
	testing.expect_value(t,fake.calls,5)
	_, live, _ := iface.binding_get_active_by_owner(repo,"alice","whatsapp")
	testing.expect(t,!live,"entitlement loss revokes the binding rather than re-enabling it later")
}

canonical_wa_fetch_media :: proc(raw:rawptr, ref:string, limit:i64, allocator:=context.allocator) -> (channel.Fetched_Media,channel.Channel_Error) {
	if ref!="signed-doc" || limit<4 do return {},{kind=.Media_Unavailable}
	bytes:=make([]byte,4,allocator)
	copy(bytes,([]byte{0xff,0x03,0x00,0x02}))
	return {bytes=bytes,mime=strings.clone("application/pdf",allocator)},{}
}

@(test)
test_canonical_whatsapp_repair_fences_old_work_and_seals_only_new_media :: proc(t:^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena)
	context.temp_allocator=context.allocator
	f: Vault_Roundtrip
	if !testing.expect(t,roundtrip_boot(t,&f)) do return
	defer activation_fixture_close(&f.fixture)
	defer vault.keyring_wipe(&f.kr)
	af:=&f.fixture
	s:=&af.pair.service
	fake:=Canonical_WA_Fake{now="2026-11-17T12:01:30Z",entitled=true}
	a: channel.Channel_Adapter
	svc: content.Content_Service
	clock: platform.Clock
	canonical_wa_setup(&f,&fake,&a,&svc,&clock)
	a.media_fetch=canonical_wa_fetch_media
	state, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code==.None,activation_err.message) do return
	if !make_conversion_binding(t,af,"wa_original","whatsapp",1) do return
	old:=canonical_wa_text("whatsapp:pn:old","2026-11-17T12:01:00Z")
	receipt, receipt_err := accept_canonical_channel_text(s,&svc,"whatsapp",old)
	if !testing.expect(t,receipt.message_id!="" && receipt_err.code==.None,receipt_err.message) do return
	inst, outgoing, inst_err := iface.agent_get_instance(&af.repos.agents,state.agent_instance_id)
	if !testing.expect(t,outgoing && inst_err.code==.None,inst_err.message) do return
	held:=canonical_wa_author(t,s,&svc,&f.kr,inst,receipt.message_id,"bound only to the original")
	if held=="" do return
	fake.now="2026-11-18T12:15:00Z"
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	repo:=&af.repos.bots
	status,_:=repo.channel_reply_state(repo.ctx,held,"alice")
	testing.expect_value(t,status,"held")
	code: string="synthetic-fresh-code"
	invite_err:=iface.bot_channel_conversion_pairing_insert_fresh(repo,{
		code_hash=bots_pairing_hash(code),owner_user_id="alice",provider="whatsapp",bot_id=state.bot_id,created_at=fake.now,expires_at="2026-11-18T12:30:00Z",
	},state.generation)
	if !testing.expect_value(t,invite_err.code,domain.Error_Code.None) do return
	start := channel.Inbound{kind=.Start,chat_is_private=true,update_key="whatsapp:pn:pair",external_chat_id="replacement-address",external_user_id="fake-sender",
		provider_time=fake.now,text=code}
	fake.batch=[]channel.Inbound{start}
	replacement, _, _:=bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect_value(t,replacement,Push_Receive_Result.Stored)
	new_binding, found, pair_err := iface.binding_get_active_by_owner(repo,"alice","whatsapp")
	if !testing.expect(t,found && pair_err.code==.None && new_binding.external_chat_id=="replacement-address" && new_binding.binding_id!="wa_original",
		"verified fresh invite installs a different binding") {return}
	pair_messages:=fake.calls
	fake.now="2026-11-18T12:15:20Z"
	old_unseen:=old
	old_unseen.update_key="whatsapp:pn:staged-before-pair"
	fake.batch=[]channel.Inbound{old,old_unseen}
	_,_,n:=bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect_value(t,n,0)
	bots_canonical_egress_tick(s,"whatsapp",bots_now_ms(s))
	status,_=repo.channel_reply_state(repo.ctx,held,"alice")
	testing.expect_value(t,status,"stale")
	testing.expect_value(t,fake.calls,pair_messages)

	media:=canonical_wa_text("whatsapp:pn:newdoc","2026-11-18T12:15:19Z","new canonical attachment")
	media.kind=.Media
	media.media={kind=.Document,file_ref="signed-doc",mime="application/pdf",size=4}
	fake.batch=[]channel.Inbound{media}
	res, _, count:=bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect(t,res==.Stored && count==1)
	msgs,msg_err:=iface.content_list_messages(&af.repos.content,state.conversation_id,"alice",10,"")
	if !testing.expect(t,msg_err.code==.None && len(msgs)==3,msg_err.message) do return
	for m in msgs {
		if m.direction!="user_to_agent" || m.message_id==receipt.message_id do continue
		caption, caption_err:=vault.open(m.body,&f.kr)
		testing.expect(t,caption_err==.Ok && caption=="new canonical attachment")
		ids: []string
		if !testing.expect(t,json.unmarshal_string(m.artifact_ids_json,&ids)==nil && len(ids)==1) do return
		doc, exists, _:=iface.content_get_artifact(&af.repos.content,ids[0])
		if !testing.expect(t,exists && doc.mime=="application/pdf") do return
		body, opened:=vault.open(doc.content,&f.kr)
		expected:=[]byte{0xff,0x03,0x00,0x02}
		testing.expect(t,opened==.Ok && body==string(expected))
	}
	staged,_:=sqlite.scalar_count(&af.pair.conn,"SELECT count(*) FROM channel_push_events;")
	testing.expect_value(t,staged,0)
	s.canonical_whatsapp_owner="another-owner"
	fake.batch=[]channel.Inbound{canonical_wa_text("whatsapp:pn:outside-pilot","2026-11-18T12:15:21Z")}
	nonpilot,_,accepted_count:=bots_push_receive(s,"whatsapp","verified-fixture","")
	testing.expect(t,nonpilot==.Stored && accepted_count==0,"the same opt-in no longer admits WhatsApp outside the designated pilot")
	scope,_,scope_err:=prepare_canonical_reply(s,inst,receipt.message_id)
	testing.expect(t,scope_err.code==.None && scope.reply_message_id=="","outside the pilot no external reply scope is minted")
}
