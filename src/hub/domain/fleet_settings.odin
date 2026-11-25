package domain

import "core:strings"
import contracts "odin_test:contracts"

Fleet_Runtime :: contracts.Fleet_Runtime
Fleet_Agent_Override :: contracts.Fleet_Agent_Override
Fleet_Settings :: contracts.Fleet_Settings
Fleet_Settings_Draft :: contracts.Fleet_Settings_Draft
Fleet_Scope :: enum { Unknown, Chain, Excluded, Manual }

fleet_runtime_destroy :: proc(r: Fleet_Runtime) {
	delete(r.provider); delete(r.provider_profile); delete(r.model)
}
fleet_runtime_clone :: proc(r: Fleet_Runtime) -> Fleet_Runtime {
	return {strings.clone(r.provider), strings.clone(r.provider_profile), strings.clone(r.model)}
}
fleet_settings_destroy :: proc(s: Fleet_Settings) {
	delete(s.bridge_id)
	fleet_runtime_destroy(s.default_runtime)
	for o in s.overrides { delete(o.agent_id); fleet_runtime_destroy(o.runtime) }
	delete(s.overrides)
}
fleet_runtime_equal :: proc(a, b: Fleet_Runtime) -> bool {
	return a.provider == b.provider && profile_effective_id(a.provider, a.provider_profile) == profile_effective_id(b.provider, b.provider_profile) && a.model == b.model
}
