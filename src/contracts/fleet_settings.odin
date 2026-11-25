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

// Point-in-time draft preview. No targets are reserved and no policy is saved.
Fleet_Preview :: struct {
	bridge_id: string `json:"bridge_id"`,
	expected_revision: i64 `json:"expected_revision"`,
	affected_instances: int `json:"affected_instances"`,
}

// Typed details codes on Conflict / Unprocessable_Entity responses.
FLEET_REVISION_CONFLICT :: "fleet_revision_conflict"
FLEET_RUNTIME_MANAGED :: "fleet_runtime_managed"
FLEET_SELECTION_UNAVAILABLE :: "fleet_selection_unavailable"

Fleet_Apply_Input :: struct {
	request_id: string `json:"request_id"`,
	expected_revision: i64 `json:"expected_revision"`,
	default_runtime: Fleet_Runtime `json:"default_runtime"`,
	overrides: []Fleet_Agent_Override `json:"overrides"`,
}
// Desired runtime is separate from actual process state. Ready requires the
// native reconfiguration's acknowledged launch epoch and startup readiness.
Fleet_Application_Target :: struct {
	agent_instance_id: string `json:"agent_instance_id"`,
	agent_id: string `json:"agent_id"`,
	configuration_revision: int `json:"configuration_revision"`,
	run_count: int `json:"run_count"`,
	launch_epoch: string `json:"launch_epoch"`,
	project_id: string `json:"project_id"`,
	lease_id: string `json:"lease_id"`,
	before: Fleet_Runtime `json:"before"`,
	desired: Fleet_Runtime `json:"desired"`,
	operation_key: string `json:"operation_key"`,
	state: string `json:"state"`, // pending | restarting | ready | failed
	error_code: string `json:"error_code"`,
	error_message: string `json:"error_message"`,
	retryable: bool `json:"retryable"`,
}
Fleet_Application :: struct {
	application_id: string `json:"application_id"`,
	bridge_id: string `json:"bridge_id"`,
	request_id: string `json:"request_id"`,
	settings_revision: i64 `json:"settings_revision"`,
	revision: int `json:"revision"`,
	settings_saved: bool `json:"settings_saved"`,
	cancelled: bool `json:"cancelled"`,
	state: string `json:"state"`, // pending | restarting | ready | partial_failure
	created_at: string `json:"created_at"`,
	updated_at: string `json:"updated_at"`,
	targets: []Fleet_Application_Target `json:"targets"`,
}
