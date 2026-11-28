package bots

import "core:mem/virtual"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"
import vault "odin_test:lib/vault"

@(test)
test_canonical_channel_text_retries_locked_bridge_and_replays_receipt :: proc(t: ^testing.T) {
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
	event := channel.Inbound{kind=.Text,chat_is_private=true,update_key="telegram:test:100",external_chat_id="fake-recipient",
		external_user_id="fake-sender",provider_time=CONVERSION_AT, text=ROUNDTRIP_INPUT}
	old := event
	old.update_key = "telegram:test:99"
	old.provider_time = "2020-01-01T00:00:00Z"
	old_answer, old_err := accept_canonical_channel_text(s,&svc,"telegram",old)
	testing.expect(t,old_answer.disposition==.Handled && old_answer.message_id=="" && old_err.code==.None,"pre-pair event is ignored")
	testing.expect_value(t,f.exchanges,0)
	f.locked=true
	blocked, lock_err := accept_canonical_channel_text(s,&svc,"telegram",event)
	testing.expect_value(t,blocked.disposition,Canonical_Intake_Disposition.Retry)
	testing.expect_value(t,lock_err.code,domain.Error_Code.Vault_Locked)
	rows, rows_err := iface.content_list_messages(&af.repos.content,a.conversation_id,"alice",10,"")
	testing.expect(t,rows_err.code==.None && len(rows)==0,"locked bridge saved neither plaintext nor a partial message")
	f.locked=false
	accepted, accepted_err := accept_canonical_channel_text(s,&svc,"telegram",event)
	if !testing.expect(t,accepted.disposition==.Handled && accepted.message_id!="" && accepted_err.code==.None,accepted_err.message) do return
	converted := f.exchanges
	duplicate, dup_err := accept_canonical_channel_text(s,&svc,"telegram",event)
	testing.expect(t,dup_err.code==.None && duplicate.message_id==accepted.message_id,"retry replays the durable canonical ID")
	testing.expect_value(t,f.exchanges,converted)
	msg, found, read_err := iface.content_get_message(&af.repos.content,accepted.message_id)
	if !testing.expect(t,found && read_err.code==.None,read_err.message) do return
	plain, open_err := vault.open(msg.body,&f.kr)
	testing.expect(t,open_err==.Ok && plain==ROUNDTRIP_INPUT && msg.body!=ROUNDTRIP_INPUT,"only encrypted text is committed")
	origin, origin_err := iface.content_message_origin(&af.repos.content,msg.message_id)
	testing.expect(t,origin_err.code==.None && origin=="telegram/chb_fresh","R7 reads an immutable pairing-specific origin")
}
