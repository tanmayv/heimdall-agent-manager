package bots

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"
import channelvault "odin_test:lib/channelvault"
import vault "odin_test:lib/vault"

Canonical_Test_Send :: struct {
	calls: int,
	fail_call: int,
	address: string,
	artifact_link: string,
	part_lengths: [8]int,
}
canonical_test_send_text :: proc(raw: rawptr, chat, body: string) -> (string,channel.Channel_Error) {
	f := (^Canonical_Test_Send)(raw)
	f.address=chat
	if strings.contains(body,"https://example.test") do f.artifact_link=strings.clone(body,context.temp_allocator)
	if f.calls<len(f.part_lengths) do f.part_lengths[f.calls]=len(body)
	f.calls += 1
	if f.calls==f.fail_call do return "",{kind=.Transient}
	return strings.clone(fmt.tprintf("sent-%d",f.calls)),{}
}

@(test)
test_canonical_explicit_reply_resolves_and_records_unknown_without_resending :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
	defer virtual.arena_destroy(&arena)
	context.allocator=virtual.arena_allocator(&arena)
	context.temp_allocator=context.allocator
	f: Vault_Roundtrip
	if !testing.expect(t,roundtrip_boot(t,&f)) do return
	defer activation_fixture_close(&f.fixture)
	defer vault.keyring_wipe(&f.kr)
	af := &f.fixture
	s := &af.pair.service
	a, err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,err.code==.None,err.message) do return
	if !make_conversion_binding(t,af,"chb_fresh","telegram",1) do return
	s.canonical_telegram=true
	svc := content.Content_Service{content=&af.repos.content,agents=&af.repos.agents,uow_factory=&af.pair.uow,clock=&af.pair.clock,ids=&af.ids,
		reply_proof={ctx=s,commit=record_canonical_reply_proof}}
	fake := Canonical_Test_Send{fail_call=2}
	s.adapter.ctx=&fake
	s.adapter.send_text=canonical_test_send_text
	event := channel.Inbound{kind=.Text,chat_is_private=true,update_key="telegram:test:200",external_chat_id="fake-recipient",
		external_user_id="fake-sender",provider_time=CONVERSION_AT,text="first connected input"}
	accepted, accepted_err := accept_canonical_channel_text(s,&svc,"telegram",event)
	if !testing.expect(t,accepted.disposition==.Handled && accepted.message_id!="" && accepted_err.code==.None,accepted_err.message) do return
	inst, found, inst_err := iface.agent_get_instance(&af.repos.agents,a.agent_instance_id)
	if !testing.expect(t,found && inst_err.code==.None,inst_err.message) do return
	unbound, no_consumed, prep_err := prepare_canonical_reply(s,inst,"")
	testing.expect(t,prep_err.code==.None && unbound.reply_message_id=="" && len(no_consumed.answered_message_ids)==0,
		"pending unread provider input never authorizes external egress")
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="alice",agent_instance_id=inst.agent_instance_id}
	channel_id := accepted.message_id
	if err:=content.note_agent_consumed(&svc,auth,inst.agent_instance_id,{channel_id},domain.INPUT_CONSUMED_READ); err.code!=.None {
		testing.expect(t,false,err.message)
		return
	}
	implicit_scope, implicit, implicit_err := prepare_canonical_reply(s,inst,"")
	testing.expect(t,implicit_err.code==.None && implicit_scope.input_message_id==channel_id && implicit.route_status==domain.REPLY_ROUTE_ROUTED,
		"one consumed channel input authorizes only its original pairing")
	web_token, _ := vault.seal_string("web question",&f.kr)
	_, web_saved, web_err := content.persist_user_message(&svc,{kind=.Internal_User,user_id="alice"},a.conversation_id,{body=web_token},"msg_web")
	if !testing.expect(t,web_saved && web_err.code==.None,web_err.message) do return
	if err:=content.note_agent_consumed(&svc,auth,inst.agent_instance_id,{"msg_web"},domain.INPUT_CONSUMED_READ); err.code!=.None {
		testing.expect(t,false,err.message)
		return
	}
	mixed_scope, mixed, mixed_err := prepare_canonical_reply(s,inst,"")
	testing.expect(t,mixed_err.code==.None && mixed_scope.reply_message_id=="" && mixed.route_status==domain.REPLY_ROUTE_AMBIGUOUS,
		"mixed origins never select a provider")
	scope, origin, scope_err := prepare_canonical_reply(s,inst,channel_id)
	if !testing.expect(t,scope_err.code==.None && scope.provider=="telegram" && scope.input_message_id==channel_id &&
		origin.route_status==domain.REPLY_ROUTE_EXPLICIT,scope_err.message) {
		return
	}
	plain := strings.repeat("private reply marker ",450,context.temp_allocator)
	sealed, proof, proof_ok := channelvault.seal_authored(scope,plain,&f.kr)
	if !testing.expect(t,proof_ok) do return
	m, saved, err_save := content.send_agent_message_with_id(&svc,auth,inst.agent_instance_id,{body=sealed,reply_to_message_id=channel_id},
		scope.reply_message_id,&inst,{channel_id,proof})
	if !testing.expect(t,saved && err_save.code==.None,err_save.message) do return
	repo := &af.repos.bots
	status, _ := repo.channel_reply_state(repo.ctx,m.message_id,"alice")
	testing.expect_value(t,status,"pending")
	bots_canonical_egress_tick(s,"telegram",12345)
	testing.expect_value(t,fake.calls,2)
	testing.expect_value(t,fake.address,"fake-recipient")
	testing.expect(t,fake.part_lengths[0]>0 && fake.part_lengths[1]>0 && fake.part_lengths[0]<len(plain))
	status, _ = repo.channel_reply_state(repo.ctx,m.message_id,"alice")
	testing.expect_value(t,status,"unknown")
	bots_canonical_egress_tick(s,"telegram",67890)
	testing.expect_value(t,fake.calls,2)
	other_owner, _ := repo.channel_reply_state(repo.ctx,m.message_id,"bob")
	testing.expect_value(t,other_owner,"")

	// Simulate a process exiting after the durable claim but before it saved
	// the provider acknowledgement. The next supervisor recovers the receipt
	// without waiting for bridge unlock and without a second network call.
	second, _, second_err := prepare_canonical_reply(s,inst,channel_id)
	if !testing.expect(t,second_err.code==.None && second.reply_message_id!="") do return
	second_body, second_proof, _ := channelvault.seal_authored(second,"second reply",&f.kr)
	row, have_row, row_err := content.send_agent_message_with_id(&svc,auth,inst.agent_instance_id,{body=second_body,reply_to_message_id=channel_id},second.reply_message_id,&inst,{channel_id,second_proof})
	if !testing.expect(t,have_row && row_err.code==.None,row_err.message) do return
	claim, claim_err := repo.channel_reply_part_claim(repo.ctx,row.message_id,0)
	testing.expect(t,claim=="claimed" && claim_err.code==.None)
	f.locked=true
	opens := f.exchanges
	bots_canonical_egress_tick(s,"telegram",72000)
	testing.expect_value(t,f.exchanges,opens)
	testing.expect_value(t,fake.calls,2)
	status, _ = repo.channel_reply_state(repo.ctx,row.message_id,"alice")
	testing.expect_value(t,status,"unknown")
	f.locked=false

	// A bound reply never opens an unrelated artifact. The only external
	// attachment part is an authenticated link to the already sealed content.
	s.ui_origin="https://example.test"
	s.canonical_content=&svc
	art_content, _ := vault.seal_string("web-only attachment bytes",&f.kr)
	art, art_created, art_err := content.create_artifact(&svc,{kind=.Internal_User,user_id="alice"},{name="Attachment",kind="file",content=art_content})
	if !testing.expect(t,art_created && art_err.code==.None,art_err.message) do return
	linked, _, link_err := prepare_canonical_reply(s,inst,channel_id)
	if !testing.expect(t,link_err.code==.None && linked.reply_message_id!="") do return
	link_token, link_proof,_ := channelvault.seal_authored(linked,"Please see the attachment",&f.kr)
	json_ids := fmt.tprintf("[\"%s\"]",art.artifact_id)
	link_row, link_saved, link_save_err := content.send_agent_message_with_id(&svc,auth,inst.agent_instance_id,{body=link_token,artifact_ids_json=json_ids,reply_to_message_id=channel_id},
		linked.reply_message_id,&inst,{channel_id,link_proof})
	if !testing.expect(t,link_saved && link_save_err.code==.None,link_save_err.message) do return
	bots_canonical_egress_tick(s,"telegram",75000)
	testing.expect_value(t,fake.calls,4)
	testing.expect(t,strings.contains(fake.artifact_link,art.artifact_id) && !strings.contains(fake.artifact_link,"web-only attachment bytes"))
	status, _ = repo.channel_reply_state(repo.ctx,link_row.message_id,"alice")
	testing.expect_value(t,status,"sent")

	third, _, third_err := prepare_canonical_reply(s,inst,channel_id)
	if !testing.expect(t,third_err.code==.None && third.reply_message_id!="") do return
	third_body, third_proof, _ := channelvault.seal_authored(third,"leave this on web after opt-out",&f.kr)
	third_row, third_saved, third_save_err := content.send_agent_message_with_id(&svc,auth,inst.agent_instance_id,{body=third_body,reply_to_message_id=channel_id},third.reply_message_id,&inst,{channel_id,third_proof})
	if !testing.expect(t,third_saved && third_save_err.code==.None,third_save_err.message) do return
	_, pause_err := set_web_activation(s,"alice",false,a.generation)
	testing.expect_value(t,pause_err.code,domain.Error_Code.None)
	bots_canonical_egress_tick(s,"telegram",81000)
	testing.expect_value(t,fake.calls,4)
	status, _ = repo.channel_reply_state(repo.ctx,third_row.message_id,"alice")
	testing.expect_value(t,status,"stale")
	stored, kept, _ := iface.content_get_message(&af.repos.content,third_row.message_id)
	testing.expect(t,kept && stored.body==third_body,"opt-out keeps the web reply but fences external egress")
}
