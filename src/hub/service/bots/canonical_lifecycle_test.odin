package bots

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content "odin_test:hub/service/content"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

Canonical_Lifecycle_Capture :: struct {
	launches, notices, stops: int,
	launch_id, message_id, notice_bridge, notice_epoch, stop_reason: string,
}

canonical_lifecycle_capture :: proc(raw: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	cap := (^Canonical_Lifecycle_Capture)(raw)
	switch jsonx.extract_string(cmd.body_json,"type",allocator=context.temp_allocator) {
	case "launch_agent":
		cap.launches += 1
		cap.launch_id= strings.clone(jsonx.extract_string(cmd.body_json,"agent_instance_id",allocator=context.temp_allocator))
	case "stop_agent":
		cap.stops += 1
		cap.stop_reason= strings.clone(jsonx.extract_string(cmd.body_json,"reason",allocator=context.temp_allocator))
	case "notify_agent_message":
		cap.notices += 1
		cap.message_id= strings.clone(jsonx.extract_string(cmd.body_json,"message_id",allocator=context.temp_allocator))
		cap.notice_epoch= strings.clone(jsonx.extract_string(cmd.body_json,"expected_launch_epoch",allocator=context.temp_allocator))
		cap.notice_bridge= strings.clone(cmd.bridge_id)
	}
	return true, {}
}

@(test)
test_canonical_lifecycle_starts_once_then_fences_old_ready_replay :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t,&f,true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	state, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code==.None,activation_err.message) do return
	cap: Canonical_Lifecycle_Capture
	sink := project.Bridge_Command_Sink{ctx=&cap,send_runtime_command=canonical_lifecycle_capture}
	f.agent.bridge_command_sink = sink
	f.agent.runtime_policy = {ctx=s,check=check_web_runtime_policy}
	svc := content.Content_Service{content=&f.repos.content,agents=&f.repos.agents,uow_factory=&f.pair.uow,clock=&f.pair.clock,ids=&f.ids,bridge_command_sink=sink}
	auth := contracts.Auth_Context{kind=.Internal_User,user_id="alice"}

	msg, saved, save_err := content.persist_user_message(&svc,auth,state.conversation_id,{body="fixture canonical sealed input"},"msg_canon")
	if !testing.expect(t,saved,save_err.message) do return
	result := deliver_canonical_message(s,&svc,auth,msg,state.generation)
	testing.expect_value(t,result.state,content.Message_Delivery_State.Pending)
	testing.expect_value(t,result.reason,contracts.MESSAGE_DELIVERY_REASON_AGENT_STARTING)
	testing.expect_value(t,cap.launches,1)
	testing.expect_value(t,cap.launch_id,state.agent_instance_id)
	testing.expect_value(t,cap.notices,0)
	old, found, _ := iface.agent_get_instance(&f.repos.agents,state.agent_instance_id)
	if !testing.expect(t,found) do return
	testing.expect(t,old.provider=="beta" && old.model=="m2" && old.runtime_transport=="pty","start preserves the assigned spec")
	// Simulate prior ACP admission without a dispatch. Moving to PTY must
	// make the same ID visible to the destination's ordinary unread inbox.
	testing.expect_value(t,iface.content_save_input_delivery(&f.repos.content,{
		message_id=msg.message_id,conversation_id=msg.conversation_id,owner_user_id="alice",
		agent_instance_id=state.agent_instance_id, launch_epoch="launch_source", state="queued",
		created_at=msg.created_at, updated_at=msg.created_at,
	}).code,domain.Error_Code.None)
	testing.expect_value(t,iface.content_set_message_delivery_flags(&f.repos.content,msg.message_id,"2026-11-28T10:00:00Z",false).code,domain.Error_Code.None)
	// A fenced Ready callback for a different run must be dropped even when
	// the instance and canonical conversation IDs are unchanged.
	query := strings.concatenate({"UPDATE agent_instances SET run_count=run_count+1, launch_epoch='launch_destination', runtime_status='running', startup_status='ready' WHERE agent_instance_id='",state.agent_instance_id,"';"})
	if !testing.expect(t,sqlite.exec(&f.pair.conn,query)) do return
	now, current, _ := iface.agent_get_instance(&f.repos.agents,state.agent_instance_id)
	if !testing.expect(t,current) do return
	replay_canonical_unread(s,&svc,old)
	testing.expect_value(t,cap.notices,0)
	reply_auth := contracts.Auth_Context{kind=.Instance_Token,user_id="alice",agent_instance_id=now.agent_instance_id,bridge_id=now.bridge_id}
	_, late_saved, late_err := content.send_agent_message_with_id(&svc,reply_auth,now.agent_instance_id,{body="old assignment reply"},"msg_late",&old)
	testing.expect(t,!late_saved && late_err.code==.Conflict,"a stale callback cannot persist a reply for channel routing")
	replay_canonical_unread(s,&svc,now)
	testing.expect_value(t,cap.notices,1)
	testing.expect_value(t,cap.message_id,msg.message_id)
	testing.expect_value(t,cap.notice_bridge,now.bridge_id)
	testing.expect_value(t,cap.notice_epoch,now.launch_epoch)
	requeued, admitted, _ := iface.content_get_input_delivery(&f.repos.content,msg.message_id)
	testing.expect(t,admitted && requeued.state=="sent" && requeued.launch_epoch=="","old ACP queued row was safely re-admitted under the same ID")
	rows, rows_err := iface.content_list_messages(&f.repos.content,state.conversation_id,"alice",10,"")
	testing.expect(t,rows_err.code==.None && len(rows)==1 && rows[0].message_id==msg.message_id,"readmission did not insert a second message")
	_, _ = iface.content_mark_messages_read(&f.repos.content,"alice",{msg.message_id},"2026-11-28T10:00:00Z")
	replay_canonical_unread(s,&svc,now)
	testing.expect_value(t,cap.notices,1)
}

