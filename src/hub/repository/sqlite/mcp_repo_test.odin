package sqlite

import "core:testing"

@(test)
test_mcp_metadata_migration_embedded_upgrade_and_repeat :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	conn,opened,_:=open(":memory:")
	testing.expect(t,opened)
	if !opened do return
	defer close(&conn)
	const_name:="174_mcp_delegated_credentials.sql"
	ok,err:=run_migrations(&conn,"/missing-embedded-migration-test",const_name)
	testing.expectf(t,ok,"baseline migrations: %s",err.message)
	testing.expect(t,!sqlite_object_exists(&conn,"mcp_records"))
	upgraded,uerr:=run_migrations(&conn,"/missing-embedded-migration-test")
	testing.expectf(t,upgraded,"embedded MCP upgrade: %s",uerr.message)
	testing.expect(t,sqlite_object_exists(&conn,"mcp_records") && migration_applied(&conn,const_name))
	testing.expect(t,exec(&conn,`INSERT INTO mcp_records(kind,id,owner_user_id,metadata_json) VALUES('client','survives','','{}');`))
	again,aerr:=run_migrations(&conn,"/missing-embedded-migration-test")
	testing.expectf(t,again,"repeat migration: %s",aerr.message)
	stmt:sqlite3_stmt
	rc:=sqlite3_prepare_v2(conn.db,"SELECT COUNT(*) FROM mcp_records WHERE id='survives';",-1,&stmt,nil)
	testing.expect(t,rc==SQLITE_OK)
	if rc!=SQLITE_OK do return
	defer sqlite3_finalize(stmt)
	testing.expect(t,sqlite3_step(stmt)==SQLITE_ROW && sqlite3_column_int64(stmt,0)==1)
}
