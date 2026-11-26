package fleet_settings

import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import placement "odin_test:hub/service/placement"
import provider "odin_test:hub/service/provider"

Service :: struct {
	bridges: ^iface.Bridge_Repository,
	agents: ^iface.Agent_Repository,
	providers: ^iface.Provider_Repository,
}
Resolved :: struct {
	runtime: domain.Fleet_Runtime,
	source: string, // agent_override | bridge_default | legacy | catalog_default
	revision: i64,
}

// Shared, local-only read. Every returned string is owned by the caller.
resolve :: proc(s: ^Service, owner: domain.User_ID, bridge_id, agent_id: string, legacy: domain.Fleet_Runtime, catalog_fallback := true) -> (Resolved, domain.Domain_Error) {
	snapshot, err := iface.fleet_settings_get(s.bridges, owner, bridge_id)
	if err.code != .None do return {}, err
	defer domain.fleet_settings_destroy(snapshot)
	r := legacy
	source := "legacy"
	if snapshot.revision > 0 {
		r, source = snapshot.default_runtime, "bridge_default"
		for o in snapshot.overrides do if o.agent_id == agent_id {r, source = o.runtime, "agent_override"; break}
	}
	// Placement selects policy before bridge/workspace eligibility. Keep catalog
	// availability out of its configuration fingerprint and structural diagnosis.
	// Legacy integrations without catalog wiring may still keep a live child;
	// the existing real-start validation remains mandatory before any spawn.
	if !catalog_fallback || (snapshot.revision == 0 && s.providers == nil) {
		r.provider_profile = domain.profile_effective_id(r.provider, r.provider_profile)
		return {domain.fleet_runtime_clone(r), source, snapshot.revision}, {}
	}
	if r.provider == "" || r.model == "" {
		// Partial explicit legacy choices constrain catalog fallback, never erase
		// them. Managed snapshots always contain full explicit selections.
		catalog, ce := iface.provider_catalog_list(s.providers)
		if ce.code != .None do return {}, ce
		defer domain.provider_catalog_destroy(catalog)
		ps := provider.Provider_Service{repo = s.providers}
		vs := placement.Service{agents = s.agents, providers = &ps}
		for &entry in catalog {
			if entry.state != "active" || (r.provider != "" && r.provider != entry.provider) do continue
			if e := provider.apply_effective_models(s.providers, bridge_id, &entry, r.provider_profile); e.code != .None do continue
			for m in entry.models {
				if m.state != "active" || (r.model != "" && r.model != m.model_id) do continue
				available, e := placement.launchable(&vs, agent_id, bridge_id, entry.provider, m.model_id, r.provider_profile)
				delete(available.provider); delete(available.model)
				if e.code == .None {
					r = {entry.provider, domain.profile_effective_id(entry.provider, r.provider_profile), m.model_id}
					return {domain.fleet_runtime_clone(r), "catalog_default", snapshot.revision}, {}
				}
			}
		}
		return {}, domain.domain_error(.Provider_Unavailable, "no available Fleet runtime matches the selection", `{"code":"fleet_selection_unavailable"}`)
	}
	r.provider_profile = domain.profile_effective_id(r.provider, r.provider_profile)
	return {domain.fleet_runtime_clone(r), source, snapshot.revision}, {}
}

legacy_runtime :: proc(f: domain.Task_Chain_Fleet, bridge_id: string) -> domain.Fleet_Runtime {
	if f.bridge_models_json != "" {
		entries: map[string]domain.Fleet_Bridge_Model
		if json.unmarshal_string(f.bridge_models_json, &entries, allocator = context.temp_allocator) == nil {
			if r, found := entries[bridge_id]; found do return {r.provider, domain.profile_effective_id(r.provider, r.provider_profile), r.model}
		}
	}
	return {f.provider, domain.profile_effective_id(f.provider, f.provider_profile), f.model}
}