@(test)
test_canonical_lifecycle_manual_stop_keeps_input_pending :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t,&f,true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	state, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code==.None,activation_err.message) do return
	query := strings.concatenate({"UPDATE agent_instances SET stopped_by='user', stop_reason='user_requested' WHERE agent_instance_id='",state.agent_instance_id,"';"})
	if !testing.expect(t,sqlite.exec(&f.pair.conn,query)) do return
	cap: Canonical_Lifecycle_Capture
	sink := project.Bridge_Command_Sink{ctx=&cap,send_runtime_command=canonical_lifecycle_capture}
	f.agent.bridge_command_sink = sink
	svc := content.Content_Service{content=&f.repos.content,agents=&f.repos.agents,uow_factory=&f.pair.uow,clock=&f.pair.clock,ids=&f.ids,bridge_command_sink=sink}
	auth := contracts.Auth_Context{kind=.Internal_User,user_id="alice"}
	msg, ok, err := content.persist_user_message(&svc,auth,state.conversation_id,{body="fixture input after stop"},"msg_hold")
	if !testing.expect(t,ok,err.message) do return
	delivery := deliver_canonical_message(s,&svc,auth,msg,state.generation)
	testing.expect_value(t,delivery.state,content.Message_Delivery_State.Pending)
	testing.expect_value(t,delivery.reason,contracts.MESSAGE_DELIVERY_REASON_MANUALLY_STOPPED)
	testing.expect_value(t,cap.launches,0)
	testing.expect_value(t,cap.notices,0)
	saved, have, _ := iface.content_get_message(&f.repos.content,msg.message_id)
	testing.expect(t,have && saved.read_at=="","manual stop preserves committed unread input")
}

@(test)
test_canonical_idle_uses_typed_stop_after_thirty_minutes :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	f: Activation_Fixture
	activation_fixture_open(t,&f,true)
	defer activation_fixture_close(&f)
	s := &f.pair.service
	active, activation_err := set_web_activation(s,"alice",true,0)
	if !testing.expect(t,activation_err.code==.None,activation_err.message) do return
	cap: Canonical_Lifecycle_Capture
	f.agent.bridge_command_sink = {ctx=&cap,send_runtime_command=canonical_lifecycle_capture}
	s.timers = default_bot_timer_config()
	stamp :: "2026-11-28T10:00:00Z"
	query := strings.concatenate({"UPDATE agent_instances SET run_count=1, runtime_status='running', startup_status='ready', activity_status='idle', started_at='",stamp,"' WHERE agent_instance_id='",active.agent_instance_id,"';"})
	if !testing.expect(t,sqlite.exec(&f.pair.conn,query)) do return
	now := bots_stamp_ms(stamp)
	testing.expect_value(t,s.timers.bot_idle_stop_ms,i64(30*60*1000))
	stop_canonical_when_idle(s,"alice",now+30*60*1000-1)
	testing.expect_value(t,cap.stops,0)
	stop_canonical_when_idle(s,"alice",now+30*60*1000)
	testing.expect_value(t,cap.stops,1)
	testing.expect_value(t,cap.stop_reason,"idle_ttl")
}
