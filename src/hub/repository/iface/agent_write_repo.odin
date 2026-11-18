package iface

import domain "odin_test:hub/domain"

Agent_Write_Repository :: struct {
	ctx:           rawptr,
	insert:        proc(ctx: rawptr, w: domain.Agent_Write) -> domain.Domain_Error,
	list_by_owner: proc(
		ctx: rawptr,
		owner_user_id: string,
		before_seq: i64,
		limit: int,
	) -> (
		[]domain.Agent_Write,
		domain.Domain_Error,
	),
}
agent_write_insert :: proc(repo: ^Agent_Write_Repository, w: domain.Agent_Write) -> domain.Domain_Error {
	if repo == nil || repo.insert == nil do return domain.domain_error(.Internal_Error, "agent write repository is not configured")
	return repo.insert(repo.ctx, w)
}
agent_write_list_by_owner :: proc(
	repo: ^Agent_Write_Repository,
	owner_user_id: string,
	before_seq: i64,
	limit: int,
) -> (
	[]domain.Agent_Write,
	domain.Domain_Error,
) {
	if repo == nil || repo.list_by_owner == nil do return nil, domain.domain_error(.Internal_Error, "agent write repository is not configured")
	return repo.list_by_owner(repo.ctx, owner_user_id, before_seq, limit)
}
