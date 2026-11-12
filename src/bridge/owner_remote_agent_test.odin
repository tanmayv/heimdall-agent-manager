package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import httpc "odin_test:lib/httpc"

// Cross-Bridge relay, sender side (task_18e6b219bcee55fa #7): the owner Bridge
// comes from the account registry rows the Hub returns for this Bridge's
// account, and only account-wide verbs that name a chain or task are relayed;
// every other verb keeps the local route without a Hub round trip.
@(test)
test_owner_remote_agent_registry_match_and_relay_scope :: proc(t:^testing.T) {
    rows:=[]Owner_Remote_Registry_Row{
        {chain_id="chain_a",task_id="",owner_bridge_id="brg_a"},
        {chain_id="chain_a",task_id="task_a1",owner_bridge_id="brg_a"},
        {chain_id="chain_b",task_id="task_b1",owner_bridge_id="brg_b"},
        {chain_id="chain_orphan",task_id="",owner_bridge_id=""},
    }
    owner_bridge,found:=bridge_owner_remote_match(rows,"chain_a","")
    testing.expect(t,found && owner_bridge=="brg_a","a chain row names its owner")
    owner_bridge,found=bridge_owner_remote_match(rows,"chain_a","task_a1")
    testing.expect(t,found && owner_bridge=="brg_a","chain + task resolves to the chain owner")
    owner_bridge,found=bridge_owner_remote_match(rows,"","task_b1")
    testing.expect(t,found && owner_bridge=="brg_b","a task named alone resolves through its task row")
    _,found=bridge_owner_remote_match(rows,"chain_b","task_a1")
    testing.expect(t,!found,"a task of another chain does not match the named chain")
    _,found=bridge_owner_remote_match(rows,"chain_other_account","")
    testing.expect(t,!found,"a chain outside the account listing is unknown (the old route is kept)")
    _,found=bridge_owner_remote_match(rows,"chain_orphan","")
    testing.expect(t,!found,"a row without an owner Bridge never routes")
    _,found=bridge_owner_remote_match(rows,"","")
    testing.expect(t,!found,"no target never matches")

    // Verbs outside the account-wide set, and verbs naming no target, are not
    // relayed: they return handled=false before any registry or Hub call.
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_x",token_hash="hash_x"}
    _,handled:=bridge_owner_remote_agent_send("req_1","agent.lease.submit",`{"chain_id":"chain_a"}`,rec)
    testing.expect(t,!handled,"work lease verbs are not relayed")
    _,handled=bridge_owner_remote_agent_send("req_1b","agent.lease.next",`{}`,rec)
    testing.expect(t,!handled,"lease next naming no chain is not relayed")
    _,handled=bridge_owner_remote_agent_send("req_2","agent.task.create",`{"chain_id":"chain_a"}`,rec)
    testing.expect(t,!handled,"chain changes are not relayed")
    _,handled=bridge_owner_remote_agent_send("req_3","agent.task.show",`{}`,rec)
    testing.expect(t,!handled,"a read naming no chain or task is not relayed")
}

// Gap 5: a relayed review lease's TASK.md text is taken out of the agent's
// reply; with no launch (no run directory) the reply says it was not written.
@(test)
test_owner_remote_review_context_write_strips_the_text :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    response:=bridge_local_response_data("req_1",`{"status":"granted","review_context":"# Owner-local review"}`)
    out:=bridge_owner_result_object(bridge_owner_remote_review_context_write("req_1",response,"inst_not_launched"))
    data,_:=out["data"].(json.Object)
    _,has:=data["review_context"]
    testing.expect(t,!has,"the text is not passed to the agent")
    written,_:=data["review_context_written"].(json.Boolean)
    testing.expect(t,!bool(written),"no run directory: not written")
    testing.expectf(t,strings.contains(string(data["context"].(json.String) or_else ""),"could not be written"),"the reply does not point at an unwritten TASK.md: %v",data)
    none:=bridge_local_response_data("req_2",`{"status":"none"}`)
    testing.expect_value(t,bridge_owner_remote_review_context_write("req_2",none,"inst_x"),none)
}

