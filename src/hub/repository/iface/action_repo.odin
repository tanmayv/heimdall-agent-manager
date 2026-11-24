package iface

import domain "odin_test:hub/domain"

Action_Rule_Row :: struct { action_id: string, rule: domain.Action_Target_Rule }
Action_Run_History :: struct { run: domain.Action_Run, joined_count: int, delivery_expires_at: string }
Action_Repository :: struct {
 rules_for_owner: proc(ctx:rawptr, owner:string)->([]Action_Rule_Row,domain.Domain_Error),
 triggers_for_owner: proc(ctx:rawptr, owner:string)->([]domain.Action_Trigger,domain.Domain_Error),
 runs_history: proc(ctx:rawptr, id:domain.Action_ID, limit:int, before,before_id:string)->([]Action_Run_History,domain.Domain_Error),
 runs_sweep: proc(ctx:rawptr, cutoff:string, limit:int)->domain.Domain_Error,

	ctx: rawptr,
	// actions
	save:          proc(ctx: rawptr, a: domain.Action) -> domain.Domain_Error,                         // insert or update by id
	get:           proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action, bool, domain.Domain_Error),
	list:          proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Action, domain.Domain_Error), // ordered by created_at, action_id
	delete_action: proc(ctx: rawptr, id: domain.Action_ID) -> domain.Domain_Error,                     // also rules, triggers, runs
	set_last_spawned: proc(ctx: rawptr, id: domain.Action_ID, instance_id, updated_at: string) -> domain.Domain_Error,
	// rules
	rules_list:    proc(ctx: rawptr, id: domain.Action_ID) -> ([]domain.Action_Target_Rule, domain.Domain_Error), // ordered by position
	rules_replace: proc(ctx: rawptr, id: domain.Action_ID, rows: []domain.Action_Target_Rule) -> domain.Domain_Error,
	// triggers
	trigger_save:   proc(ctx: rawptr, t: domain.Action_Trigger) -> domain.Domain_Error,
	trigger_get:    proc(ctx: rawptr, trigger_id: string) -> (domain.Action_Trigger, bool, domain.Domain_Error),
	trigger_delete: proc(ctx: rawptr, trigger_id: string) -> domain.Domain_Error,
	triggers_list:  proc(ctx: rawptr, id: domain.Action_ID) -> ([]domain.Action_Trigger, domain.Domain_Error), // ordered by created_at, trigger_id
	// Enabled triggers of enabled actions for one owner and event type whose match_key is `subject` or '',
	// ordered by created_at, trigger_id. Two index reads on action_triggers_match (6.16, Q3). S2.
	triggers_match: proc(ctx: rawptr, owner, event_type, subject: string) -> ([]domain.Action_Trigger, domain.Domain_Error),
	// Enabled triggers of one kind whose action is enabled, across all owners (reconcile).
	triggers_effective: proc(ctx: rawptr, kind: string) -> ([]domain.Action_Trigger, domain.Domain_Error),
	// runs
	run_insert: proc(ctx: rawptr, r: domain.Action_Run) -> (inserted: bool, err: domain.Domain_Error),  // INSERT OR IGNORE on occurrence_key
	run_get:    proc(ctx: rawptr, run_id: string) -> (domain.Action_Run, bool, domain.Domain_Error),
	run_open:   proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action_Run, bool, domain.Domain_Error), // the queued, deferred or routed run
	// Runs that are due for routing: state queued, or state deferred with not_before <= now. Never a routed run. Ordered by created_at, run_id.
	runs_due:   proc(ctx: rawptr, now: string, limit: int) -> ([]domain.Action_Run, domain.Domain_Error),
	// Runs in state deferred, whatever their not_before. Ordered by created_at, run_id.
	runs_deferred: proc(ctx: rawptr, limit: int) -> ([]domain.Action_Run, domain.Domain_Error),
	// Compare-and-set: writes next only if the stored state equals from_state. changed = false when it did not.
	run_transition: proc(ctx: rawptr, next: domain.Action_Run, from_state: string) -> (changed: bool, err: domain.Domain_Error),
	// started_at of the newest run whose started_at is set (routed, delivered, or failed after routing), or "".
	run_last_started_at: proc(ctx: rawptr, id: domain.Action_ID) -> (string, domain.Domain_Error),
	run_joined_count: proc(ctx: rawptr, run_id: string) -> (int, domain.Domain_Error),
	// Newest first. Empty before_created_at starts at the newest row; before_id breaks timestamp ties when supplied.
	runs_list:  proc(ctx: rawptr, id: domain.Action_ID, limit: int, before_created_at: string, before_id: string) -> ([]domain.Action_Run, domain.Domain_Error),
	// Deletes rows of this action that are not open and are either older than cutoff or beyond the newest keep rows.
	runs_prune: proc(ctx: rawptr, id: domain.Action_ID, keep: int, cutoff: string) -> domain.Domain_Error,
}
