package contracts

// One complete bridge snapshot. Revision zero means never configured; first
// successful Apply establishes shared authority without importing chain values.
Fleet_Runtime :: struct {
	provider: string `json:"provider"`,
	provider_profile: string `json:"provider_profile"`,
	model: string `json:"model"`,
}
Fleet_Agent_Override :: struct {
	agent_id: string `json:"agent_id"`,
	runtime: Fleet_Runtime `json:"runtime"`,
}
Fleet_Settings :: struct {
	bridge_id: string `json:"bridge_id"`,
	revision: i64 `json:"revision"`,
	default_runtime: Fleet_Runtime `json:"default_runtime"`,
	overrides: []Fleet_Agent_Override `json:"overrides"`,
}
Fleet_Settings_Draft :: struct {
	expected_revision: i64 `json:"expected_revision"`,
	default_runtime: Fleet_Runtime `json:"default_runtime"`,
	overrides: []Fleet_Agent_Override `json:"overrides"`,
}

// Typed details codes on Conflict / Unprocessable_Entity responses.
FLEET_REVISION_CONFLICT :: "fleet_revision_conflict"
FLEET_RUNTIME_MANAGED :: "fleet_runtime_managed"
FLEET_SELECTION_UNAVAILABLE :: "fleet_selection_unavailable"
