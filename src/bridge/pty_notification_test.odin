package main

import "core:strings"
import "core:encoding/json"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

pty_notification_test_intent :: proc() -> contracts.PTY_Notification_Delivery {
    return {protocol_version=1, operation_id="op", delivery_id="delivery", source={agent_instance_id="inst", launch_epoch="epoch", run_count="1"}, pid="42", launch_key="key", message="literal $() text", interrupt=true}
}

@(test)
pty_notification_spawn_fence_tracks_exact_issued_token :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex)
    defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator=context.temp_allocator
    saved:=bridge_local_token_records
    defer bridge_local_token_records=saved
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record)
    append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{agent_instance_id="inst",token_hash=bridge_local_hash_token("old-agent-token"),instance_token="hub-assertion~old-epoch",run_count=1,role=.Agent})
    append(&bridge_local_token_records,Bridge_Local_Agent_Token_Record{agent_instance_id="inst",token_hash=bridge_local_hash_token("new-agent-token"),instance_token="hub-assertion~new-epoch",run_count=2,role=.Agent})
    old_epoch,old_count:=bridge_pty_notification_spawn_fence("inst","old-agent-token")
    testing.expect_value(t,old_epoch,"old-epoch"); testing.expect_value(t,old_count,"1")
    new_epoch,new_count:=bridge_pty_notification_spawn_fence("inst","new-agent-token")
    testing.expect_value(t,new_epoch,"new-epoch"); testing.expect_value(t,new_count,"2")
    profile:=Bridge_Provider_Profile{name="notify-test",command=[]string{"/fake/provider"},model_flag="--model",prompt_delivery="flag-injection",prompt_flags=[]string{"--prompt"},starter_prompt="Read AGENTS.md"}
    req,spawn_ok:=bridge_pty_host_build_spawn_for_profile("inst","/managed/run",profile,"model","old-agent-token",[]string{"HEIMDALL_NOTIFICATION_EPOCH=forged","HEIMDALL_NOTIFICATION_RUN_COUNT=999"})
    defer bridge_pty_host_untrack_instance_provider("inst")
    testing.expect(t,spawn_ok)
    epoch_value,count_value: string
    for pair in req.env {
        if pair[0]=="HEIMDALL_NOTIFICATION_EPOCH" do epoch_value=pair[1]
        if pair[0]=="HEIMDALL_NOTIFICATION_RUN_COUNT" do count_value=pair[1]
    }
    testing.expect_value(t,epoch_value,"old-epoch"); testing.expect_value(t,count_value,"1")
    bridge_local_token_records[0].invalidated_at_unix_ms=1
    epoch,count:=bridge_pty_notification_spawn_fence("inst","old-agent-token")
    testing.expect_value(t,epoch,""); testing.expect_value(t,count,"0")
    epoch,count=bridge_pty_notification_spawn_fence("other","new-agent-token")
    testing.expect_value(t,epoch,""); testing.expect_value(t,count,"0")
}

@(test)
pty_notification_wire_matches_rust_golden :: proc(t: ^testing.T) {
    intent := pty_notification_test_intent()
    frame, ok := pty_notification_encode(intent, PTY_NOTIFICATION_PREPARE, "")
    if !testing.expect(t,ok) do return
    defer delete(frame)
    hex := "0123456789abcdef"
    b := strings.builder_make(context.temp_allocator)
    for c in frame { strings.write_byte(&b,hex[c>>4]); strings.write_byte(&b,hex[c&15]) }
    testing.expect_value(t,strings.to_string(b),strings.trim_space(#load("../../tools/pty_host/fixtures/notification-prepare.hex")))
    invalid := intent; invalid.message="bad\x1b"
    _, valid := pty_notification_encode(invalid,0,""); testing.expect(t,!valid)
    invalid=intent; invalid.pid="2147483648"
    _, valid=pty_notification_encode(invalid,0,""); testing.expect(t,!valid)
    for mode in 1..=2 { _, valid=pty_notification_encode(intent,u8(mode),""); testing.expect(t,!valid) }
    _, valid=pty_notification_encode(intent,0,"old-ticket"); testing.expect(t,!valid)
}

@(test)
pty_notification_shared_unicode_and_control_vectors :: proc(t: ^testing.T) {
    vectors:struct {cases:[]struct {name,message:string,valid:bool}}
    err:=json.unmarshal(transmute([]byte)#load("../../tools/pty_host/fixtures/notification-messages.json"),&vectors,allocator=context.temp_allocator)
    if !testing.expect(t,err==nil) do return
    interrupts:=[2]bool{false,true}
    for c in vectors.cases {
        for interrupt in interrupts {
            intent:=pty_notification_test_intent(); intent.message=c.message; intent.interrupt=interrupt
            testing.expectf(t,contracts.pty_notification_message_valid(c.message)==c.valid,"%s",c.name)
            encoded,ok:=pty_notification_encode(intent,PTY_NOTIFICATION_PREPARE,"")
            testing.expectf(t,ok==c.valid,"%s",c.name)
            if encoded!=nil do delete(encoded)
        }
    }
}

@(test)
pty_notification_reply_is_strict_and_tracks_phases :: proc(t: ^testing.T) {
    p := make([dynamic]byte)
    defer delete(p)
    append(&p,PTY_HOST_T_NOTIFICATION_RECEIPT)
    pty_host_put_str(&p,"inst"); pty_host_put_str(&p,"delivery"); pty_host_put_str(&p,"ticket")
    append(&p,1); pty_host_put_u32(&p,15); append(&p,1,1)
    pty_host_put_str(&p,"readline-keyseq-timeout-v1:50:100"); pty_host_put_u32(&p,0)
    for n in 0..<len(p) {
        r,ok:=pty_host_decode_reply(p[:n]); testing.expect(t,!ok)
        if ok do pty_host_reply_delete(r)
    }
    r,ok:=pty_host_decode_reply(p[:])
    if !testing.expect(t,ok) do return
    defer pty_host_reply_delete(r)
    testing.expect_value(t,r.kind,Pty_Host_Reply_Kind.Notification_Receipt)
    testing.expect_value(t,r.notification_id,"delivery")
    testing.expect_value(t,r.notification_ticket,"ticket")
    testing.expect_value(t,r.notification_bytes,u32(15))
    testing.expect(t,r.notification_esc && r.notification_enter)
    append(&p,0)
    _,extra_ok:=pty_host_decode_reply(p[:]); testing.expect(t,!extra_ok)
    huge:=[]byte{PTY_HOST_T_NOTIFICATION_RECEIPT,255,255,255,255}
    _,huge_ok:=pty_host_decode_reply(huge); testing.expect(t,!huge_ok)
}
