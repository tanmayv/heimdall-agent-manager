package main

import "core:testing"

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
    _,handled:=bridge_owner_remote_agent_send("req_1","agent.lease.next",`{"chain_id":"chain_a"}`,rec)
    testing.expect(t,!handled,"lease verbs are not relayed")
    _,handled=bridge_owner_remote_agent_send("req_2","agent.task.create",`{"chain_id":"chain_a"}`,rec)
    testing.expect(t,!handled,"chain changes are not relayed")
    _,handled=bridge_owner_remote_agent_send("req_3","agent.task.show",`{}`,rec)
    testing.expect(t,!handled,"a read naming no chain or task is not relayed")
}
