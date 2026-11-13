#+private file
package sqlite

import "core:testing"
import "core:strings"
import iface "odin_test:hub/repository/iface"

@(test)
test_task_event_latest_id_is_owner_scoped_empty_zero_and_indexed :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 conn,path,ok:=tmpl_open_file_prod(t,"event_latest")
 defer tmpl_remove_db(path)
 if !ok do return
 defer close(&conn)
 migrated,merr:=run_migrations(&conn)
 if !testing.expect(t,migrated,merr.message) do return
 impl:Taskchain_Repo_SQLite
 repo:=new_taskchain_repository(&impl,&conn)
 empty,eerr:=iface.taskchain_latest_event_id(&repo,"t","u1")
 testing.expect(t,eerr.code==.None && empty==0,"no events is generation zero")
 seeded:=exec(&conn,`INSERT INTO task_events(event_id,task_id,chain_id,owner_user_id,ts_ms,kind,payload_json)
 VALUES (11,'t','c','u1',9,'created','{"large":"original body"}'),
 (31,'t','c','u1',1,'comment','{"body":"latest id despite older timestamp"}'),
 (51,'t','c','u2',20,'created','{}'),(71,'other','c','u1',30,'created','{}');`)
 if !testing.expect(t,seeded,"seed scoped histories") do return
 latest,lerr:=iface.taskchain_latest_event_id(&repo,"t","u1")
 testing.expect(t,lerr.code==.None && latest==31,"latest ID includes comments, excludes other owners/tasks, ignores timestamp ordering")
 other,oerr:=iface.taskchain_latest_event_id(&repo,"t","u2")
 testing.expect(t,oerr.code==.None && other==51,"explicit other owner is independently scoped")
 absent,aerr:=iface.taskchain_latest_event_id(&repo,"t","missing")
 testing.expect(t,aerr.code==.None && absent==0,"wrong owner receives empty history")
 stmt:sqlite3_stmt
 rc:=sqlite3_prepare_v2(conn.db,"EXPLAIN QUERY PLAN SELECT event_id FROM task_events WHERE task_id='t' AND owner_user_id='u1' ORDER BY event_id DESC LIMIT 1;",-1,&stmt,nil)
 if testing.expect(t,rc==SQLITE_OK,"prepare scalar query plan") {
  defer sqlite3_finalize(stmt)
  testing.expect(t,sqlite3_step(stmt)==SQLITE_ROW,"query plan row")
  detail:=column_text_unowned(stmt,3)
  testing.expect(t,strings.contains(detail,"idx_task_events_task"),"existing task/event index serves generation lookup")
 }
 // Query failure must never masquerade as an empty generation.
 testing.expect(t,exec(&conn,"DROP TABLE task_events;"),"remove event source")
 _,failerr:=iface.taskchain_latest_event_id(&repo,"t","u1")
 testing.expect(t,failerr.code!=.None,"SQL errors fail closed")
 missing:iface.Taskchain_Repository
 _,adaptererr:=iface.taskchain_latest_event_id(&missing,"t","u1")
 testing.expect(t,adaptererr.code!=.None,"missing adapter fails closed")
}
