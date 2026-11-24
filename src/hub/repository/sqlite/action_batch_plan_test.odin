package sqlite
import "core:strings"
import "core:testing"
import iface "odin_test:hub/repository/iface"

@(test)
test_action_batch_target_lookup_uses_instance_index :: proc(t:^testing.T) {
 actions_repo_test(t,action_batch_target_lookup_plan)
}
action_batch_target_lookup_plan :: proc(t:^testing.T,_:iface.Action_Repository,conn:^Conn) {
 query:=strings.concatenate({"EXPLAIN QUERY PLAN ",ACTIONS_SQL_TARGET_OPEN_DELIVERY},context.temp_allocator)
 stmt:sqlite3_stmt
 if !testing.expect_value(t,sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(query,context.temp_allocator),-1,&stmt,nil),SQLITE_OK) do return
 defer sqlite3_finalize(stmt)
 indexed:=false
 for sqlite3_step(stmt)==SQLITE_ROW {
  detail:=column_text_unowned(stmt,3)
  if strings.contains(detail,"SEARCH r USING INDEX action_runs_instance_routed") do indexed=true
  testing.expect(t,!strings.contains(detail,"SCAN r"),detail)
 }
 testing.expect(t,indexed,"target lookup must search action_runs_instance_routed")
}
