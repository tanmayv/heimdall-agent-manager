package actions
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
when ODIN_OS==.Windows {foreign import perf_sqlite "system:sqlite3.lib"} else {foreign import perf_sqlite "system:sqlite3"}
foreign perf_sqlite {
 @(link_name="sqlite3_trace_v2")
 perf_trace :: proc "c" (db:rawptr,mask:c.uint,cb:proc "c"(c.uint,rawptr,rawptr,rawptr)->c.int,ctx:rawptr)->c.int ---
 @(link_name="sqlite3_sql")
 perf_sql :: proc "c" (stmt:rawptr)->cstring ---
}
perf_count :: proc "c"(mask:c.uint,ctx,stmt,unused:rawptr)->c.int {
 context=runtime.default_context()
 sql:=string(perf_sql(stmt))
 if strings.has_prefix(sql,"SELECT") || strings.has_prefix(sql,"WITH") do (^int)(ctx)^+=1
 return 0
}
@(test)
test_action_list_query_count_and_ownership :: proc(t:^testing.T) {actions_track(t,perf_list_tracked)}
perf_list_tracked :: proc(t:^testing.T) {service_case(t,perf_list)}
perf_list :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
 repo:=&s.repos.actions
 for i in 0..<40 {
  id:=fmt.tprintf("action-%03d",i)
  testing.expect_value(t,repo.save(repo.ctx,{id=domain.Action_ID(id),owner_user_id="owner",prompt_text="p",target_kind="instance",min_interval_s=30,instance_strategy="reuse",created_at=id,updated_at=id}).code,domain.Error_Code.None)
  for j in 0..<i%4 {
   trigger:=fmt.tprintf("%s-trigger-%d",id,j)
   testing.expect_value(t,repo.trigger_save(repo.ctx,{trigger_id=trigger,action_id=domain.Action_ID(id),owner_user_id="owner",kind="event",config_json="{}",data_filter_json="{}",created_at=trigger,updated_at=trigger}).code,domain.Error_Code.None)
  }
  if i%2==0 do testing.expect_value(t,repo.rules_replace(repo.ctx,domain.Action_ID(id),{{position=0,bridge_id="*",provider="*",model="*"}}).code,domain.Error_Code.None)
 }
 testing.expect_value(t,repo.save(repo.ctx,{id="other",owner_user_id="other",prompt_text="secret",target_kind="instance",min_interval_s=30,instance_strategy="reuse"}).code,domain.Error_Code.None)
 count:=0
 perf_trace(rawptr(db.db),1,perf_count,&count)
 views,err:=list(s,"owner")
 perf_trace(rawptr(db.db),0,nil,nil)
 defer action_views_destroy(views)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,count,3)
 testing.expect_value(t,len(views),40)
 for v,i in views {
  testing.expect_value(t,string(v.action.id),fmt.tprintf("action-%03d",i))
  testing.expect_value(t,len(v.rules),1 if i%2==0 else 0)
  testing.expect_value(t,len(v.triggers),i%4)
  for tr in v.triggers do testing.expect_value(t,string(tr.action_id),string(v.action.id))
 }
 empty,e:=list(s,"absent");defer action_views_destroy(empty)
 testing.expect(t,e.code==.None && len(empty)==0)
}
@(test)
test_history_page_batches_counts_and_expiry :: proc(t:^testing.T) {action_test_case(t,perf_history)}
perf_history :: proc(t:^testing.T,f:^Action_Test) {
 action_test_match(t,f,"first");drain_due(&f.runtime.router)
 action_test_match(t,f,"second");action_test_match(t,f,"third")
 count:=0
 perf_trace(rawptr(f.db.db),1,perf_count,&count)
 rows,err:=list_runs(&f.runtime.router,"owner","action",100,"")
 perf_trace(rawptr(f.db.db),0,nil,nil)
 defer run_views_destroy(rows)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,len(rows),3)
 routed:=false
 for row in rows {
  if row.run.state=="routed" {
   routed=true
   testing.expect_value(t,row.joined_count,2)
   testing.expect(t,row.delivery_expires_at!="")
  } else {testing.expect_value(t,row.joined_count,0);testing.expect_value(t,row.delivery_expires_at,"")}
 }
 testing.expect(t,routed)
 for _ in 0..<10 {action_test_match(t,f,fmt.tprintf("join-%d",f.serial))}
 many_count:=0
 perf_trace(rawptr(f.db.db),1,perf_count,&many_count)
 many,me:=list_runs(&f.runtime.router,"owner","action",100,"")
 perf_trace(rawptr(f.db.db),0,nil,nil)
 defer run_views_destroy(many)
 testing.expect_value(t,me.code,domain.Error_Code.None)
 testing.expect_value(t,many_count,count)
 page,pe:=list_runs(&f.runtime.router,"owner","action",1,"")
 defer run_views_destroy(page)
 if !testing.expect(t,pe.code==.None && len(page)==1) do return
 next,ne:=list_runs(&f.runtime.router,"owner","action",100,page[0].run.created_at,page[0].run.run_id)
 defer run_views_destroy(next)
 testing.expect_value(t,ne.code,domain.Error_Code.None)
 testing.expect_value(t,len(next),len(many)-1)
 for row in next do testing.expect(t,row.run.run_id!=page[0].run.run_id)
 _,denied:=list_runs(&f.runtime.router,"other","action",100,"")
 testing.expect_value(t,denied.code,domain.Error_Code.Not_Found)
}
@(test)
test_cold_history_sweep_is_bounded :: proc(t:^testing.T) {action_test_case(t,perf_sweep)}
perf_sweep :: proc(t:^testing.T,f:^Action_Test) {
 testing.expect(t,sqlite.exec(&f.db,
 "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<260) INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,created_at) SELECT 'cold-'||x,'action','trigger','owner','cold-'||x,'event','delivered','2026-01-01' FROM n;"+
 "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<260) INSERT INTO pipeline_deliveries(delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,state,expires_at,created_at,updated_at) SELECT 'cold-'||x,'owner','prompt','bridge','instance','run:cold-'||x,'done','2026-01-01','2026-01-01','2026-01-01' FROM n;"+
 "INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,created_at) VALUES('recent','action','trigger','owner','recent','event','delivered','2026-11-22');"+
 "INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,created_at) VALUES('open','action','trigger','owner','open','event','queued','2026-01-01');"+
 "INSERT INTO pipeline_deliveries(delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,state,expires_at,created_at,updated_at) VALUES('open','owner','prompt','bridge','instance','run:open','routed','2027-01-01','2026-01-01','2026-01-01');"))
 // Failure of the second table must roll the first table's deletion back.
 original:=f.repos.pipeline_deliveries.prune
 f.repos.pipeline_deliveries.prune=proc(ctx:rawptr,cutoff:string)->domain.Domain_Error {
  return domain.domain_error(.Internal_Error,"injected retention failure")
 }
 failed:=sweep_history(f.runtime.svc,time.Time{_nsec=f.now_ms*1_000_000})
 testing.expect_value(t,failed.code,domain.Error_Code.Internal_Error)
 unchanged,ue:=f.repos.actions.runs_list(f.repos.actions.ctx,"action",1000,"","")
 testing.expect_value(t,ue.code,domain.Error_Code.None)
 testing.expect_value(t,len(unchanged),262)
 domain.action_runs_destroy(unchanged)
 f.repos.pipeline_deliveries.prune=original
 for want in ([]int{134,6,2}) {
  err:=sweep_history(f.runtime.svc,time.Time{_nsec=f.now_ms*1_000_000})
  testing.expect_value(t,err.code,domain.Error_Code.None)
  rows,e:=f.repos.actions.runs_list(f.repos.actions.ctx,"action",1000,"","")
  testing.expect_value(t,e.code,domain.Error_Code.None)
  testing.expect_value(t,len(rows),want)
  domain.action_runs_destroy(rows)
 }
 open,found,e:=f.repos.actions.run_open(f.repos.actions.ctx,"action")
 defer domain.action_run_destroy(&open)
 testing.expect(t,e.code==.None && found && open.run_id=="open")
 testing.expect(t,sqlite.exec(&f.db,"CREATE TEMP TABLE sweep_check(n INTEGER CHECK(n=1)); INSERT INTO sweep_check SELECT count(*) FROM pipeline_deliveries;"))
}
