package provider

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Provider_Settings_Update :: struct {
 has_enabled, enabled, has_transport: bool,
 transport, profile_id: string, // empty transport clears the override
}

provider_transport_from_entry :: proc(entry: domain.Provider_Catalog_Entry, override: string) -> (string, domain.Domain_Error) {
 transport := override
 if transport=="" do transport=contracts.runtime_transport_or_pty(entry.default_transport)
 if !contracts.provider_supports_transport(entry.transports_json,transport) do return "",domain.domain_error(.Invalid_Transport,"transport is not supported by this provider")
 if transport=="acp" && !contracts.acp_provider_recipe_valid(entry.provider, entry.acp_recipe_json) do return "",domain.domain_error(.ACP_Unavailable,"provider ACP recipe is invalid")
 return strings.clone(transport),{}
}

// Settings status describes the current selection. A launch separately checks
// live bridge capability and adapter readiness immediately before freezing it.
//
// Precedence (highest first):
//   1. instance_override: one agent instance's explicit choice ("pty" | "acp"),
//      set through instance reconfiguration (agent_instances.runtime_transport_override);
//   2. the bridge-wide provider setting (bridge_provider_settings transport);
//   3. the catalog default_transport.
// Every source passes the same catalog support/recipe and ACP readiness checks.
resolve_runtime_transport :: proc(service: ^Provider_Service, bridge_id, provider: string, instance_override: string = "") -> (string, domain.Domain_Error) {
 if instance_override!="" && !contracts.runtime_transport_valid(instance_override) do return "",domain.domain_error(.Invalid_Transport,"runtime_transport must be 'pty' or 'acp'")
 entry,found,err:=iface.provider_catalog_get(service.repo,provider)
 if err.code!=.None do return "",err
 if !found || entry.state!="active" do return "",domain.domain_error(.Unprocessable_Entity,"provider is unknown or deprecated")
 defer domain.provider_catalog_entry_destroy(entry)
 override:=strings.clone(instance_override)
 if instance_override=="" {
  read_err: domain.Domain_Error
  override,read_err=iface.get_provider_transport(service.repo,bridge_id,provider)
  if read_err.code!=.None do return "",read_err
 }
 defer delete(override)
 transport,terr:=provider_transport_from_entry(entry,override)
 if terr.code!=.None do return "",terr
 if transport=="acp" {
  if ready_err:=require_acp_ready(service,bridge_id,entry);ready_err.code!=.None {delete(transport);return "",ready_err}
 }
 return transport,{}
}

require_acp_ready :: proc(service: ^Provider_Service, bridge_id: string, entry: domain.Provider_Catalog_Entry) -> domain.Domain_Error {
 bridge,found,err:=iface.bridge_get_bridge(service.bridges,bridge_id)
 if err.code!=.None do return err
 if !found do return domain.domain_error(.Not_Found,"bridge not found")
 defer domain.bridge_destroy(&bridge)
 adapter_json:=""
 has_status:=false
 // Only bridges that support ACP need their adapter status read.
 if contracts.bridge_supports_acp_runtime(bridge.capabilities_json) {
  statuses,serr:=iface.bridge_provider_status_list(service.repo,bridge_id)
  if serr.code!=.None do return serr
  defer domain.bridge_provider_statuses_destroy(statuses)
  for status in statuses {
   if status.provider!=entry.provider || domain.profile_effective_id(status.provider,status.profile_id)!=entry.provider do continue
   adapter_json=strings.clone(status.acp_adapter_json,context.temp_allocator)
   has_status=true
   break
  }
 }
 verdict:=classify_acp_availability(entry.provider,entry.acp_recipe_json,bridge.capabilities_json,adapter_json)
 return acp_availability_error(entry.provider,verdict,adapter_json,has_status)
}