// run14: B aborted (free(): invalid pointer) because a relayed reply opened
// into the temp allocator was returned to the local endpoint, which deletes
// it with the heap allocator. Both paths now return a heap string.
@(test)
test_owner_remote_review_context_write_returns_a_heap_reply :: proc(t:^testing.T) {
    for body in ([]string{`{"status":"none"}`,`{"status":"granted","review_context":"# Owner-local review"}`}) {
        heap_reply:=bridge_local_response_data("req_1",body)
        plain:=strings.clone(heap_reply,context.temp_allocator)
        delete(heap_reply)
        out:=bridge_owner_remote_review_context_write("req_1",plain,"inst_not_launched")
        testing.expect(t,raw_data(out)!=raw_data(plain),"the reply is a new heap string, not the temp-allocated input")
        delete(out)
    }
}

// Gap 5 on the reviewer's Bridge: a bare `lease next` takes the chain from
// the caller's launch record; only a granted review is taken from the relay.
@(test)
test_owner_remote_bare_lease_next_uses_the_launch_chain :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    instance:=fmt.tprintf("inst_bare_next_%d",time.to_unix_nanoseconds(time.now()))
    defer bridge_runtime_remove_launch(instance)
    chain,params:=bridge_owner_remote_lease_next_chain(bridge_owner_params(`{"peek":false}`),instance)
    testing.expect(t,chain=="" && params=="","no launch record: nothing to relay")
    bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id=instance})
    chain,_=bridge_owner_remote_lease_next_chain(bridge_owner_params(`{}`),instance)
    testing.expect_value(t,chain,"")
    bridge_runtime_record_launch(Bridge_Runtime_Launch{agent_instance_id=instance,chain_id="chain_owned_elsewhere"})
    chain,params=bridge_owner_remote_lease_next_chain(bridge_owner_params(`{"peek":false}`),instance)
    testing.expect_value(t,chain,"chain_owned_elsewhere")
    p:=bridge_owner_params(params)
    testing.expect(t,bridge_owner_pstr(p,"chain_id")=="chain_owned_elsewhere" && "peek" in p,"params keep their fields and name the chain")
    testing.expect(t,bridge_owner_remote_review_granted(bridge_local_response_data("r",`{"status":"granted"}`)))
    testing.expect(t,!bridge_owner_remote_review_granted(bridge_local_response_data("r",`{"status":"none"}`)))
    testing.expect(t,!bridge_owner_remote_review_granted(bridge_local_response_error("r","not_found","x")))
}

// R1 FIX A: one remote reviewer instance per (chain, agent, run Bridge). The
// first dispatch launches it; later ones start it when stopped, wake a live one
// with the review-lease line, and launch anew only when the Hub no longer
// knows it (run8 launched three).
Remote_Reviewer_Call :: struct{path,body,envelope_method:string}
remote_reviewer_calls:[dynamic]Remote_Reviewer_Call
remote_reviewer_start_status:int
remote_reviewer_next_instance:string
// These tests share the process-global Hub hook and the reviewer cache.
remote_reviewer_test_mutex:sync.Mutex

