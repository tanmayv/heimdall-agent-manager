package iface

import domain "odin_test:hub/domain"

Unit_Of_Work_Commit_Proc :: proc(ctx: rawptr) -> (bool, domain.Domain_Error)
Unit_Of_Work_Rollback_Proc :: proc(ctx: rawptr)
Unit_Of_Work_Begin_Proc :: proc(ctx: rawptr) -> (Unit_Of_Work, bool, domain.Domain_Error)

Unit_Of_Work :: struct {
	ctx: rawptr,
	commit: Unit_Of_Work_Commit_Proc,
	rollback: Unit_Of_Work_Rollback_Proc,
	repos: ^Repositories,
}

Unit_Of_Work_Factory :: struct {
	ctx: rawptr,
	begin: Unit_Of_Work_Begin_Proc,
}

unit_of_work_begin :: proc(factory: ^Unit_Of_Work_Factory) -> (Unit_Of_Work, bool, domain.Domain_Error) {
	if factory == nil || factory.begin == nil {
		return Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "unit of work factory is not configured")
	}
	return factory.begin(factory.ctx)
}

unit_of_work_commit :: proc(uow: ^Unit_Of_Work) -> (bool, domain.Domain_Error) {
	if uow == nil || uow.commit == nil {
		return false, domain.domain_error(.Internal_Error, "unit of work is not configured")
	}
	return uow.commit(uow.ctx)
}

unit_of_work_rollback :: proc(uow: ^Unit_Of_Work) {
	if uow == nil || uow.rollback == nil do return
	uow.rollback(uow.ctx)
}
