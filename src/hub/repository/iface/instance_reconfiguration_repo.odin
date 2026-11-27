package iface

import domain "odin_test:hub/domain"

Instance_Reconfiguration_Begin_Proc :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error)
Instance_Reconfiguration_Get_Proc :: proc(ctx: rawptr, owner, instance_id, idempotency_key: string) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error)
Instance_Reconfiguration_Advance_Proc :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error)
Instance_Reconfiguration_List_Proc :: proc(ctx: rawptr, owner, instance_id: string, active_only: bool) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error)
// Every Waiting_For_Idle operation ("" filters match all), oldest first. These do
// not block input, so the active_only list above (blocks_input=1) excludes them.
Instance_Reconfiguration_List_Waiting_Proc :: proc(ctx: rawptr, owner, instance_id: string) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error)
// Atomically ends a Waiting_For_Idle operation (superseded is its next revision,
// phase Failed) and begins op, in one transaction: "Restart now" never leaves the
// instance with no operation or with two.
Instance_Reconfiguration_Begin_Superseding_Proc :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, superseded: domain.Instance_Reconfiguration, superseded_expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error)

instance_reconfiguration_begin :: proc(repo: ^Agent_Repository, op: domain.Instance_Reconfiguration) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	if repo == nil || repo.reconfiguration_begin == nil do return {}, false, domain.domain_error(.Internal_Error, "reconfiguration repository is not configured")
	return repo.reconfiguration_begin(repo.ctx, op)
}
instance_reconfiguration_get :: proc(repo: ^Agent_Repository, owner, instance_id, idempotency_key: string) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	if repo == nil || repo.reconfiguration_get == nil do return {}, false, domain.domain_error(.Internal_Error, "reconfiguration repository is not configured")
	return repo.reconfiguration_get(repo.ctx, owner, instance_id, idempotency_key)
}
instance_reconfiguration_advance :: proc(repo: ^Agent_Repository, op: domain.Instance_Reconfiguration, expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	if repo == nil || repo.reconfiguration_advance == nil do return {}, false, domain.domain_error(.Internal_Error, "reconfiguration repository is not configured")
	return repo.reconfiguration_advance(repo.ctx, op, expected_revision)
}
instance_reconfiguration_list :: proc(repo: ^Agent_Repository, owner, instance_id: string, active_only: bool) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error) {
	if repo == nil || repo.reconfiguration_list == nil do return nil, domain.domain_error(.Internal_Error, "reconfiguration repository is not configured")
	return repo.reconfiguration_list(repo.ctx, owner, instance_id, active_only)
}
instance_reconfiguration_list_waiting :: proc(repo: ^Agent_Repository, owner, instance_id: string) -> ([]domain.Instance_Reconfiguration, domain.Domain_Error) {
	if repo == nil || repo.reconfiguration_list_waiting == nil do return nil, {}
	return repo.reconfiguration_list_waiting(repo.ctx, owner, instance_id)
}
instance_reconfiguration_begin_superseding :: proc(repo: ^Agent_Repository, op: domain.Instance_Reconfiguration, superseded: domain.Instance_Reconfiguration, superseded_expected_revision: int) -> (domain.Instance_Reconfiguration, bool, domain.Domain_Error) {
	if repo == nil || repo.reconfiguration_begin_superseding == nil do return {}, false, domain.domain_error(.Conflict, "a configuration change is already queued for this instance")
	return repo.reconfiguration_begin_superseding(repo.ctx, op, superseded, superseded_expected_revision)
}