@(test)
test_owner_remote_reviewer_instance_is_reused :: proc(t:^testing.T) {
    sync.mutex_lock(&remote_reviewer_test_mutex);defer sync.mutex_unlock(&remote_reviewer_test_mutex)
    remote_reviewer_calls=make([dynamic]Remote_Reviewer_Call,context.temp_allocator)
    bridge_owner_remote_reviewer_http=proc(path:[]string,body,envelope_method:string,rec:Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
        joined:=""
        for part in path do joined=fmt.tprintf("%s/%s",joined,part)
        append(&remote_reviewer_calls,Remote_Reviewer_Call{joined,body,envelope_method})
        switch {
        case joined=="/api/v1/agent-instances":
            return {status=201,ok=true,body=fmt.tprintf(`{{"data":{{"agent_instance_id":"%s"}}}}`,remote_reviewer_next_instance)}
        case len(joined)>6 && joined[len(joined)-6:]=="/start":
            return {status=remote_reviewer_start_status,ok=true,body=`{}`}
        }
        return {status=200,ok=true,body=`{}`}
    }
    defer bridge_owner_remote_reviewer_http=nil
    defer bridge_owner_remote_reviewer_set("chain_r|agt_rev|brg_b|p|m","")
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_coord"}
    body:=`{"agent_id":"agt_rev","bridge_id":"brg_b","chain_id":"chain_r","model":"m","provider":"p"}`
    line:="[taskv2] New review lease l on task t"

    remote_reviewer_next_instance="inst_rev1"
    testing.expect_value(t,bridge_owner_review_remote_launch(body,"agt_rev",line,rec),"")
    testing.expect_value(t,len(remote_reviewer_calls),1)
    testing.expect_value(t,remote_reviewer_calls[0].path,"/api/v1/agent-instances")

    // A stopped reviewer is started, not launched again.
    remote_reviewer_start_status=202
    testing.expect_value(t,bridge_owner_review_remote_launch(body,"agt_rev",line,rec),"")
    testing.expect_value(t,len(remote_reviewer_calls),2)
    testing.expect_value(t,remote_reviewer_calls[1].path,"/api/v1/agent-instances/inst_rev1/start")

    // A live one gets the review-lease line as an agent message.
    remote_reviewer_start_status=409
    testing.expect_value(t,bridge_owner_review_remote_launch(body,"agt_rev",line,rec),"")
    testing.expect_value(t,len(remote_reviewer_calls),4)
    testing.expect_value(t,remote_reviewer_calls[3].path,"/api/v1/agent-actions/chat/send-to-agent")
    testing.expect_value(t,remote_reviewer_calls[3].envelope_method,"agent.chat.send")
    sent,_:=json.parse_string(remote_reviewer_calls[3].body,allocator=context.temp_allocator)
    testing.expect_value(t,bridge_owner_pstr(sent.(json.Object),"to_instance"),"inst_rev1")
    testing.expect_value(t,bridge_owner_pstr(sent.(json.Object),"body"),line)

    // Another chain's reviewer is its own instance.
    remote_reviewer_next_instance="inst_other"
    testing.expect_value(t,bridge_owner_review_remote_launch(`{"agent_id":"agt_rev","bridge_id":"brg_b","chain_id":"chain_s"}`,"agt_rev",line,rec),"")
    testing.expect_value(t,remote_reviewer_calls[4].path,"/api/v1/agent-instances")
    bridge_owner_remote_reviewer_set("chain_s|agt_rev|brg_b||","")

    // The Hub no longer knows it: a new one is launched and remembered.
    remote_reviewer_start_status=404
    remote_reviewer_next_instance="inst_rev2"
    testing.expect_value(t,bridge_owner_review_remote_launch(body,"agt_rev",line,rec),"")
    testing.expect_value(t,len(remote_reviewer_calls),7)
    testing.expect_value(t,remote_reviewer_calls[6].path,"/api/v1/agent-instances")
    testing.expect_value(t,bridge_owner_remote_reviewer_get("chain_r|agt_rev|brg_b|p|m"),"inst_rev2")

    // A Hub failure on start is reported and the instance kept.
    remote_reviewer_start_status=503
    testing.expect(t,bridge_owner_review_remote_launch(body,"agt_rev",line,rec)!="","a 5xx start is a dispatch failure")
    testing.expect_value(t,bridge_owner_remote_reviewer_get("chain_r|agt_rev|brg_b|p|m"),"inst_rev2")
}

