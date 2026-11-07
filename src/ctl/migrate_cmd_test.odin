package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// ham-ctl only transports a browser-signed request; it refuses a request that
// is not for the chain and owner named on the command line.
@(test)
ctl_migration_request_binds_chain_owner_and_genesis :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    zeros:=strings.repeat("0",128)
    selection:=fmt.tprintf(`{{"protocol_version":"1","account_id":"acct","chain_id":"chain_1","migration_id":"mig_1","owner_bridge_id":"brg_1","owner_key_id":"key_1","principal_id":"dev_1","key_id":"dev_1","expected_work_revision":"3","request_expires_ms":"1000","signature":"%s"}}`,zeros)
    genesis:=fmt.tprintf(`{{"protocol_version":"1","account_id":"acct","chain_id":"chain_1","creation_op":"mig_1","owner_bridge_id":"brg_1","owner_key_id":"key_1","creator_id":"dev_1","creator_key_id":"dev_1","schema_version":"1","creator_signature":"%s","owner_signature":"%s"}}`,zeros,zeros)
    raw,_:=json.marshal(Ctl_Migration_Request{selection,genesis},allocator=context.temp_allocator)
    _,ok:=ctl_migration_request_parse(string(raw),"chain_1","brg_1")
    testing.expect(t,ok)
    _,ok=ctl_migration_request_parse(string(raw),"chain_2","brg_1")
    testing.expect(t,!ok,"another chain")
    _,ok=ctl_migration_request_parse(string(raw),"chain_1","brg_2")
    testing.expect(t,!ok,"another owner Bridge")
    other,_:=strings.replace(genesis,`"creation_op":"mig_1"`,`"creation_op":"mig_2"`,1)
    raw,_=json.marshal(Ctl_Migration_Request{selection,other},allocator=context.temp_allocator)
    _,ok=ctl_migration_request_parse(string(raw),"chain_1","brg_1")
    testing.expect(t,!ok,"genesis must be created by this migration")
    _,ok=ctl_migration_request_parse(`{"selection":"{}","genesis":"{}"}`,"chain_1","brg_1")
    testing.expect(t,!ok)
}
