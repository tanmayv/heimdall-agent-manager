#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// A Bridge-created owner chain driven through the real owner verbs
// (bridge_owner_agent_exec), with the owner key as the test signer and the
// live-child probe answering from review_test_live instead of a PTY host.
Review_Test :: struct {
    store:owner.Store,
    key:contracts.Owner_Verified_Key,
    kr:vault.Vault_Keyring,
    root:string,
}
review_test_live:[dynamic]owner.Child
review_test_nudged:[dynamic]string
review_test_started:[dynamic]string

review_test_child :: proc(instance,agent:string) -> owner.Child {
    return owner.Child{instance,fmt.tprintf("epoch_%s",instance),contracts.owner_payload_digest(instance),1,agent}
}
review_test_probe :: proc(instance:string) -> (owner.Child,bool) {
    for c in review_test_live do if c.instance==instance do return c,true
    return {},false
}
review_test_ctx :: proc(r:^Review_Test,child:owner.Child) -> Owner_Agent_Ctx {
    return Owner_Agent_Ctx{request_id=bridge_owner_fresh_id("req"),store=&r.store,child=child,key=r.key,kr=&r.kr,
        now=time.to_unix_nanoseconds(time.now())/1000000,rec=Bridge_Local_Agent_Token_Record{agent_instance_id=child.instance,role=.Agent,instance_token=fmt.tprintf("token_%s",child.instance)}}
}
// The verb's JSON result ({"ok":true,"data":...} or an error).
review_test_exec :: proc(r:^Review_Test,child:owner.Child,method,params:string) -> (json.Object,Owner_Agent_Ctx) {
    ctx:=review_test_ctx(r,child)
    raw:=bridge_owner_agent_exec(&ctx,method,bridge_owner_params(params))
    if raw=="" && ctx.pending.active do raw=bridge_local_response_data(ctx.request_id,bridge_owner_json(ctx.pending.next))
    return bridge_owner_result_object(raw),ctx
}
review_test_data :: proc(o:json.Object) -> json.Object {
    d,_:=o["data"].(json.Object)
    return d
}
review_test_state :: proc(r:^Review_Test,task:string) -> string {
    rows,_:=owner.query(r.store.db,"SELECT state FROM lifecycle_state WHERE task_id=?",task)
    return rows[0][0] if len(rows)==1 else ""
}

// Worker: claim, acknowledge and submit through the real lease verbs.
review_test_submit :: proc(t:^testing.T,r:^Review_Test,worker:owner.Child) -> (json.Object,Owner_Agent_Ctx) {
    next,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(next)["lease"].(json.Object)
    revision:=contracts.owner_string(lease,"requirements_revision")
    testing.expectf(t,revision!="",`worker claims its task: %v`,next)
    hb,_:=review_test_exec(r,worker,"agent.lease.heartbeat",fmt.tprintf(`{{"acknowledge_requirements_revision":"%s"}}`,revision))
    testing.expectf(t,contracts.owner_string(review_test_data(hb),"acknowledged_requirements_revision")==revision,"worker acknowledges: %v",hb)
    return review_test_exec(r,worker,"agent.lease.submit",`{"summary":"tests pass"}`)
}

review_test_nudge :: proc(instance,line:string) -> bool {
    append(&review_test_nudged,fmt.tprintf("%s %s",instance,line))
    return true
}
review_test_start :: proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    append(&review_test_started,fmt.tprintf("%s %s %s",instance,agent,rec.agent_instance_id))
    append(&review_test_live,review_test_child(strings.clone(instance,context.temp_allocator),strings.clone(agent,context.temp_allocator)))
    return ""
}