// classify_acp_availability is the Hub's single ACP verdict. It is pure: the
// provider-status view and every launch/settings gate (require_acp_ready) call
// it with the catalog recipe, the bridge's capabilities_json and the
// provider-wide adapter report ("" when the bridge has no status row).
//
// Readiness itself is the Bridge's verdict: it detects Node.js, npm, the CLI
// version (against the same compiled minimum), the package tree and the probe
// receipt live and reports state "ready" only when it can launch, after
// matching the catalog recipe against its own descriptor. The Hub adds only
// the facts it owns (a valid catalog recipe, bridge ACP support, and that the
// report was evaluated against this catalog recipe) and never re-derives it.
classify_acp_availability :: proc(provider, recipe_json, bridge_capabilities_json, adapter_json: string) -> contracts.ACP_Availability {
 if !contracts.acp_provider_recipe_valid(provider,recipe_json) do return contracts.acp_availability_for(.No_Recipe)
 if !contracts.bridge_supports_acp_runtime(bridge_capabilities_json) do return contracts.acp_availability_for(.Unsupported_Bridge)
 switch acp_adapter_state(adapter_json) {
 case "ready":
  // A ready report evaluated against another recipe needs a Re-check/install.
  if !acp_report_binds_recipe(adapter_json,recipe_json) do return contracts.acp_availability_for(.Adapter_Outdated)
  return contracts.acp_availability_for(.Ready)
 case "installing": return contracts.acp_availability_for(.Installing)
 case "missing": return contracts.acp_availability_for(.Adapter_Missing)
 case "missing_node": return contracts.acp_availability_for(.Adapter_Missing_Node)
 case "missing_npm": return contracts.acp_availability_for(.Adapter_Missing_Npm)
 case "error": return contracts.acp_availability_for(.Adapter_Error)
 case "outdated": return contracts.acp_availability_for(.Adapter_Outdated)
 }
 return contracts.acp_availability_for(.Not_Checked)
}

// acp_report_binds_recipe checks a ready report's minimal structure (installed,
// checked_at) and the recipe binding it carries (adapter_package and
// adapter_version, sent since R2) against the catalog recipe. A report from a
// pre-R2 bridge has no binding; its "version" is then accepted only when it
// equals the recipe's adapter_version, which is exactly what those bridges
// pinned for adapters (a system CLI must sit at the minimum itself, so such
// bridges are best updated). Mismatches classify as adapter_outdated.
acp_report_binds_recipe :: proc(adapter_json, recipe_json: string) -> bool {
 recipe: contracts.ACP_Recipe
 if json.unmarshal_string(recipe_json,&recipe,allocator=context.temp_allocator)!=nil || recipe.adapter_version=="" do return false
 value,err:=json.parse_string(adapter_json,allocator=context.temp_allocator)
 if err!=nil do return false
 obj,ok:=value.(json.Object)
 if !ok do return false
 installed,iok:=obj["installed"].(json.Boolean)
 checked,cok:=obj["checked_at"].(json.String)
 if !iok || !bool(installed) || !cok || checked=="" do return false
 if version,bound:=obj["adapter_version"].(json.String);bound {
  pkg,_:=obj["adapter_package"].(json.String)
  return string(version)==recipe.adapter_version && string(pkg)==recipe.adapter_package
 }
 legacy,lok:=obj["version"].(json.String)
 return lok && string(legacy)==recipe.adapter_version
}

// acp_availability_error maps a verdict to the launch/settings error. Error
// codes and details are unchanged from before the classifier existed: the
// detail state is the raw adapter state.
acp_availability_error :: proc(provider: string, verdict: contracts.ACP_Availability, adapter_json: string, has_status: bool) -> domain.Domain_Error {
 switch verdict.reason {
 case .Ready: return {}
 case .No_Recipe: return domain.domain_error(.ACP_Unavailable,"provider ACP recipe is invalid")
 case .Unsupported_Bridge: return acp_unavailable_error(provider,"unsupported_bridge","bridge does not support acp_runtime_v1 and piped hosting")
 case .Installing: return domain.domain_error(.ACP_Installing,"ACP adapter installation is in progress")
 case .Not_Checked:
  // A missing status row and a present-but-unchecked report keep their
  // historical messages.
  if !has_status do return acp_unavailable_error(provider,"not_checked","ACP adapter has not been checked")
 case .Adapter_Missing,.Adapter_Outdated,.Adapter_Missing_Node,.Adapter_Missing_Npm,.Adapter_Error:
 }
 // The HTTP settings handler starts a tracked install for installable states
 // while keeping the settings unchanged until adapter readiness is verified.
 return acp_unavailable_error(provider,acp_adapter_state(adapter_json),"ACP adapter is not ready")
}

