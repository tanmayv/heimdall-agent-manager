package main

import "core:encoding/json"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

@(test)
test_catalog_transport_mirror_accepts_pin_and_rejects_bad_recipes :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 defer free_all(context.temp_allocator)
 provider:Bridge_Catalog_Provider
 raw:=`{"provider":"claude","transports":["pty","acp"],"default_transport":"pty","acp_recipe":{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}}`
 testing.expect(t,json.unmarshal_string(raw,&provider)==nil)
 testing.expect(t,bridge_catalog_transport_valid(provider))
 catalog := strings.concatenate({`{"providers":[`,raw,`]}`})
 testing.expect(t,bridge_catalog_transport_shape_valid(catalog))
 fractional,_ := strings.replace_all(catalog,`"protocol_version":1`,`"protocol_version":1.0`)
 testing.expect(t,!bridge_catalog_transport_shape_valid(fractional),"wire protocol_version must be an integer before typed decoding")
 testing.expect_value(t,provider.acp_recipe.env["CLAUDE_AGENT_ACP_PROTOCOL"],"v1")
 provider.acp_recipe.adapter_version="latest"
 testing.expect(t,!bridge_catalog_transport_valid(provider))
 provider.acp_recipe.adapter_version="0.108.0";provider.default_transport="unknown"
 testing.expect(t,!bridge_catalog_transport_valid(provider))
 provider.default_transport="pty";provider.transports=[]string{"pty","pty"}
 testing.expect(t,!bridge_catalog_transport_valid(provider))
 testing.expect(t,bridge_catalog_transport_valid({}),"legacy catalog normalizes to PTY")
 testing.expect(t,!contracts.bridge_supports_acp_runtime(`{"features":["piped_spawn_v1"]}`))
}
