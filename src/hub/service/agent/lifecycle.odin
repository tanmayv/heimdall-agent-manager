package agent

import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// One lifecycle path for agent instances (R7).
//
// Every entry point that needs an agent process goes through ensure_running
// (keep a live child) or restart_instance (replace it), both built on start();
// every stop names a Stop_Reason and its bridge command is built by
// stop_command_json. Reasons are typed so callers cannot invent new spellings;
// the wire and the stored stop_reason column carry their string values.

// Why a start was asked for. Logged with each launch.
Start_Reason :: enum u8 {
	User_Start,           // explicit start (UI, ham-ctl, MCP instances.start)
	User_Restart,         // explicit restart (composer, instance menu)
	Instance_Create,      // created and started in one request
	User_Message,         // the user wrote to a stopped agent (chat, question answers)
	Chain_Message,        // MCP chains.message to the coordinator
	Chain_Create,         // a new chain's coordinator
	Coordinator_Wake,     // a task notice or agent message for a stopped coordinator
	Coordinator_Dispatch, // the task engine starts a chain's coordinator
	Lease_Wake,           // the task engine wakes a lease holder
	Bridge_Wake,          // the bridge asks for a start (start-begin)
	Context_Rollover,     // the bridge restarts an agent with a fresh context
}

START_REASON_WIRE := [Start_Reason]string {
	.User_Start           = "user_start",
	.User_Restart         = "user_restart",
	.Instance_Create      = "instance_create",
	.User_Message         = "user_message",
	.Chain_Message        = "chain_message",
	.Chain_Create         = "chain_create",
	.Coordinator_Wake     = "coordinator_wake",
	.Coordinator_Dispatch = "coordinator_dispatch",
	.Lease_Wake           = "lease_wake",
	.Bridge_Wake          = "bridge_wake",
	.Context_Rollover     = "context_rollover",
}

start_reason_wire :: proc(r: Start_Reason) -> string { return START_REASON_WIRE[r] }

// Parses a restart reason sent over the wire. Only the reasons a caller may
// name for a restart are accepted; "" is a user restart.
restart_reason_parse :: proc(s: string) -> (Start_Reason, bool) {
	switch s {
	case "", START_REASON_WIRE[.User_Restart]: return .User_Restart, true
	case START_REASON_WIRE[.Context_Rollover]: return .Context_Rollover, true
	}
	return .User_Restart, false
}

// Why an instance is stopped. A distinct string: the value is stored in
// agent_instances.stop_reason and sent to the bridge as is, and only the named
// constants below (or a literal at a call site, typed by the compiler) are
// stop reasons. Reasons starting with "user" mark a sticky user stop.
Stop_Reason :: distinct string

STOP_USER_REQUESTED          :: Stop_Reason("user_requested")
STOP_CONFIGURATION_CHANGE    :: Stop_Reason("configuration_change")
STOP_RECOVERY_FORCE          :: Stop_Reason("recovery_force_stop")
STOP_TASK_COMPLETED          :: Stop_Reason("task_completed")
STOP_REVIEW_POSTED           :: Stop_Reason("review_posted")
STOP_IDLE_TTL                :: Stop_Reason("idle_ttl")
STOP_CAPACITY_YIELD          :: Stop_Reason("capacity_yield")
STOP_LEASE_HANDOFF           :: Stop_Reason("lease_handoff")
STOP_LEASE_INVALIDATED       :: Stop_Reason("lease_invalidated")
STOP_LEASE_REVOKED           :: Stop_Reason("lease_revoked")
STOP_COORDINATOR_IDLE        :: Stop_Reason("coordinator_idle")
STOP_COORDINATOR_IDLE_DONE   :: Stop_Reason("coordinator_idle_completed")
STOP_ACTION_FRESH_PER_RUN    :: Stop_Reason("action_fresh_per_run")

// Every reason a caller outside the service may send (UI, MCP, ham-ctl).
STOP_USER_FORCE              :: Stop_Reason("user_force_stop")
STOP_REASONS_WIRE := [?]Stop_Reason{STOP_USER_REQUESTED, STOP_USER_FORCE}

// Parses the reason of an explicit stop request (UI, MCP, ham-ctl). Those are
// all user stops: "" and free text (ham-ctl --reason "done for now") are
// user_requested, so a stop is sticky whatever note came with it.
stop_reason_parse :: proc(s: string) -> Stop_Reason {
	for r in STOP_REASONS_WIRE do if string(r) == s do return r
	return STOP_USER_REQUESTED
}

stop_reason_is_user :: proc(r: Stop_Reason) -> bool {
	return len(r) >= 4 && string(r)[:4] == "user"
}

// ensure_running: the agent should be running for `reason`. A live child is
// kept as is; a stopped one is started with its own provider, profile, model
// and transport. kept=true when nothing was launched.
ensure_running :: proc(service: ^Agent_Service, auth: contracts.Auth_Context, instance_id: string, reason: Start_Reason, guard_ctx: rawptr = nil, guard: proc(ctx: rawptr) -> domain.Domain_Error = nil) -> (inst: domain.Agent_Instance, kept, ok: bool, err: domain.Domain_Error) {
	return start(service, auth, instance_id, {if_live = .Keep, reason = reason, guard = guard, guard_ctx = guard_ctx})
}

lifecycle_log_start :: proc(inst: domain.Agent_Instance, reason: Start_Reason) {
	fmt.printfln("agent lifecycle: start instance=%s reason=%s run_count=%d provider=%s profile=%s model=%s transport=%s",
		inst.agent_instance_id, start_reason_wire(reason), inst.run_count, inst.provider, inst.provider_profile, inst.model, inst.runtime_transport)
}