update_bridge_provider_settings :: proc(service: ^Provider_Service, bridge: domain.Bridge, provider, now: string, input: Provider_Settings_Update) -> domain.Domain_Error {
 if !input.has_enabled && !input.has_transport do return domain.domain_error(.Validation_Failed,"enabled or transport is required")
 profile:=domain.profile_effective_id(provider,input.profile_id)
 if input.has_transport && profile!=provider do return domain.domain_error(.Transport_Is_Provider_Wide,"transport is configured per provider, not per profile")
 if input.has_transport && input.transport!="" && !contracts.runtime_transport_valid(input.transport) do return domain.domain_error(.Invalid_Transport,"transport must be pty, acp or null")
 entry,found,err:=iface.provider_catalog_get(service.repo,provider)
 if err.code!=.None do return err
 if !found || entry.state!="active" do return domain.domain_error(.Unprocessable_Entity,"provider is unknown or deprecated")
 defer domain.provider_catalog_entry_destroy(entry)
 // Transport-only saves are provider-wide even if the canonical profile is
 // disabled or missing. Enable updates keep their existing profile validation.
 if input.has_enabled {
  if e:=validate_profile(service.repo,bridge.bridge_id,provider,profile);e.code!=.None do return e
 }
 if input.has_transport && input.transport!="" {
  selected,terr:=provider_transport_from_entry(entry,input.transport)
  if terr.code!=.None do return terr
  delete(selected)
  // Offline saves are allowed. Clearing/reverting never needs readiness.
  if input.transport=="acp" && bridge.status==.Online {
   if e:=require_acp_ready(service,bridge.bridge_id,entry);e.code!=.None do return e
  }
 }
 if !input.has_transport {
  _,_,save_err:=set_bridge_provider_enabled(service,bridge.bridge_id,provider,now,input.enabled,profile)
  return save_err
 }
 tx,started,txerr:=iface.unit_of_work_begin(service.uow_factory)
 if !started do return txerr
 committed:=false
 defer if !committed do iface.unit_of_work_rollback(&tx)
 // Provider repository shares the connection held by this unit of work.
 if input.has_enabled {
  _,saved,save_err:=set_bridge_provider_enabled(service,bridge.bridge_id,provider,now,input.enabled,profile)
  if !saved do return save_err
 }
 if input.has_transport {
  if save_err:=iface.set_provider_transport(service.repo,bridge.bridge_id,provider,input.transport,now);save_err.code!=.None do return save_err
 }
 committed=true // commit consumes this unit of work, including on failure
 _,cerr:=iface.unit_of_work_commit(&tx)
 return cerr
}


// Only bounded, nonsecret state is exposed in failure details, never a raw
// adapter report/error or an environment supplied by the Bridge.
acp_unavailable_error :: proc(provider,state,message:string)->domain.Domain_Error {
 data,_:=json.marshal(struct{provider,state:string}{provider,state},allocator=context.temp_allocator)
 return domain.domain_error(.ACP_Unavailable,message,string(data))
}
acp_adapter_state :: proc(raw:string)->string {
 value,err:=json.parse(raw)
 if err!=nil do return "not_checked"
 defer json.destroy_value(value)
 obj,ok:=value.(json.Object)
 if !ok do return "not_checked"
 state,valid:=obj["state"].(json.String)
 if !valid do return "not_checked"
 switch string(state) {
 case "not_checked","missing_node","missing_npm","missing","installing","ready","outdated","error":return strings.clone(string(state),context.temp_allocator)
 }
 return "not_checked"
}
