package main

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:time"

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
    none:=bridge_local_response_data("req_2",`{"status":"none"}`)
    testing.expect_value(t,bridge_owner_remote_review_context_write("req_2",none,"inst_x"),none)
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
