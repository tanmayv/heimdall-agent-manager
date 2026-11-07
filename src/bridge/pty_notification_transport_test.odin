#+build !windows
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:sync"
import "core:strings"
import contracts "odin_test:contracts"

@(test)
pty_notification_transport_distinguishes_receipt_uncertainty_and_unsupported :: proc(t: ^testing.T) {
    path:=fmt.tprintf("/tmp/ham_notification_%d.sock",os.get_pid())
    _=posix.unlink(cstring(raw_data(path)))
    defer _=posix.unlink(cstring(raw_data(path)))
    listener:=posix.socket(.UNIX,.STREAM)
    if !testing.expect(t,listener>=0) do return
    defer posix.close(listener)
    addr:posix.sockaddr_un
    when ODIN_OS==.Darwin || ODIN_OS==.FreeBSD || ODIN_OS==.NetBSD || ODIN_OS==.OpenBSD { addr.sun_len=c.uchar(size_of(addr)) }
    addr.sun_family=.UNIX
    for ch,i in path do addr.sun_path[i]=c.char(ch)
    if !testing.expect(t,posix.bind(listener,(^posix.sockaddr)(&addr),posix.socklen_t(size_of(addr)))==.OK) do return
    if !testing.expect(t,posix.listen(listener,4)==.OK) do return
    Server::struct {listener:posix.FD,frames:[15][]byte}
    server:=Server{listener=listener}
    defer for frame in server.frames do delete(frame,runtime.heap_allocator())
    worker:=thread.create_and_start_with_data(&server,proc(data:rawptr) {
        context.allocator=runtime.heap_allocator()
        s:=(^Server)(data)
        for i in 0..<15 {
            client:=posix.accept(s.listener,nil,nil)
            if client<0 do return
            frame,ok:=pty_host_read_frame(client)
            if ok do s.frames[i]=frame
            if i!=1 {
                p:=make([dynamic]byte)
                if i==6 || i==10 || i==11 {
                    append(&p,PTY_HOST_T_ERROR)
                    pty_host_put_str(&p,"inst")
                    pty_host_put_str(&p,"notification: unsupported_not_delivered" if i==6 else "notification: literal_paste_unsupported_not_delivered" if i==10 else "notification: interrupt_profile_unsupported_not_delivered")
                } else {
                    append(&p,PTY_HOST_T_NOTIFICATION_RECEIPT)
                    pty_host_put_str(&p,"inst")
                    pty_host_put_str(&p,"other" if i==9 else "delivery")
                    pty_host_put_str(&p,"" if i==4 || i==5 else "wrong-ticket" if i==7 else "saved-ticket")
                    append(&p,u8(1) if i==2 || i==3 || i==7 || i==9 || i>=12 else u8(0))
                    pty_host_put_u32(&p,16 if i==3 || i==7 || i==9 || i==12 else 3 if i==2 || i==8 || i==14 else 0)
                    append(&p,u8(1) if i==3 || i==7 || i==9 || i==12 else u8(0))
                    append(&p,u8(2) if i==4 else u8(3) if i==5 else u8(1) if i==3 || i==7 || i==9 || i==12 else u8(0))
                    pty_host_put_str(&p,"" if i==4 || i==5 else "wrong-profile" if i==12 else "readline-keyseq-timeout-v1:50:100")
                    pty_host_put_u32(&p,75 if i==13 || i==14 else 0)
                }
                reply:=pty_host_frame(p[:])
                _=pty_host_send_all(client,reply)
                delete(reply);delete(p)
            }
            posix.close(client)
        }
    })
    defer thread.destroy(worker)
    expected:=[15]Bridge_PTY_Notification_Error{.None,.Transport_Uncertain,.None,.None,.None,.None,.Unsupported_Not_Delivered,.Invalid_Receipt,.Invalid_Receipt,.Invalid_Receipt,.Unsupported_Not_Delivered,.Unsupported_Not_Delivered,.Invalid_Receipt,.None,.Invalid_Receipt}
    intent:=pty_notification_test_intent()
    for i in 0..<15 {
        mode:u8=PTY_NOTIFICATION_DISPATCH
        if i==0 do mode=PTY_NOTIFICATION_PREPARE
        if i==2 || i==4 || i==5 do mode=PTY_NOTIFICATION_QUERY
        result:=bridge_pty_notification_request(path,intent,mode,"" if i==0 else "saved-ticket","" if i==0 else "readline-keyseq-timeout-v1:50:100")
        r,ticket,error:=result.receipt,result.ticket,result.error
        defer delete(ticket)
        defer delete(result.input_profile)
        testing.expect_value(t,error,expected[i])
        if i==3 do testing.expect_value(t,r.status,"delivered")
        if i==4 do testing.expect_value(t,r.status,"recovery_required")
        if i==5 do testing.expect_value(t,r.status,"child_mismatch")
        if i==13 do testing.expect_value(t,result.retry_after_ms,u32(75))
    }
    thread.join(worker)
    for frame,i in server.frames {
        if !testing.expect(t,len(frame)>1) do continue
        testing.expect_value(t,frame[0],u8(PTY_HOST_T_NOTIFICATION))
        if i==0 do testing.expect_value(t,frame[1],u8(PTY_NOTIFICATION_PREPARE))
    }
}