// R1 review finding: a task whose agent_models override selects another
// provider/model is not reviewed by the instance launched with the first
// selection; it gets its own, and each selection keeps reusing its instance.
@(test)
test_owner_remote_reviewer_reuse_matches_selection :: proc(t:^testing.T) {
    sync.mutex_lock(&remote_reviewer_test_mutex);defer sync.mutex_unlock(&remote_reviewer_test_mutex)
    remote_reviewer_calls=make([dynamic]Remote_Reviewer_Call,context.temp_allocator)
    bridge_owner_remote_reviewer_http=proc(path:[]string,body,envelope_method:string,rec:Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
        joined:=""
        for part in path do joined=fmt.tprintf("%s/%s",joined,part)
        append(&remote_reviewer_calls,Remote_Reviewer_Call{joined,body,envelope_method})
        if joined=="/api/v1/agent-instances" {
            p:=bridge_owner_params(body)
            return {status=201,ok=true,body=fmt.tprintf(`{{"data":{{"agent_instance_id":"inst_%s"}}}}`,bridge_owner_pstr(p,"model"))}
        }
        return {status=202,ok=true,body=`{}`}
    }
    defer bridge_owner_remote_reviewer_http=nil
    defer bridge_owner_remote_reviewer_set("chain_m|agt_rev|brg_b|p|m1","")
    defer bridge_owner_remote_reviewer_set("chain_m|agt_rev|brg_b|p|m2","")
    defer bridge_owner_remote_reviewer_set("chain_m|agt_rev|brg_b|q|m2","")
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_coord"}
    line:="[taskv2] New review lease l on task t"
    body:=proc(provider,model:string) -> string {
        return fmt.tprintf(`{{"agent_id":"agt_rev","bridge_id":"brg_b","chain_id":"chain_m","model":"%s","provider":"%s"}}`,model,provider)
    }

    // Task 1 (model m1) launches its reviewer.
    testing.expect_value(t,bridge_owner_review_remote_launch(body("p","m1"),"agt_rev",line,rec),"")
    // Task 2 overrides the model: a reviewer launched with m2, not a start of inst_m1.
    testing.expect_value(t,bridge_owner_review_remote_launch(body("p","m2"),"agt_rev",line,rec),"")
    testing.expect_value(t,len(remote_reviewer_calls),2)
    testing.expect_value(t,remote_reviewer_calls[1].path,"/api/v1/agent-instances")
    testing.expect_value(t,bridge_owner_pstr(bridge_owner_params(remote_reviewer_calls[1].body),"model"),"m2")
    // A provider change is a different selection too.
    testing.expect_value(t,bridge_owner_review_remote_launch(body("q","m2"),"agt_rev",line,rec),"")
    testing.expect_value(t,len(remote_reviewer_calls),3)
    testing.expect_value(t,remote_reviewer_calls[2].path,"/api/v1/agent-instances")
    // Each selection keeps reusing its own instance.
    testing.expect_value(t,bridge_owner_review_remote_launch(body("p","m1"),"agt_rev",line,rec),"")
    testing.expect_value(t,remote_reviewer_calls[3].path,"/api/v1/agent-instances/inst_m1/start")
    testing.expect_value(t,bridge_owner_review_remote_launch(body("p","m2"),"agt_rev",line,rec),"")
    testing.expect_value(t,remote_reviewer_calls[4].path,"/api/v1/agent-instances/inst_m2/start")
    testing.expect_value(t,len(remote_reviewer_calls),5)
}

// R1 review finding: two tasks of one chain dispatch the same remote reviewer
// at once (asynchronous dispatch, per-task back-off). The second waits for
// the first's launch and reuses it: one launch, then a wake of that instance.
remote_reviewer_launches:int
remote_reviewer_wakes:int
remote_reviewer_first_entered:sync.Sema
remote_reviewer_second_entered:sync.Sema
remote_reviewer_release:sync.Sema

