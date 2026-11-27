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
c2_copilot_transport_opt_in_requires_bridge_reported_readiness :: proc(t: ^testing.T) {
 store := Transport_Test_Store{provider="copilot",features=`{"features":["acp_runtime_v1"]}`,transports=`["pty","acp"]`,default_transport="pty",recipe=COPILOT_TRANSPORT_TEST_RECIPE,
  adapter=`{"installed":true,"state":"ready","version":"1.0.120","checked_at":"2026-11-27T00:00:00Z","provider":"copilot","profile":"copilot","runtime_kind":"system","adapter_package":"@github/copilot","adapter_version":"1.0.114"}`}
 repo := iface.Provider_Repository{ctx=&store,get=transport_test_get,get_provider_transport=transport_test_override,list_status=transport_test_status}
 bridges := iface.Bridge_Repository{ctx=&store,get_bridge=transport_test_bridge}
 svc := Provider_Service{repo=&repo,bridges=&bridges}
 selected, err := resolve_runtime_transport(&svc,"bridge","copilot")
 testing.expect(t,err.code==.None && selected=="pty");delete(selected)
 store.override="acp"
 selected,err=resolve_runtime_transport(&svc,"bridge","copilot")
 testing.expect(t,err.code==.None && selected=="acp");delete(selected)
 ready:=store.adapter
 // A user-installed CLI below the minimum is reported outdated by the bridge.
 for raw in ([]string{
  transport_test_replace(transport_test_replace(ready,`"state":"ready"`,`"state":"outdated"`),`"version":"1.0.120"`,`"version":"1.0.91"`),
  transport_test_replace(ready,`"state":"ready"`,`"state":"missing"`),
  transport_test_replace(ready,`"state":"ready"`,`"state":"error"`),
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

// One readiness function (G7): the bridge computes readiness; the hub stores
// its report and classify_acp_availability consumes the reported state, adding
// only what the Hub owns: the catalog recipe, bridge capability, and that the
// report was evaluated against that recipe. Runtime kind and identity are the
// bridge's checks and are not re-derived here.
@(test)
test_acp_readiness_is_the_bridge_reported_verdict :: proc(t: ^testing.T) {
 ACP :: `{"features":["acp_runtime_v1"]}`
 ready :: `{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-19T00:00:00Z","provider":"claude","profile":"claude","runtime_kind":"adapter","adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}`
 for raw in ([]string{
  ready,
  transport_test_replace(ready, `,"runtime_kind":"adapter"`, ``),
  // The bound recipe decides, not the reported CLI/package version.
  transport_test_replace(ready, `"version":"0.108.0","checked_at"`, `"version":"9.9.9","checked_at"`),
  // A pre-R2 bridge (no binding) whose version is the recipe's pin.
  `{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-19T00:00:00Z"}`,
 }) { testing.expectf(t, classify_acp_availability("claude", TRANSPORT_TEST_RECIPE, ACP, raw).reason == .Ready, "%s", raw) }
 // A ready report for another recipe, or without its structure, is outdated.
 for raw in ([]string{
  `{"state":"ready"}`,
  transport_test_replace(ready, `"adapter_version":"0.108.0"`, `"adapter_version":"0.109.0"`),
  transport_test_replace(ready, `"adapter_package":"@agentclientprotocol/claude-agent-acp"`, `"adapter_package":"other"`),
  `{"installed":true,"state":"ready","version":"0.109.0","checked_at":"2026-11-19T00:00:00Z"}`,
  transport_test_replace(ready, `"installed":true`, `"installed":false`),
  transport_test_replace(ready, `"checked_at":"2026-11-19T00:00:00Z"`, `"checked_at":""`),
 }) { testing.expectf(t, classify_acp_availability("claude", TRANSPORT_TEST_RECIPE, ACP, raw).reason == .Adapter_Outdated, "%s", raw) }
 for state in ([]string{"missing", "missing_node", "missing_npm", "outdated", "error", "installing", "not_checked"}) {
  raw := transport_test_replace(ready, `"state":"ready"`, strings.concatenate({`"state":"`, state, `"`}, context.temp_allocator))
  testing.expectf(t, !classify_acp_availability("claude", TRANSPORT_TEST_RECIPE, ACP, raw).available, "%s is not ready", state)
 }
 // Hub-owned facts still gate a ready report.
 testing.expect_value(t, classify_acp_availability("copilot", TRANSPORT_TEST_RECIPE, ACP, ready).reason, contracts.ACP_Availability_Reason.No_Recipe)
 testing.expect_value(t, classify_acp_availability("claude", TRANSPORT_TEST_RECIPE, "", ready).reason, contracts.ACP_Availability_Reason.Unsupported_Bridge)
}

KIRO_TRANSPORT_TEST_RECIPE :: `{"command":"kiro-cli","args":["acp","--agent-engine","v3"],"env":{},"protocol_version":1,"adapter_package":"kiro-cli","adapter_version":"3.5.0"}`

CODEX_TRANSPORT_TEST_RECIPE :: `{"command":"codex","args":["app-server"],"env":{},"protocol_version":1,"adapter_package":"codex","adapter_version":"0.162.0"}`

@(test)
test_runtime_codex_opt_in_requires_system_probe_readiness :: proc(t: ^testing.T) {
 ready :: `{"installed":true,"state":"ready","version":"0.162.0","checked_at":"2026-11-22T00:00:00Z","provider":"codex","profile":"codex","runtime_kind":"system"}`
 store := Transport_Test_Store{provider="codex",features=`{"features":["acp_runtime_v1"]}`,transports=`["pty","acp"]`,default_transport="pty",recipe=CODEX_TRANSPORT_TEST_RECIPE}
 repo := iface.Provider_Repository{ctx=&store,get=transport_test_get,get_provider_transport=transport_test_override,list_status=transport_test_status}
 bridges := iface.Bridge_Repository{ctx=&store,get_bridge=transport_test_bridge}
 svc := Provider_Service{repo=&repo,bridges=&bridges}
 selected, err := resolve_runtime_transport(&svc,"bridge","codex")
 testing.expect(t,err.code==.None && selected=="pty");delete(selected)
 store.override="acp"
 selected,err=resolve_runtime_transport(&svc,"bridge","codex")
 testing.expect(t,err.code==.ACP_Unavailable && selected=="");delete(selected)
 store.adapter=ready
 selected,err=resolve_runtime_transport(&svc,"bridge","codex")
 testing.expect(t,err.code==.None && selected=="acp");delete(selected)
 for raw in ([]string{
  transport_test_replace(ready, `"state":"ready"`, `"state":"error"`),
  transport_test_replace(ready, `"state":"ready"`, `"state":"outdated"`),
  transport_test_replace(ready, `"state":"ready"`, `"state":"missing"`),
 }) {
  store.adapter=raw
  selected,err=resolve_runtime_transport(&svc,"bridge","codex")
  testing.expect(t,err.code==.ACP_Unavailable && selected=="");delete(selected)
 }
 store.adapter=ready;store.features=""
 selected,err=resolve_runtime_transport(&svc,"bridge","codex")
 testing.expect(t,err.code==.ACP_Unavailable && selected=="");delete(selected)
 store.override="pty"
 selected,err=resolve_runtime_transport(&svc,"bridge","codex")
 testing.expect(t,err.code==.None && selected=="pty");delete(selected)
}

@(test)
test_runtime_kiro_readiness_follows_the_bridge_report :: proc(t: ^testing.T) {
 ACP :: `{"features":["acp_runtime_v1"]}`
 ready :: `{"installed":true,"state":"ready","version":"3.5.0","checked_at":"2026-11-21T00:00:00Z","provider":"kiro","profile":"kiro","runtime_kind":"system"}`
 testing.expect(t, classify_acp_availability("kiro", KIRO_TRANSPORT_TEST_RECIPE, ACP, ready).available)
 testing.expect(t, !classify_acp_availability("claude", KIRO_TRANSPORT_TEST_RECIPE, ACP, ready).available)
 testing.expect(t, !classify_acp_availability("kiro", TRANSPORT_TEST_RECIPE, ACP, ready).available)
 // Below the minimum, the bridge reports outdated with the detected version.
 outdated := transport_test_replace(transport_test_replace(ready, `"state":"ready"`, `"state":"outdated"`), `"version":"3.5.0"`, `"version":"3.4.9"`)
 testing.expect_value(t, classify_acp_availability("kiro", KIRO_TRANSPORT_TEST_RECIPE, ACP, outdated).reason, contracts.ACP_Availability_Reason.Adapter_Outdated)
}

@(test)
test_acp_availability_classifies_every_reason_with_its_fix :: proc(t: ^testing.T) {
 ACP :: `{"features":["acp_runtime_v1"]}`
 ready :: `{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-19T00:00:00Z","provider":"claude","profile":"claude","runtime_kind":"adapter"}`
 state_json :: proc(state: string) -> string {
  return strings.concatenate({`{"state":"`,state,`","installed":false,"checked_at":"2026-11-19T00:00:00Z"}`},context.temp_allocator)
 }
 Case :: struct {recipe, features, adapter: string, available: bool, reason, fix: string}
 cases := []Case{
  {TRANSPORT_TEST_RECIPE, ACP, ready, true, "ready", "null"},
  {"", ACP, ready, false, "no_recipe", "null"},
  {COPILOT_TRANSPORT_TEST_RECIPE, ACP, ready, false, "no_recipe", "null"}, // recipe bound to another provider
  // Recipe is checked before the bridge, so a PTY-only provider never asks for a bridge update.
  {"", "", "", false, "no_recipe", "null"},
  {TRANSPORT_TEST_RECIPE, "", ready, false, "unsupported_bridge", `"update_bridge"`},
  {TRANSPORT_TEST_RECIPE, `{"features":["other"],"description":"acp_runtime_v1"}`, ready, false, "unsupported_bridge", `"update_bridge"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("missing"), false, "adapter_missing", `"install_adapter"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("outdated"), false, "adapter_outdated", `"install_adapter"`},
  {TRANSPORT_TEST_RECIPE, ACP, transport_test_replace(ready,`"version":"0.108.0"`,`"version":"0.107.0"`), false, "adapter_outdated", `"install_adapter"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("missing_node"), false, "adapter_missing_node", `"install_adapter"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("missing_npm"), false, "adapter_missing_npm", `"install_adapter"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("error"), false, "adapter_error", `"install_adapter"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("installing"), false, "installing", "null"},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("not_checked"), false, "not_checked", `"check_now"`},
  {TRANSPORT_TEST_RECIPE, ACP, "", false, "not_checked", `"check_now"`},
  {TRANSPORT_TEST_RECIPE, ACP, "not json", false, "not_checked", `"check_now"`},
  {TRANSPORT_TEST_RECIPE, ACP, state_json("bogus"), false, "not_checked", `"check_now"`},
 }
 seen: bit_set[contracts.ACP_Availability_Reason]
 for c, i in cases {
  verdict := classify_acp_availability("claude", c.recipe, c.features, c.adapter)
  seen += {verdict.reason}
  b := strings.builder_make(context.temp_allocator)
  contracts.write_acp_availability_json(&b, verdict)
  want := strings.concatenate({`{"available":`, "true" if c.available else "false", `,"reason":"`, c.reason, `","fix":`, c.fix, `}`}, context.temp_allocator)
  testing.expectf(t, strings.to_string(b) == want, "case %d: got %s want %s", i, strings.to_string(b), want)
 }
 testing.expect_value(t, seen, ~bit_set[contracts.ACP_Availability_Reason]{})
 // A pre-R2 bridge sends no recipe binding. For a System runtime its version is
 // the detected CLI: at or above the minimum stays ready (a Re-check could never
 // change it), below is outdated. Bound (R2) reports ignore that version.
 legacy_kiro :: proc(version: string) -> string {
  return strings.concatenate({`{"installed":true,"state":"ready","checked_at":"2026-11-21T00:00:00Z","version":"`, version, `"}`}, context.temp_allocator)
 }
 testing.expect_value(t, classify_acp_availability("kiro", KIRO_TRANSPORT_TEST_RECIPE, ACP, legacy_kiro("3.12.1")), contracts.acp_availability_for(.Ready))
 testing.expect_value(t, classify_acp_availability("kiro", KIRO_TRANSPORT_TEST_RECIPE, ACP, legacy_kiro("3.5.0")), contracts.acp_availability_for(.Ready))
 testing.expect_value(t, classify_acp_availability("kiro", KIRO_TRANSPORT_TEST_RECIPE, ACP, legacy_kiro("3.4.9")), contracts.acp_availability_for(.Adapter_Outdated))
 testing.expect_value(t, classify_acp_availability("copilot", COPILOT_TRANSPORT_TEST_RECIPE, ACP, legacy_kiro("1.0.130")), contracts.acp_availability_for(.Ready))
 // An unbound adapter report still needs the exact pin.
 testing.expect_value(t, classify_acp_availability("claude", TRANSPORT_TEST_RECIPE, ACP, legacy_kiro("0.109.0")), contracts.acp_availability_for(.Adapter_Outdated))
}

// require_acp_ready is built on the classifier; its error codes and details
// keep their pre-classifier values (UI and the settings auto-install read them).
@(test)
test_require_acp_ready_maps_verdicts_to_unchanged_errors :: proc(t: ^testing.T) {
 store := Transport_Test_Store{features=`{"features":["acp_runtime_v1"]}`,transports=`["pty","acp"]`,default_transport="pty",recipe=TRANSPORT_TEST_RECIPE}
 repo := iface.Provider_Repository{ctx=&store,get=transport_test_get,get_provider_transport=transport_test_override,list_status=transport_test_status}
 bridges := iface.Bridge_Repository{ctx=&store,get_bridge=transport_test_bridge}
 svc := Provider_Service{repo=&repo,bridges=&bridges}
 entry := domain.Provider_Catalog_Entry{provider="claude",acp_recipe_json=TRANSPORT_TEST_RECIPE}
 Case :: struct {features, adapter: string, code: domain.Error_Code, state, message: string}
 for c, i in ([]Case{
  {`{"features":["acp_runtime_v1"]}`, `{"installed":true,"state":"ready","version":"0.108.0","checked_at":"2026-11-19T00:00:00Z"}`, .None, "", ""},
  {"", "", .ACP_Unavailable, "unsupported_bridge", "bridge does not support acp_runtime_v1 and piped hosting"},
  {`{"features":["acp_runtime_v1"]}`, `{"installed":true,"state":"ready","version":"0.1.0","checked_at":"2026-11-19T00:00:00Z"}`, .ACP_Unavailable, "ready", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"missing_npm"}`, .ACP_Unavailable, "missing_npm", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"missing"}`, .ACP_Unavailable, "missing", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"missing_node"}`, .ACP_Unavailable, "missing_node", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"outdated"}`, .ACP_Unavailable, "outdated", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"error"}`, .ACP_Unavailable, "error", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"not_checked"}`, .ACP_Unavailable, "not_checked", "ACP adapter is not ready"},
  {`{"features":["acp_runtime_v1"]}`, `{"state":"installing"}`, .ACP_Installing, "", "ACP adapter installation is in progress"},
 }) {
  store.features = c.features; store.adapter = c.adapter
  err := require_acp_ready(&svc, "bridge", entry)
  testing.expectf(t, err.code == c.code && err.message == c.message, "case %d: %v %s", i, err.code, err.message)
  if c.state != "" do testing.expectf(t, strings.contains(err.details_json, strings.concatenate({`"state":"`, c.state, `"`}, context.temp_allocator)), "case %d: %s", i, err.details_json)
 }
 // No status row for the provider at all.
 store.features = `{"features":["acp_runtime_v1"]}`; store.adapter = ""; store.provider = "codex"
 err := require_acp_ready(&svc, "bridge", entry)
 testing.expect(t, err.code == .ACP_Unavailable && err.message == "ACP adapter has not been checked" && strings.contains(err.details_json, `"state":"not_checked"`), err.message)
}