// Malformed authenticated observations must traverse both the local route and
// shared remote-child IPC helper. Authority IDs remain strict and never poison
// another child's profile. NativeProfile tests prove daemon-side invalidation.
@(test)
pty_notification_malformed_lifecycle_reaches_daemon_after_current_child_fences :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator=context.temp_allocator
    saved_config:=bridge_config;defer bridge_config=saved_config
    saved_records:=bridge_local_token_records;defer bridge_local_token_records=saved_records
    bridge_config.local_endpoint_run_dir="/tmp"
    bridge_config.daemon_id=fmt.tprintf("notification-route-%d",os.get_pid())
    path:=pty_host_socket_path()
    _=posix.unlink(cstring(raw_data(path)));defer _=posix.unlink(cstring(raw_data(path)))
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst",token_hash="key",instance_token="assertion~epoch",run_count=1,role=.Agent}
    bridge_local_token_records=make([dynamic]Bridge_Local_Agent_Token_Record)
    append(&bridge_local_token_records,rec)
    listener:=posix.socket(.UNIX,.STREAM)
    if !testing.expect(t,listener>=0) do return
    defer posix.close(listener)
    addr:posix.sockaddr_un
    when ODIN_OS==.Darwin || ODIN_OS==.FreeBSD || ODIN_OS==.NetBSD || ODIN_OS==.OpenBSD {addr.sun_len=c.uchar(size_of(addr))}
    addr.sun_family=.UNIX
    for ch,i in path do addr.sun_path[i]=c.char(ch)
    if !testing.expect(t,posix.bind(listener,(^posix.sockaddr)(&addr),posix.socklen_t(size_of(addr)))==.OK) do return
    if !testing.expect(t,posix.listen(listener,4)==.OK) do return
    Server::struct {listener:posix.FD,frames:[12][]byte}
    server:=Server{listener=listener}
    defer for frame in server.frames do delete(frame,runtime.heap_allocator())
    worker:=thread.create_and_start_with_data(&server,proc(data:rawptr) {
        context.allocator=runtime.heap_allocator()
        s:=(^Server)(data)
        for i in 0..<12 {
            client:=posix.accept(s.listener,nil,nil)
            if client<0 do return
            frame,ok:=pty_host_read_frame(client)
            if ok do s.frames[i]=frame
            p:=make([dynamic]byte)
            if ok && frame[0]==PTY_HOST_T_STARTUP_LAUNCH {
                append(&p,PTY_HOST_T_STARTUP_LAUNCH_REPLY)
                pty_host_put_str(&p,"inst");pty_host_put_i32(&p,42);pty_host_put_str(&p,"key")
            } else {
                append(&p,PTY_HOST_T_NOTIFICATION_SESSION_BOUND);pty_host_put_str(&p,"inst")
            }
            reply:=pty_host_frame(p[:]);_=pty_host_send_all(client,reply)
            delete(reply);delete(p);posix.close(client)
        }
    })
    defer thread.destroy(worker)
    cases:=[4][3]string{{"replacement","","startup"},{"","/native/session.jsonl","startup"},
        {"replacement",strings.repeat("x",4097,context.temp_allocator),"startup"},{"replacement","/native/session.jsonl","invalid source"}}
    for values in cases {
        ev:=contracts.Ext_Event{provider="codex",kind=.Session,session_phase="start",session_id=values[0],transcript_path=values[1],session_source=values[2]}
        bridge_pty_notification_session(rec,ev)
    }
    // Same helper is used after remote bootstrap/directory/exact-child checks.
    for values in cases do testing.expect(t,bridge_pty_notification_bind_session(path,"inst",42,"key","epoch","1",values[0],values[1],values[2]))
    // Invalid authority is still rejected without contacting the daemon.
    testing.expect(t,!bridge_pty_notification_bind_session(path,"inst",42,"","epoch","1","replacement","","startup"))
    thread.join(worker)
    observed:=0
    for frame in server.frames {
        if !testing.expect(t,len(frame)>0) do continue
        if frame[0]!=PTY_HOST_T_NOTIFICATION_SESSION do continue
        off:=1
        inst,_:=pty_host_get_str(frame,&off);pid,_:=pty_host_get_i32(frame,&off)
        key,_:=pty_host_get_str(frame,&off);epoch,_:=pty_host_get_str(frame,&off);count,_:=pty_host_get_str(frame,&off)
        session,_:=pty_host_get_str(frame,&off);native_path,_:=pty_host_get_str(frame,&off);source,_:=pty_host_get_str(frame,&off)
        testing.expect(t,inst=="inst" && pid==42 && key=="key" && epoch=="epoch" && count=="1")
        testing.expect(t,(source=="startup" && session=="replacement" && native_path=="") ||
            (source=="invalid" && session=="" && native_path==""))
        observed+=1
    }
    testing.expect_value(t,observed,8)
}