// F2 calls validate + save inside its Apply UOW together with application/target
// records. This layer performs no lifecycle actions and creates no network calls.
validate :: proc(s: ^Service, owner: domain.User_ID, bridge_id: string, draft: domain.Fleet_Settings_Draft) -> domain.Domain_Error {
	b, found, err := iface.bridge_get_bridge(s.bridges, bridge_id)
	defer domain.bridge_destroy(&b)
	if err.code != .None do return err
	if !found || b.owner_user_id != owner do return domain.domain_error(.Not_Found, "bridge not found")
	ps := provider.Provider_Service{repo = s.providers}
	vs := placement.Service{agents = s.agents, providers = &ps}
	if e := validate_runtime(&vs, bridge_id, "", draft.default_runtime); e.code != .None do return e
	seen := make(map[string]bool, context.temp_allocator)
	for o in draft.overrides {
		if seen[o.agent_id] do return domain.domain_error(.Unprocessable_Entity, "duplicate Fleet agent override")
		seen[o.agent_id] = true
		a, exists, ae := iface.agent_get(s.agents, o.agent_id)
		if ae.code != .None do return ae
		if !exists || a.owner_user_id != owner do return domain.domain_error(.Not_Found, "agent not found")
		if a.state != .Active do return domain.domain_error(.Unprocessable_Entity, "Fleet override agent is archived")
		if e := validate_runtime(&vs, bridge_id, o.agent_id, o.runtime); e.code != .None do return e
	}
	return {}
}

validate_runtime :: proc(vs: ^placement.Service, bridge_id, agent_id: string, r: domain.Fleet_Runtime) -> domain.Domain_Error {
	resolved, err := placement.launchable(vs, agent_id, bridge_id, r.provider, r.model, r.provider_profile)
	defer {delete(resolved.provider); delete(resolved.model)}
	if err.code != .None {
		if err.code == .Internal_Error do return err
		return domain.domain_error(.Unprocessable_Entity, err.message, `{"code":"fleet_selection_unavailable"}`)
	}
	return {}
}

save :: proc(s: ^Service, owner: domain.User_ID, bridge_id: string, draft: domain.Fleet_Settings_Draft) -> (domain.Fleet_Settings, bool, domain.Domain_Error) {
	if e := validate(s, owner, bridge_id, draft); e.code != .None do return {}, false, e
	return iface.fleet_settings_save(s.bridges, owner, bridge_id, draft)
}

managed_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Conflict, "Runtime is managed by bridge Fleet settings; edit Home Fleet for this bridge", `{"code":"fleet_runtime_managed"}`)
}

owner_has_managed_bridge :: proc(s: ^Service, owner: domain.User_ID) -> (bool, domain.Domain_Error) {
	bridges, err := iface.bridge_list_by_owner(s.bridges, owner)
	if err.code != .None do return false, err
	defer {for &b in bridges do domain.bridge_destroy(&b); delete(bridges)}
	for b in bridges {
		snapshot, e := iface.fleet_settings_get(s.bridges, owner, b.bridge_id)
		if e.code != .None do return false, e
		managed := snapshot.revision > 0
		domain.fleet_settings_destroy(snapshot)
		if managed do return true, {}
	}
	return false, {}
}

// Legacy field writes may still configure staffing/placement. Changes to runtime
// values which could apply on a managed bridge must be redirected explicitly.
guard_legacy_write :: proc(s: ^Service, owner: domain.User_ID, before, after: domain.Task_Chain_Fleet) -> domain.Domain_Error {
	bridges, err := iface.bridge_list_by_owner(s.bridges, owner)
	if err.code != .None do return err
	defer {for &b in bridges do domain.bridge_destroy(&b); delete(bridges)}
	for b in bridges {
		snapshot, e := iface.fleet_settings_get(s.bridges, owner, b.bridge_id)
		if e.code != .None do return e
		managed := snapshot.revision > 0
		domain.fleet_settings_destroy(snapshot)
		if !managed do continue
		if before.provider != after.provider || before.model != after.model || domain.profile_effective_id(before.provider, before.provider_profile) != domain.profile_effective_id(after.provider, after.provider_profile) do return managed_error()
		if !domain.fleet_runtime_equal(legacy_runtime(before, b.bridge_id), legacy_runtime(after, b.bridge_id)) do return managed_error()
	}
	return {}
}
