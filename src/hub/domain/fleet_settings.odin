package domain

import "core:strings"
import contracts "odin_test:contracts"

Fleet_Runtime :: contracts.Fleet_Runtime
Fleet_Agent_Override :: contracts.Fleet_Agent_Override
Fleet_Settings :: contracts.Fleet_Settings
Fleet_Settings_Draft :: contracts.Fleet_Settings_Draft
Fleet_Scope :: enum { Unknown, Chain, Excluded, Manual }
Fleet_Application :: contracts.Fleet_Application
Fleet_Application_Target :: contracts.Fleet_Application_Target
Fleet_Apply_Input :: contracts.Fleet_Apply_Input

// The durable envelope keeps the canonical request private; status responses
// expose only the application, never another owner's request or settings.
Fleet_Application_Record :: struct {
	owner_user_id: User_ID,
	request_json: string,
	authority_json: string,
	application: Fleet_Application,
}
fleet_application_destroy :: proc(a: ^Fleet_Application) {
	delete(a.application_id); delete(a.bridge_id); delete(a.request_id)
	delete(a.state); delete(a.created_at); delete(a.updated_at)
	for t in a.targets {
		delete(t.agent_instance_id); delete(t.agent_id); delete(t.launch_epoch)
		delete(t.project_id); delete(t.lease_id); delete(t.operation_key); delete(t.state)
		delete(t.error_code); delete(t.error_message)
		fleet_runtime_destroy(t.before); fleet_runtime_destroy(t.desired)
	}
	delete(a.targets)
	a^ = {}
}
fleet_application_record_destroy :: proc(r: ^Fleet_Application_Record) {
	delete(string(r.owner_user_id)); delete(r.request_json); delete(r.authority_json)
	fleet_application_destroy(&r.application)
	r^ = {}
}

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
