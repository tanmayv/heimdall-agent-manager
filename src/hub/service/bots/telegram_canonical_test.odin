package bots

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"
import vault "odin_test:lib/vault"

Canonical_Poll_Fake :: struct {
	events: [2]channel.Inbound,
	reactions: [dynamic]string,
	failed_media: bool,
}

canonical_fake_poll :: proc(raw:rawptr,cursor:string,cancel:^bool,allocator:=context.allocator) -> ([]channel.Inbound,string,channel.Channel_Error) {
	f := (^Canonical_Poll_Fake)(raw)
	if cursor=="43" do return nil,strings.clone(cursor,allocator),{}
	batch := make([]channel.Inbound,len(f.events),allocator)
	for source,i in f.events {
		dest := source
		dest.update_key=strings.clone(source.update_key,allocator)
		dest.external_chat_id=strings.clone(source.external_chat_id,allocator)
		dest.external_message_id=strings.clone(source.external_message_id,allocator)
		dest.external_user_id=strings.clone(source.external_user_id,allocator)
		dest.provider_time=strings.clone(source.provider_time,allocator)
		dest.text=strings.clone(source.text,allocator)
		dest.media.file_ref=strings.clone(source.media.file_ref,allocator)
		dest.media.mime=strings.clone(source.media.mime,allocator)
		batch[i]=dest
	}
	return batch,strings.clone("43",allocator),{}
}

CANONICAL_MEDIA_PAYLOAD := [?]byte{0xff,0x00,0x13,0x91,0x2a}
canonical_fake_media :: proc(raw:rawptr, ref: string, limit: i64,allocator:=context.allocator) -> (channel.Fetched_Media,channel.Channel_Error) {
	f := (^Canonical_Poll_Fake)(raw)
	if f.failed_media do return {},{kind=.Transient}
	if ref!="verified-fake-file" || limit<i64(len(CANONICAL_MEDIA_PAYLOAD)) do return {},{kind=.Invalid_Request}
	b := make([]byte,len(CANONICAL_MEDIA_PAYLOAD),allocator)
	copy(b,CANONICAL_MEDIA_PAYLOAD[:])
	return {bytes=b,mime=strings.clone("application/pdf",allocator)},{}
}

canonical_fake_react :: proc(raw:rawptr,chat,id,emoji:string) -> channel.Channel_Error {
	f := (^Canonical_Poll_Fake)(raw)
	if chat!="fake-recipient" || id!="77" do return {kind=.Invalid_Request}
	append(&f.reactions,strings.clone(emoji,context.temp_allocator))
	return {}
}

@(test)
test_canonical_telegram_poller_keeps_mixed_owner_cursor_and_seals_media :: proc(t:^testing.T) {
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
	svc := content.Content_Service{content=&af.repos.content,agents=&af.repos.agents,uow_factory=&af.pair.uow,clock=&af.pair.clock,ids=&af.ids}
	s.canonical_telegram=true
	s.canonical_content=&svc
	fake := Canonical_Poll_Fake{events={
		{kind=.Media,chat_is_private=true,update_key="telegram:1:41",external_chat_id="fake-recipient",external_message_id="77",external_user_id="fake-sender",
			provider_time=CONVERSION_AT,text="PDF caption",media={kind=.Document,file_ref="verified-fake-file",mime="application/pdf",size=5}},
		{kind=.Text,chat_is_private=true,update_key="telegram:1:42",external_chat_id="legacy-chat",external_user_id="legacy-sender",
			provider_time=CONVERSION_AT,text="legacy owner should not advance alone"},
	}}
	s.adapter.ctx=&fake
	s.adapter.poll=canonical_fake_poll
	s.adapter.media_fetch=canonical_fake_media
	s.adapter.react=canonical_fake_react
	repo := &af.repos.bots
	timers := default_bot_timer_config()
	s.timers=timers
	_, flag_err := iface.experiment_set(s.experiments,{owner_user_id="bob",key="bots",enabled=true,updated_at=CONVERSION_AT})
	testing.expect_value(t,flag_err.code,domain.Error_Code.None)
	testing.expect_value(t,iface.bot_insert(repo,{bot_id="bot_legacy",agent_id="agt_legacy",owner_user_id="bob",created_at=CONVERSION_AT,updated_at=CONVERSION_AT}).code,domain.Error_Code.None)
	testing.expect_value(t,iface.pairing_insert(repo,{code_hash="legacy-hash",owner_user_id="bob",bot_id="bot_legacy",provider="telegram",created_at=CONVERSION_AT,expires_at="2027-01-01"}).code,domain.Error_Code.None)
	_, _, legacy_err := iface.binding_activate(repo,{binding_id="chb_legacy",owner_user_id="bob",bot_id="bot_legacy",provider="telegram",
		external_chat_id="legacy-chat",external_user_id="legacy-sender",state=.Active,created_at=CONVERSION_AT},"legacy-hash",CONVERSION_AT)
	testing.expect_value(t,legacy_err.code,domain.Error_Code.None)
	rt:=Bots_Runtime{service=s}
	backoff:=time.Second
	f.locked=true
	delay, aborted := bots_poller_iteration(&rt,&backoff)
	testing.expect(t,!aborted && delay>0,"an unavailable owner vault withholds the whole batch")
	cursor, cursor_found, cursor_err := iface.cursor_get(repo,"telegram")
	testing.expect(t,cursor_err.code==.None && !cursor_found && cursor=="")
	legacy, _ := iface.messages_pending(repo,"bot_legacy",-1)
	testing.expect_value(t,len(legacy),0)
	f.locked=false
	delay, aborted = bots_poller_iteration(&rt,&backoff)
	testing.expect(t,!aborted && delay==0)
	cursor, cursor_found, cursor_err = iface.cursor_get(repo,"telegram")
	testing.expect(t,cursor_found && cursor_err.code==.None && cursor=="43")
	legacy, _ = iface.messages_pending(repo,"bot_legacy",-1)
	testing.expect_value(t,len(legacy),1)
	rows, rows_err := iface.content_list_messages(&af.repos.content,a.conversation_id,"alice",10,"")
	if !testing.expect(t,rows_err.code==.None && len(rows)==1,rows_err.message) do return
	caption, open_err := vault.open(rows[0].body,&f.kr)
	testing.expect(t,open_err==.Ok && caption=="PDF caption","the caption is sealed independently")
	ids: []string
	if !testing.expect(t,json.unmarshal_string(rows[0].artifact_ids_json,&ids)==nil && len(ids)==1,"canonical attachment is present") do return
	art, found, art_err := iface.content_get_artifact(&af.repos.content,ids[0])
	if !testing.expect(t,found && art_err.code==.None,art_err.message) do return
	body, body_err := vault.open(art.content,&f.kr)
	testing.expect(t,body_err==.Ok && body==string(CANONICAL_MEDIA_PAYLOAD[:]) && art.mime=="application/pdf","real bridge sealing keeps the original binary bytes")
	bots_canonical_feedback_tick(s,"telegram")
	testing.expect(t,len(fake.reactions)==1 && fake.reactions[0]==bots_queued_reaction("telegram"))
	auth := contracts.Auth_Context{kind=.Instance_Token,user_id="alice",agent_instance_id=a.agent_instance_id}
	for _ in 0..<2 {
		consume_err := content.note_agent_consumed(&svc,auth,a.agent_instance_id,{rows[0].message_id},domain.INPUT_CONSUMED_READ)
		testing.expect_value(t,consume_err.code,domain.Error_Code.None)
		bots_canonical_feedback_tick(s,"telegram")
	}
	testing.expect(t,len(fake.reactions)==2 && fake.reactions[1]==BOT_READ_REACTION,"a durable first consumption reacts exactly once")
	_, _ = bots_poller_iteration(&rt,&backoff)
	repeated, _ := iface.content_list_messages(&af.repos.content,a.conversation_id,"alice",10,"")
	testing.expect_value(t,len(repeated),1)
}

