package domain

// Versioned independently from transport connection generations. Source/destination
// are captured once so UI progress and audit history never follow changing rows.
Instance_Configuration :: struct {
	runtime_transport: string,
	provider_profile: string,
	bridge_id: string,
	bridge_label: string,
	project_id: string,
	project_label: string,
	project_path: string,
	provider: string,
	model: string,
	// permission_mode is the instance override ("" inherit | "yolo" | "ask"); the
	// move commit trigger copies the destination value onto the instance.
	permission_mode: string,
	// runtime_transport_override is the instance's explicit transport choice
	// ("" follow bridge/catalog | "pty" | "acp"); runtime_transport above is the
	// value it resolved to. The move commit trigger copies it onto the instance.
	runtime_transport_override: string,
}

Instance_Reconfiguration_Phase :: enum {
	Prepared,
	Stopping,
	Source_Stopped,
	Launching,
	Ready,
	Failed,
	Recovery_Required,
	// Appended (payloads persist the enum ordinal): an apply "after_turn"
	// operation queued until the instance is idle. It does not block input, it
	// holds the instance's single active-operation slot, and it leaves only to
	// Stopping/Source_Stopped (fired) or Failed (cancelled, superseded, conflict).
	Waiting_For_Idle,
}

// Apply modes for a reconfiguration request.
RECONFIGURATION_APPLY_NOW :: "now"
RECONFIGURATION_APPLY_AFTER_TURN :: "after_turn"

// Failure codes of an operation that left Waiting_For_Idle without firing.
RECONFIGURATION_CANCELLED :: "cancelled"
RECONFIGURATION_SUPERSEDED :: "superseded"
// Fire-time revision check failed: the instance configuration changed while waiting.
RECONFIGURATION_CONFLICT :: "conflict"


Instance_Reconfiguration :: struct {
	operation_id: string,
	owner_user_id: string,
	agent_instance_id: string,
	conversation_id: string,
	actor_user_id: string,
	idempotency_key: string,
	expected_revision: int,
	revision: int,
	phase: Instance_Reconfiguration_Phase,
	source: Instance_Configuration,
	destination: Instance_Configuration,
	stop_command_id: string,
	launch_command_id: string,
	launch_epoch: string,
	source_launch_epoch: string,
	source_run_count: int,
	// Frozen native launch frame, including an existing task context when held.
	launch_json: string,
	// True after a physical stop is confirmed, or after an offline source is
	// durably fenced by transferring canonical ownership. A fenced source Bridge
	// must terminate the superseded runtime when it next reports inventory.
	source_stopped: bool,
	destination_committed: bool,
	failure_code: string,
	failure_message: string,
	// apply is "now" or "after_turn" ("" on payloads written before T4 = now).
	apply: string,
	// waiting_since is when an after_turn operation entered Waiting_For_Idle
	// ("" when it never waited). Kept after it fires, so history shows the wait.
	// The Hub waits indefinitely; the UI offers "Restart now" after 30 minutes.
	waiting_since: string,
	created_at: string,
	updated_at: string,
}

instance_reconfiguration_phase_string :: proc(phase: Instance_Reconfiguration_Phase) -> string {
	switch phase {
	case .Prepared: return "prepared"
	case .Stopping: return "stopping"
	case .Source_Stopped: return "source_stopped"
	case .Launching: return "launching"
	case .Ready: return "ready"
	case .Failed: return "failed"
	case .Recovery_Required: return "recovery_required"
	case .Waiting_For_Idle: return "waiting_for_idle"
	}
	return "recovery_required"
}

// An uncertain or interrupted command remains exclusive until explicitly reconciled.
// A failed launch after commit also needs recovery: Reset must not unlock delivery.
// A queued (Waiting_For_Idle) operation never blocks input: messages still flow
// while the current turn finishes.
instance_reconfiguration_blocks_input :: proc(op: Instance_Reconfiguration) -> bool {
	if op.phase == .Waiting_For_Idle do return false
	return op.phase != .Ready && !(op.phase == .Failed && (op.failure_code == "recovery_stopped" || (!op.source_stopped && !op.destination_committed)))
}

instance_reconfiguration_transition_allowed :: proc(from, to: Instance_Reconfiguration_Phase) -> bool {
	switch from {
	case .Prepared: return to == .Stopping || to == .Source_Stopped || to == .Failed || to == .Recovery_Required
	case .Stopping: return to == .Source_Stopped || to == .Recovery_Required
	case .Source_Stopped: return to == .Launching || to == .Recovery_Required
	case .Launching: return to == .Launching || to == .Ready || to == .Recovery_Required
	case .Recovery_Required: return to == .Recovery_Required || to == .Stopping || to == .Source_Stopped || to == .Launching || to == .Ready || to == .Failed
	case .Waiting_For_Idle: return to == .Stopping || to == .Source_Stopped || to == .Failed
	case .Ready, .Failed: return false
	}
	return false
}

// instance_reconfiguration_holds_slot reports whether the operation occupies the
// instance's single active-operation slot (blocking or queued).
instance_reconfiguration_holds_slot :: proc(op: Instance_Reconfiguration) -> bool {
	return op.phase == .Waiting_For_Idle || instance_reconfiguration_blocks_input(op)
}

instance_configuration_equal :: proc(a, b: Instance_Configuration) -> bool {
	return a.bridge_id == b.bridge_id && a.project_id == b.project_id && a.project_path == b.project_path && a.provider == b.provider && profile_effective_id(a.provider,a.provider_profile)==profile_effective_id(b.provider,b.provider_profile) && a.model == b.model && a.permission_mode == b.permission_mode && a.runtime_transport==b.runtime_transport && runtime_transport_override_normalize(a.runtime_transport_override)==runtime_transport_override_normalize(b.runtime_transport_override)
}

instance_configuration_destroy :: proc(config: ^Instance_Configuration) {
	delete(config.runtime_transport)
	delete(config.bridge_id); delete(config.bridge_label)
	delete(config.project_id); delete(config.project_label); delete(config.project_path)
	delete(config.provider_profile); delete(config.provider); delete(config.model); delete(config.permission_mode)
	delete(config.runtime_transport_override)
	config^ = {}
}

instance_reconfiguration_destroy :: proc(op: ^Instance_Reconfiguration) {
	delete(op.operation_id); delete(op.owner_user_id); delete(op.agent_instance_id)
	delete(op.conversation_id); delete(op.actor_user_id); delete(op.idempotency_key)
	delete(op.stop_command_id); delete(op.launch_command_id); delete(op.launch_epoch)
	delete(op.source_launch_epoch); delete(op.launch_json)
	delete(op.failure_code); delete(op.failure_message); delete(op.apply); delete(op.waiting_since); delete(op.created_at); delete(op.updated_at)
	instance_configuration_destroy(&op.source); instance_configuration_destroy(&op.destination)
	op^ = {}
}
