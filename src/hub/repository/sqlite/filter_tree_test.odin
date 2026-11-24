package sqlite

import "core:testing"

@(test)
test_filter_tree_migration :: proc(t:^testing.T) {
 conn,opened,_:=open(":memory:")
 if !testing.expect(t,opened) do return
 defer close(&conn)
 ok,_:=run_migrations(&conn,stop_before="actions_007_filter_tree.sql")
 if !testing.expect(t,ok) do return
 testing.expect(t,exec(&conn,`INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES('a','owner','p','instance','now','now');`))
 testing.expect(t,exec(&conn,`INSERT INTO action_triggers(trigger_id,action_id,owner_user_id,kind,config,event_type,subject_filter,data_filter,created_at,updated_at) VALUES('t','a','owner','event','{"event_type":"chain.state","chain_id":"c","data":{"state":"completed"}}','chain.state','ev.owner.chain.c.state','{"state":"completed"}','now','now'),('empty','a','owner','event','{"event_type":"chain.state","data":{}}','chain.state','ev.owner.chain.*.state','{}','now','now');`))
 ok,_=run_migrations(&conn)
 if !testing.expect(t,ok) do return
 stmt:sqlite3_stmt
 testing.expect_value(t,sqlite3_prepare_v2(conn.db,`SELECT json_extract(config,'$.entity_id'),json_type(config,'$.chain_id') IS NULL,json_type(config,'$.data') IS NULL,json_extract(config,'$.filter')=data_filter,subject_filter,data_filter FROM action_triggers WHERE trigger_id='t';`,-1,&stmt,nil),SQLITE_OK)
 testing.expect_value(t,sqlite3_step(stmt),SQLITE_ROW)
 id:=column_text(stmt,0);defer delete(id)
 testing.expect_value(t,id,"c")
 testing.expect_value(t,sqlite3_column_int64(stmt,1),i64(1))
 testing.expect_value(t,sqlite3_column_int64(stmt,2),i64(1))
 testing.expect_value(t,sqlite3_column_int64(stmt,3),i64(1))
 subject:=column_text(stmt,4);defer delete(subject)
 testing.expect_value(t,subject,"ev.owner.chain.c.state")
 tree:=column_text(stmt,5);defer delete(tree)
 testing.expect_value(t,tree,`{"all":[{"field":"data.state","op":"eq","value":"completed"}]}`)
 sqlite3_finalize(stmt)
 testing.expect_value(t,sqlite3_prepare_v2(conn.db,`SELECT data_filter,json_type(config,'$.filter') IS NULL FROM action_triggers WHERE trigger_id='empty';`,-1,&stmt,nil),SQLITE_OK)
 testing.expect_value(t,sqlite3_step(stmt),SQLITE_ROW)
 empty:=column_text(stmt,0);defer delete(empty)
 testing.expect_value(t,empty,"{}")
 testing.expect_value(t,sqlite3_column_int64(stmt,1),i64(1))
 sqlite3_finalize(stmt)
}
