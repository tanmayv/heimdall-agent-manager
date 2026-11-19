package provider

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

TRANSPORT_TEST_RECIPE :: `{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}`
COPILOT_TRANSPORT_TEST_RECIPE :: `{"command":"copilot","args":["--acp","--stdio"],"env":{"COPILOT_AUTO_UPDATE":"false"},"protocol_version":1,"adapter_package":"@github/copilot","adapter_version":"1.0.114"}`

Transport_Test_Store :: struct {
 override, features, adapter, transports, recipe, default_transport: string,
 provider: string,
}
transport_test_get :: proc(ctx:rawptr,name:string)->(domain.Provider_Catalog_Entry,bool,domain.Domain_Error) {
 s:=(^Transport_Test_Store)(ctx)
 return {provider=strings.clone(name),state=strings.clone("active"),transports_json=strings.clone(s.transports),default_transport=strings.clone(s.default_transport),acp_recipe_json=strings.clone(s.recipe)},true,{}
}
transport_test_override :: proc(ctx:rawptr,bridge_id,provider:string)->(string,domain.Domain_Error) {
 return strings.clone((^Transport_Test_Store)(ctx).override),{}
}
transport_test_bridge :: proc(ctx:rawptr,id:string)->(domain.Bridge,bool,domain.Domain_Error) {
 return {bridge_id=strings.clone(id),capabilities_json=strings.clone((^Transport_Test_Store)(ctx).features)},true,{}
}
transport_test_status :: proc(ctx:rawptr,id:string)->([dynamic]domain.Bridge_Provider_Status,domain.Domain_Error) {
 items:=make([dynamic]domain.Bridge_Provider_Status)
 s := (^Transport_Test_Store)(ctx)
 name := s.provider if s.provider != "" else "claude"
 append(&items,domain.Bridge_Provider_Status{provider=strings.clone(name),profile_id=strings.clone(name),acp_adapter_json=strings.clone(s.adapter)})
 return items,{}
}

@(test)
c2_copilot_transport_opt_in_requires_native_pinned_readiness :: proc(t: ^testing.T) {
 store := Transport_Test_Store{provider="copilot",features=`{"features":["acp_runtime_v1"]}`,transports=`["pty","acp"]`,default_transport="pty",recipe=COPILOT_TRANSPORT_TEST_RECIPE,
  adapter=`{"installed":true,"state":"ready","version":"1.0.114","checked_at":"2026-11-19T00:00:00Z","provider":"copilot","profile":"copilot","runtime_kind":"native"}`}
 repo := iface.Provider_Repository{ctx=&store,get=transport_test_get,get_provider_transport=transport_test_override,list_status=transport_test_status}
 bridges := iface.Bridge_Repository{ctx=&store,get_bridge=transport_test_bridge}
 svc := Provider_Service{repo=&repo,bridges=&bridges}
 selected, err := resolve_runtime_transport(&svc,"bridge","copilot")
 testing.expect(t,err.code==.None && selected=="pty");delete(selected)
 store.override="acp"
 selected,err=resolve_runtime_transport(&svc,"bridge","copilot")
 testing.expect(t,err.code==.None && selected=="acp");delete(selected)
 ready:=store.adapter
 for raw in ([]string{
  transport_test_replace(ready,`"runtime_kind":"native"`,`"runtime_kind":"adapter"`),
  transport_test_replace(ready,`"version":"1.0.114"`,`"version":"1.0.91"`),
  transport_test_replace(ready,`"provider":"copilot"`,`"provider":"claude"`),
 }) {
  store.adapter=raw
  selected,err=resolve_runtime_transport(&svc,"bridge","copilot")
  testing.expect(t,err.code==.ACP_Unavailable && selected=="");delete(selected)
 }
}