// Finding 1/2: a task created with --reviewer A --reviewer B and
// --require-user-approval is submitted; the submit dispatches a review lease to
// both reviewers (one woken live, one started), each reviewer's `lease next`
// returns its review, both approve, the gate still waits on the user, and the
// user's own device review settles it. A second task returns to ready on any
// request_changes.
@(test)
test_owner_review_dispatch_reaches_every_reviewer_end_to_end :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_cfg().daemon_id;bridge_cfg().daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    bridge_owner_review_effects=Owner_Review_Effects{nudge=review_test_nudge,start=review_test_start};bridge_owner_review_sync_effects=true
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    review_test_nudged=make([dynamic]string,context.temp_allocator)
    review_test_started=make([dynamic]string,context.temp_allocator)
    defer {
        bridge_cfg().daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil
        bridge_owner_review_effects={};bridge_owner_review_sync_effects=false
        review_test_live=nil;review_test_nudged=nil;review_test_started=nil
    }
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-review-dispatch-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:="chain_review"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("review chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_review",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,first,second:=review_test_child("inst_w","agt_w"),review_test_child("inst_a","agt_a"),review_test_child("inst_b","agt_b")
    append(&review_test_live,coord,worker,first,second)
    for m in ([3]owner.Child{worker,first,second}) {
        ctx:=review_test_ctx(r,coord)
        joined:=bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code
        testing.expectf(t,joined=="ok","%s joins the chain: %s",m.agent_id,joined)
    }

    create :: proc(t:^testing.T,r:^Review_Test,coord:owner.Child,chain,title:string,user:bool) -> string {
        params:=fmt.tprintf(`{{"chain_id":"%s","title":"%s","brief":{{"goal":"Ship %s","acceptance":["Tests pass"]}},"assignee":"agt_w","reviewers":["agt_a","agt_b"],"requires_user_approval":%v}}`,chain,title,title,user)
        out,_:=review_test_exec(r,coord,"agent.task.create",params)
        task:=contracts.owner_string(review_test_data(out),"task_id")
        testing.expectf(t,task!="","task create with two --reviewer: %v",out)
        return task
    }
    task:=create(t,r,coord,chain,"gated",true)
    if task=="" do return
    st,_,_:=owner.agent_task_state(&r.store,chain,task)
    testing.expect_value(t,len(owner.brief_reviewers(st.brief)),2)
    testing.expect(t,owner.brief_user_approval(&r.store,st.brief),"the brief requires the user")

    // B is stopped: the submit wakes A and starts B, then wakes it.
    for c,i in review_test_live do if c.instance=="inst_b" { ordered_remove(&review_test_live,i);break }
    submitted,sctx:=review_test_submit(t,r,worker)
    dispatched,_:=review_test_data(submitted)["review_dispatch"].(json.Array)
    planned:=[2][3]string{{"agt_a","woken","inst_a"},{"agt_b","starting","inst_b"}}
    testing.expectf(t,len(dispatched)==2,"both reviewers are dispatched: %v",submitted)
    for entry,i in dispatched {
        o,_:=entry.(json.Object)
        testing.expect_value(t,[3]string{contracts.owner_string(o,"agent_id"),contracts.owner_string(o,"action"),contracts.owner_string(o,"instance_id")},planned[i])
    }
    testing.expect_value(t,review_test_state(r,task),"in_review")
    // The coordinator's credential starts the stopped member (none held here: the caller's).
    bridge_owner_review_dispatch(sctx.reviews)
    testing.expect_value(t,len(review_test_started),1)
    testing.expect(t,len(review_test_started)==1 && strings.has_prefix(review_test_started[0],"inst_b agt_b"),"B started")
    testing.expect_value(t,len(review_test_nudged),2)
    order:=[2]string{"inst_a","inst_b"}
    for n,i in review_test_nudged {
        testing.expectf(t,strings.has_prefix(n,order[i]) && strings.contains(n,"New review lease") && strings.contains(n,task),"review lease line %s",n)
    }

    // Each reviewer's lease next returns its review lease; nobody else's does.
    for reviewer in ([2]owner.Child{first,second}) {
        next,nctx:=review_test_exec(r,reviewer,"agent.lease.next","{}")
        d:=review_test_data(next)
        lease,_:=d["lease"].(json.Object)
        testing.expectf(t,contracts.owner_string(d,"status")=="granted" && contracts.owner_string(lease,"role")=="reviewer" && contracts.owner_string(lease,"task_id")==task && contracts.owner_string(lease,"attempt")=="1","%s gets its review lease: %v",reviewer.agent_id,next)
        testing.expectf(t,strings.contains(nctx.review_context.text,"Role: reviewer") && strings.contains(nctx.review_context.text,"Ship gated"),"reviewer TASK.md: %s",nctx.review_context.text)
        // R1 run16: the grant points the reviewer at its freshly written
        // TASK.md, and task show carries the brief it is judged against.
        testing.expectf(t,strings.contains(contracts.owner_string(d,"context"),"TASK.md"),"the grant says to read TASK.md: %v",next)
        shown,_:=review_test_exec(r,reviewer,"agent.task.show",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s"}}`,chain,task))
        shown_task,_:=review_test_data(shown)["task"].(json.Object)
        brief,_:=shown_task["brief"].(json.Object)
        testing.expectf(t,strings.contains(contracts.owner_string(brief,"goal"),"Ship gated"),"task show carries the brief: %v",shown)
    }
    idle,_:=review_test_exec(r,coord,"agent.lease.next","{}")
    testing.expect_value(t,contracts.owner_string(review_test_data(idle),"status"),"none")

    // Both approve; the user's approval is still owed.
    for reviewer in ([2]owner.Child{first,second}) {
        posted,_:=review_test_exec(r,reviewer,"agent.review.post",fmt.tprintf(`{{"task_id":"%s","verdict":"approve"}}`,task))
        testing.expectf(t,contracts.owner_string(review_test_data(posted),"verdict")=="approve","%s approves: %v",reviewer.agent_id,posted)
    }
    testing.expect_value(t,review_test_state(r,task),"in_review")
    done,_:=review_test_exec(r,first,"agent.lease.next","{}")
    testing.expect_value(t,contracts.owner_string(review_test_data(done),"status"),"none")
    // The coordinator's relay never counts as the user...
    relay,_:=review_test_exec(r,coord,"agent.review.post",fmt.tprintf(`{{"task_id":"%s","verdict":"approve","on_behalf_of":"user"}}`,task))
    testing.expectf(t,strings.contains(contracts.owner_string(review_test_data(relay),"note"),"user's own review"),"relay: %v",relay)
    testing.expect_value(t,review_test_state(r,task),"in_review")
    // ...the user's own (device-signed) review does: any paired device of the
    // account, with no per-chain grant (account-level trust).
    dpriv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&dpriv)
    device:=chain_create_test_key(t,&dpriv,"device_user","device_user");device.kind="device"
    after,_,_:=owner.agent_task_state(&r.store,chain,task)
    verdict:=bridge_owner_json(map[string]string{"requirements_revision"=after.requirements_revision,"attempt"=after.attempt,"head"=after.head,"verdict"="approve","summary"="user approves"})
    human:=owner.doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"=chain,"immutable_owner_bridge"="bridge","principal_id"="device_user",
        "operation_id"="op_user","method"="review.post","task_id"=task,"expected_revision"=after.task_revision,"request_expires_ms"=fmt.tprintf("%d",now+300000),
        "payload_digest"=contracts.owner_payload_digest(verdict),"key_id"="device_user","signature"=strings.repeat("0",128,context.temp_allocator)})
    sig,_:=chain_create_test_sign(&dpriv,"command",human);human["signature"]=json.String(sig)
    user:=owner.execute(&r.store,bridge_owner_json(human),verdict,g,device,r.key,0,"",time.to_unix_nanoseconds(time.now())/1000000,&r.kr,signer)
    testing.expect_value(t,user.code,"ok")
    testing.expect_value(t,review_test_state(r,task),"done")

    // Any request_changes returns the task to ready, and to its worker.
    clear(&review_test_nudged)
    other:=create(t,r,coord,chain,"ungated",false)
    if other=="" do return
    _,octx:=review_test_submit(t,r,worker)
    bridge_owner_review_dispatch(octx.reviews)
    testing.expect_value(t,len(review_test_nudged),2)
    // Without --task a reviewer posts on the review it owes.
    approved,_:=review_test_exec(r,first,"agent.review.post",`{"verdict":"approve"}`)
    testing.expectf(t,contracts.owner_string(review_test_data(approved),"verdict")=="approve","%v",approved)
    testing.expect_value(t,review_test_state(r,other),"in_review")
    posted,_:=review_test_exec(r,second,"agent.review.post",fmt.tprintf(`{{"task_id":"%s","verdict":"request_changes","summary":"the zero case crashes"}}`,other))
    testing.expectf(t,contracts.owner_string(review_test_data(posted),"verdict")=="request_changes","%v",posted)
    testing.expect_value(t,review_test_state(r,other),"ready")
    late,_:=review_test_exec(r,first,"agent.lease.next","{}")
    testing.expect_value(t,contracts.owner_string(review_test_data(late),"status"),"none")
    again,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(again)["lease"].(json.Object)
    testing.expectf(t,contracts.owner_string(lease,"task_id")==other && contracts.owner_string(lease,"role")=="","the worker reclaims the task: %v",again)
}
