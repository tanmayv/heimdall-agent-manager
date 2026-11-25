package taskv2

import "core:encoding/json"
import "core:strings"
import domain "odin_test:hub/domain"
import agent "odin_test:hub/service/agent"
import fleet_settings "odin_test:hub/service/fleet_settings"

// fleet_model_on_bridge returns the fleet row's provider/model for a bridge,
// honouring a per-bridge override in bridge_models_json.
fleet_model_on_bridge :: proc(fleet: domain.Task_Chain_Fleet, bridge_id: string) -> (string, string) {
	if fleet.bridge_models_json != "" {
		entries: map[string]domain.Fleet_Bridge_Model
		if json.unmarshal((transmute([]u8) fleet.bridge_models_json), &entries, allocator = context.temp_allocator) == nil {
			if selection, found := entries[bridge_id]; found { return selection.provider, selection.model }
		}
	}
	return fleet.provider, fleet.model
}

// resolve_launch_model fills an empty provider/model from the active catalog
// intersected with what the bridge supports. Catalog order is rank then id.
// Explicit selections are preserved: an unavailable selection must fail rather
// than silently launch a different provider or model. Caller owns the strings.
resolve_launch_model :: proc(agent_service: ^agent.Agent_Service, bridge_id, provider, model: string,provider_profile:string = "") -> (string, string) {
	if provider != "" && model != "" do return strings.clone(provider), strings.clone(model)
	if agent_service == nil || agent_service.providers == nil do return strings.clone(provider), strings.clone(model)
	// Compatibility/catalog helper only. Callers with chain identity resolve
	// shared authority first; nil bridges deliberately means no settings read.
	s := fleet_settings.Service{agents = agent_service.agents, providers = agent_service.providers}
	r, err := fleet_settings.resolve(&s, "", bridge_id, "", {provider, provider_profile, model})
	if err.code != .None do return strings.clone(provider), strings.clone(model)
	delete(r.runtime.provider_profile)
	return r.runtime.provider, r.runtime.model
}

// A provider override deliberately discards the instance's old model. Empty
// provider/model together retain the catalog-default fleet inheritance rule.
lease_launch_model :: proc(svc: ^Service, placement: Placement, inst: domain.Agent_Instance) -> (string, string) {
	provider, model := resolve_launch_model(svc.agent_service, placement.bridge_id, placement.provider, placement.model,placement.provider_profile)
	if provider == "" { delete(provider); provider = strings.clone(inst.provider) }
	if model == "" && placement.provider == "" {
		delete(model); model = strings.clone(inst.model)
	}
	return provider, model
}

fleet_profile_on_bridge :: proc(fleet:domain.Task_Chain_Fleet,bridge_id:string) -> string {
 if fleet.bridge_models_json!="" {
  entries:map[string]domain.Fleet_Bridge_Model
  if json.unmarshal_string(fleet.bridge_models_json,&entries,allocator=context.temp_allocator)==nil {
   if selection,found:=entries[bridge_id];found do return domain.profile_effective_id(selection.provider,selection.provider_profile)
  }
 }
 return domain.profile_effective_id(fleet.provider,fleet.provider_profile)
}