@(test)
test_canonical_telegram_pairing_requires_new_code_and_fences_same_second_updates :: proc(t:^testing.T) {
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
	now := pairing_test_clock(nil)
	if !make_conversion_binding(t,af,"chb_legacy","telegram",0,false) do return
	a, err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,err.code==.None,err.message) do return
	_, disabled_err := bots_pairing_create(s,"alice","telegram")
	testing.expect_value(t,disabled_err.code,domain.Error_Code.Conflict)
	s.canonical_telegram=true
	svc := content.Content_Service{content=&af.repos.content,agents=&af.repos.agents,uow_factory=&af.pair.uow,clock=&af.pair.clock,ids=&af.ids}
	s.canonical_content=&svc
	link, link_err := bots_pairing_create(s,"alice","telegram")
	if !testing.expect(t,link_err.code==.None,link_err.message) do return
	prefix := "?start="
	i := strings.index(link.pairing_url,prefix)
	if !testing.expect(t,i>=0) do return
	code := link.pairing_url[i+len(prefix):]
	pair := channel.Inbound{kind=.Start,text=code,chat_is_private=true,update_key="telegram:1:40",external_chat_id="fake-recipient",
		external_user_id="fake-sender",provider_time=now}
	remaining, pair_err := bots_telegram_canonical_batch(s,{pair},now)
	if !testing.expect(t,len(remaining)==0 && pair_err.code==.None,pair_err.message) do return
	binding, bound, bind_err := iface.binding_get_active_by_owner(&af.repos.bots,"alice","telegram")
	if !testing.expect(t,bound && bind_err.code==.None && binding.binding_id!="chb_legacy",bind_err.message) do return
	grant, granted, grant_err := iface.bot_channel_conversion_binding_get(&af.repos.bots,binding.binding_id)
	testing.expect(t,granted && grant_err.code==.None && grant.pairing_update_key==pair.update_key && grant.activation_generation==a.generation)
	event := pair
	event.kind=.Text
	event.text="old update with the same second"
	event.update_key="telegram:1:39"
	ignored, ignored_err := accept_canonical_channel_text(s,&svc,"telegram",event)
	testing.expect(t,ignored_err.code==.None && ignored.disposition==.Handled && ignored.message_id=="")
	event.update_key="telegram:1:41"
	fresh, fresh_err := accept_canonical_channel_text(s,&svc,"telegram",event)
	testing.expect(t,fresh_err.code==.None && fresh.message_id!="",fresh_err.message)
	rows, read_err := iface.content_list_messages(&af.repos.content,a.conversation_id,"alice",10,"")
	testing.expect(t,read_err.code==.None && len(rows)==1)
}
