package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

SQLite_Unit_Of_Work_Factory :: struct {
	conn: ^Conn,
	repos: ^iface.Repositories,
}

SQLite_Unit_Of_Work_Context :: struct {
	conn: ^Conn,
	repos: ^iface.Repositories,
	closed: bool,
}

new_unit_of_work_factory :: proc(factory: ^SQLite_Unit_Of_Work_Factory, conn: ^Conn, repos: ^iface.Repositories) -> iface.Unit_Of_Work_Factory {
	factory.conn = conn
	factory.repos = repos
	return iface.Unit_Of_Work_Factory{ctx = rawptr(factory), begin = sqlite_uow_begin}
}

sqlite_uow_begin :: proc(ctx: rawptr) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
	factory := (^SQLite_Unit_Of_Work_Factory)(ctx)
	if factory == nil || factory.conn == nil || factory.conn.db == nil {
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "sqlite unit of work factory is not open")
	}
	if !exec(factory.conn, "BEGIN;") {
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to begin transaction")
	}
	uow_ctx := new(SQLite_Unit_Of_Work_Context)
	uow_ctx.conn = factory.conn
	uow_ctx.repos = factory.repos
	return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos}, true, domain.Domain_Error{}
}

sqlite_uow_commit :: proc(ctx: rawptr) -> (bool, domain.Domain_Error) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return false, domain.domain_error(.Internal_Error, "transaction is closed")
	uow_ctx.closed = true
	ok := exec(uow_ctx.conn, "COMMIT;")
	free(uow_ctx)
	if !ok do return false, domain.domain_error(.Internal_Error, "failed to commit transaction")
	return true, domain.Domain_Error{}
}

sqlite_uow_rollback :: proc(ctx: rawptr) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return
	uow_ctx.closed = true
	exec(uow_ctx.conn, "ROLLBACK;")
	free(uow_ctx)
}
