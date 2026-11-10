package http

import "core:testing"
import contracts "odin_test:contracts"

// Another paired Bridge of the account reaches the owner-local relay and the
// registry listing (origin/main parity); every lookup stays scoped to the
// token's account, and an agent instance token only relays.
@(test)
owner_local_admits_a_same_account_bridge_token :: proc(t:^testing.T) {
    bridge:=contracts.Auth_Context{kind=.Bridge_Token,user_id="alice",bridge_id="brg_b"}
    testing.expect(t,owner_local_caller_admitted(bridge,true),"bridge token relays")
    testing.expect(t,owner_local_caller_admitted(bridge,false),"bridge token lists the registry")
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{kind=.Bridge_Token,bridge_id="brg_b"},true),"a bridge token without an account is refused")
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{kind=.Bridge_Token,user_id="alice"},false),"a bridge token without a bridge id is refused")
    instance:=contracts.Auth_Context{kind=.Instance_Token,user_id="alice",agent_instance_id="inst_1"}
    testing.expect(t,owner_local_caller_admitted(instance,true))
    testing.expect(t,!owner_local_caller_admitted(instance,false),"an agent token does not list the registry")
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{kind=.Enrollment_Token,user_id="alice"},true))
    testing.expect(t,!owner_local_caller_admitted(contracts.Auth_Context{},true))
}
