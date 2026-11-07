package main

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
bridge_legacy_observation_binds_original_batch_entry_and_synthetic_target :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    parent:=` {"type":"wake_agent","command_id":"parent","chain_id":"chain","payload":{"run":[ { "agent_instance_id":"first","task_id":"task","lease_id":"lease","chain_id":"chain","pack":{"n":9007199254740993} }, {"agent_instance_id":"second","chain_id":"chain"} ]}} `
    origin,ok:=bridge_legacy_wake_entry_observation(parent,0)
    testing.expect(t,ok && origin.version=="1" && origin.entry_index==0)
    testing.expect_value(t,origin.parent_digest,contracts.owner_payload_digest(parent))
    testing.expect_value(t,origin.entry_digest,contracts.owner_payload_digest(`{ "agent_instance_id":"first","task_id":"task","lease_id":"lease","chain_id":"chain","pack":{"n":9007199254740993} }`))
    native:=bridge_wake_launch_command_json("synthetic","first","task","worker","codex","model","agent","name","chain","title","coordinator","project","/repo",lease_id="lease")
    origin.native_command_digest=contracts.owner_payload_digest(native)
    testing.expect(t,bridge_legacy_origin_matches_native(origin,native))
    other,other_ok:=bridge_legacy_wake_entry_observation(parent,1)
    testing.expect(t,other_ok && other.entry_digest!=origin.entry_digest)
    other.native_command_digest=contracts.owner_payload_digest(native)
    testing.expect(t,!bridge_legacy_origin_matches_native(other,native),"batch entry cannot be swapped onto another native target")
    swapped:=origin;swapped.instance="second"
    testing.expect(t,!bridge_legacy_origin_matches_native(swapped,native))
    changed:=strings.concatenate({native," "},context.temp_allocator)
    testing.expect(t,!bridge_legacy_origin_matches_native(origin,changed),"native command digest preserves original bytes too")
    relabeled,_:=strings.replace_all(parent,`"chain_id":"chain","payload"`,`"chain_id":"other","payload"`,context.temp_allocator)
    _,ok=bridge_legacy_wake_entry_observation(relabeled,0)
    testing.expect(t,!ok,"parent and entry chain claims cannot disagree")
    legacy,legacy_ok:=bridge_legacy_wake_entry_observation(`{"type":"wake_agent","payload":{"run":[{"agent_instance_id":"first"}]}}`,0)
    testing.expect(t,legacy_ok && legacy.version=="","old packets remain unproved without disrupting normal launch consent")
    _,ok=bridge_legacy_wake_entry_observation(`{"type":"wake_agent","command_id":"parent","chain_id":"chain","payload":{"run":[{"agent_instance_id":"first","agent_instance_id":"second"}]}}`,0)
    testing.expect(t,!ok,"duplicate target cannot be normalized before observation")
}