@(test)
test_runtime_transport_resolves_default_override_and_capability_gate :: proc(t:^testing.T) {
 store:=Transport_Test_Store{features=`{"features":["acp_runtime_v1"]}`,transports=`["pty","acp"]`,default_transport="pty",recipe=TRANSPORT_TEST_RECIPE,
 adapter=`{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-18T00:00:00Z"}`}
 repo:=iface.Provider_Repository{ctx=&store,get=transport_test_get,get_provider_transport=transport_test_override,list_status=transport_test_status}
 bridges:=iface.Bridge_Repository{ctx=&store,get_bridge=transport_test_bridge}
 svc:=Provider_Service{repo=&repo,bridges=&bridges}
 transport,err:=resolve_runtime_transport(&svc,"bridge","claude")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,transport,"pty");delete(transport)
 store.override="acp"
 transport,err=resolve_runtime_transport(&svc,"bridge","claude")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,transport,"acp");delete(transport)
 for features in ([]string{"",`{"features":[]}`,`{"features":["other"],"description":"acp_runtime_v1"}`}) {
  store.features=features
  transport,err=resolve_runtime_transport(&svc,"bridge","claude")
  testing.expect_value(t,err.code,domain.Error_Code.ACP_Unavailable)
  delete(transport)
 }
 store.features=`{"features":["acp_runtime_v1"]}`
 for state in ([]string{"missing_node","missing","installing","outdated","error","not_checked"}) {
  store.adapter=strings.concatenate({`{"state":"`,state,`","installed":false,"checked_at":"2026-11-18T00:00:00Z"}`})
  transport,err=resolve_runtime_transport(&svc,"bridge","claude")
  testing.expect_value(t,err.code,domain.Error_Code.ACP_Installing if state=="installing" else domain.Error_Code.ACP_Unavailable)
  delete(transport);delete(store.adapter)
 }
 store.override="pty";store.features="";store.adapter=""
 transport,err=resolve_runtime_transport(&svc,"bridge","claude")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,transport,"pty");delete(transport)
 store.override="unknown"
 _,err=resolve_runtime_transport(&svc,"bridge","claude")
 testing.expect_value(t,err.code,domain.Error_Code.Invalid_Transport)
}

@(test)
test_runtime_transport_rejects_invalid_recipes_and_catalog_membership :: proc(t:^testing.T) {
 entry:=domain.Provider_Catalog_Entry{provider="claude",transports_json=`["pty"]`,default_transport="pty",acp_recipe_json=TRANSPORT_TEST_RECIPE}
 _,err:=provider_transport_from_entry(entry,"acp")
 testing.expect_value(t,err.code,domain.Error_Code.Invalid_Transport)
 entry.transports_json=`["pty","acp"]`
 for recipe in ([]string{
  "", "null", "{}", "[]",
  transport_test_replace(TRANSPORT_TEST_RECIPE,"0.108.0","latest"),
  transport_test_replace(TRANSPORT_TEST_RECIPE,"0.108.0","^0.108.0"),
  transport_test_replace(TRANSPORT_TEST_RECIPE,"claude-agent-acp","sh"),
  transport_test_replace(TRANSPORT_TEST_RECIPE,`"protocol_version":1`,`"protocol_version":1.0`),
 }) {
  entry.acp_recipe_json=recipe
  _,err=provider_transport_from_entry(entry,"acp")
  testing.expect_value(t,err.code,domain.Error_Code.ACP_Unavailable)
 }
 testing.expect(t,contracts.acp_recipe_valid(TRANSPORT_TEST_RECIPE))
}

@(test)
test_transport_catalog_wire_values_change_etag :: proc(t:^testing.T) {
 entries:=make([dynamic]domain.Provider_Catalog_Entry,context.temp_allocator)
 append(&entries,domain.Provider_Catalog_Entry{provider="claude",state="active",base_args_json="[]",yolo_args_json="[]",prompt_args_json="[]",startup_detection_json="{}",activity_detection_json="{}"})
 old_body:=catalog_body_json(entries);defer delete(old_body)
 old_hash:=catalog_body_etag(old_body);defer delete(old_hash)
 entries[0].transports_json=`["pty","acp"]`;entries[0].default_transport="pty";entries[0].acp_recipe_json=TRANSPORT_TEST_RECIPE
 new_body:=catalog_body_json(entries);defer delete(new_body)
 new_hash:=catalog_body_etag(new_body);defer delete(new_hash)
 testing.expect(t,old_hash!=new_hash)
 testing.expect(t,strings.contains(new_body,`"transports":["pty","acp"]`))
 testing.expect(t,strings.contains(new_body,`"acp_recipe":{"command"`))
 testing.expect(t,strings.contains(old_body,`"acp_recipe":null`))
}


transport_test_replace :: proc(input,old,replacement:string)->string {
 value,_:=strings.replace_all(input,old,replacement,context.temp_allocator)
 return value
}

@(test)
test_runtime_descriptor_readiness_rejects_status_identity_substitution :: proc(t: ^testing.T) {
 ready :: `{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-19T00:00:00Z","provider":"claude","profile":"claude","runtime_kind":"adapter"}`
 testing.expect(t, acp_adapter_ready(ready, TRANSPORT_TEST_RECIPE, "claude"))
 testing.expect(t, !acp_adapter_ready(ready, TRANSPORT_TEST_RECIPE, "copilot"))
 for raw in ([]string{
  transport_test_replace(ready, `"provider":"claude"`, `"provider":"copilot"`),
  transport_test_replace(ready, `"profile":"claude"`, `"profile":"work"`),
  transport_test_replace(ready, `"runtime_kind":"adapter"`, `"runtime_kind":"native"`),
  transport_test_replace(ready, `"version":"0.108.0"`, `"version":"0.108.1"`),
 }) { testing.expect(t, !acp_adapter_ready(raw, TRANSPORT_TEST_RECIPE, "claude")) }
}