@(test)
test_owner_remote_reviewer_concurrent_dispatch_launches_once :: proc(t:^testing.T) {
    sync.mutex_lock(&remote_reviewer_test_mutex);defer sync.mutex_unlock(&remote_reviewer_test_mutex)
    remote_reviewer_launches=0;remote_reviewer_wakes=0
    remote_reviewer_first_entered={};remote_reviewer_second_entered={};remote_reviewer_release={}
    bridge_owner_remote_reviewer_http=proc(path:[]string,body,envelope_method:string,rec:Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
        joined:=""
        for part in path do joined=fmt.tprintf("%s/%s",joined,part)
        switch {
        case joined=="/api/v1/agent-instances":
            if sync.atomic_add(&remote_reviewer_launches,1)==0 {
                // The first launch stalls in the Hub call until released.
                sync.sema_post(&remote_reviewer_first_entered)
                sync.sema_wait(&remote_reviewer_release)
            } else {
                sync.sema_post(&remote_reviewer_second_entered)
            }
            return {status=201,ok=true,body=`{"data":{"agent_instance_id":"inst_once"}}`}
        case len(joined)>6 && joined[len(joined)-6:]=="/start":
            // The first one is live by now.
            return {status=409,ok=true,body=`{}`}
        case joined=="/api/v1/agent-actions/chat/send-to-agent":
            sync.atomic_add(&remote_reviewer_wakes,1)
        }
        return {status=200,ok=true,body=`{}`}
    }
    defer bridge_owner_remote_reviewer_http=nil
    defer bridge_owner_remote_reviewer_set("chain_c|agt_rev|brg_b|p|m","")

    Dispatch :: struct{task:string,ok:bool}
    run :: proc(d:^Dispatch) {
        rec:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_coord"}
        line:=fmt.tprintf("[taskv2] New review lease l on task %s",d.task)
        d.ok=bridge_owner_review_remote_launch(`{"agent_id":"agt_rev","bridge_id":"brg_b","chain_id":"chain_c","model":"m","provider":"p"}`,"agt_rev",line,rec)==""
        free_all(context.temp_allocator)
    }
    first:=Dispatch{task="task_1"};second:=Dispatch{task="task_2"}
    t1:=thread.create_and_start_with_poly_data(&first,run)
    testing.expect(t,sync.sema_wait_with_timeout(&remote_reviewer_first_entered,5*time.Second),"the first dispatch is launching")
    t2:=thread.create_and_start_with_poly_data(&second,run)
    // Unfixed, the second dispatch also sees no reviewer and launches at once;
    // fixed, it waits on the key's acquisition and never gets here.
    second_launched:=sync.sema_wait_with_timeout(&remote_reviewer_second_entered,300*time.Millisecond)
    sync.sema_post(&remote_reviewer_release)
    thread.join(t1);thread.join(t2)
    thread.destroy(t1);thread.destroy(t2)
    testing.expect(t,!second_launched,"the second dispatch did not launch while the first was launching")
    testing.expect(t,first.ok && second.ok,"both dispatches succeed")
    testing.expect_value(t,sync.atomic_load(&remote_reviewer_launches),1)
    testing.expect_value(t,sync.atomic_load(&remote_reviewer_wakes),1)
    testing.expect_value(t,bridge_owner_remote_reviewer_get("chain_c|agt_rev|brg_b|p|m"),"inst_once")
}

// R1 FIX A (REQ-E2E-1 run11): the agent-relay body is one JSON object the Hub
// reads as {chain_id,task_id,request,signature}, never a JSON string literal
// of it (the Hub answered every relay 400 "invalid agent relay").
@(test)
test_owner_remote_relay_body_is_a_json_object :: proc(t:^testing.T) {
    body,is_json:=bridge_owner_remote_relay_body("chain_r","","sealed_text","sig_hex").(httpc.Json_Body)
    if !testing.expect(t,is_json && !body.failed) do return
    parsed:struct{chain_id,task_id,request,signature:string}
    testing.expect(t,json.unmarshal(body.encoded,&parsed,.JSON,context.temp_allocator)==nil,"the Hub's body struct parses it")
    testing.expect_value(t,parsed.chain_id,"chain_r")
    testing.expect_value(t,parsed.request,"sealed_text")
    testing.expect_value(t,parsed.signature,"sig_hex")
}
