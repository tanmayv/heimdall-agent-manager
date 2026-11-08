package taskv2

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import platform "odin_test:hub/platform"
import compact "odin_test:lib/context_compaction"

summary_test_rebuild :: proc(t:^testing.T,fx:^Fixture,chain:domain.Task_Chain) {
    u,ok,err:=begin_uow(&fx.svc)
    if !testing.expect(t,ok,err.message) do return
    before:=scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'")
    rebuild_chain_summary_in_uow(&fx.svc,&u,chain)
    after:=scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'")
    testing.expect_value(t,len(u.effects.notifications),int(1 if before!=after else 0))
    _,cerr:=end_uow(&fx.svc,&u,true)
    testing.expect(t,cerr.code==.None,cerr.message)
}

@(test)
test_summary_compaction_overflow_curated_edits_and_persisted_failure_rearm :: proc(t:^testing.T) {
    fx,ok:=fixture_open(t,"summary_compaction");defer fixture_close(fx)
    if !ok do return
    chain:=seed_chain(t,fx,"summary_chain",true)
    chain.coordinator_agent_instance_id="coordinator"
    _,_,_=iface.taskchain_save_chain(&fx.repo,chain)
    task:=seed_task(t,fx,chain,"history_task")
    for i in 1..=100 {
        raw,_:=json.marshal(struct{summary:string,dead_ends,decisions:[]string}{"handoff",[]string{fmt.tprintf("lesson%d %s",i,strings.repeat("detail",300,context.temp_allocator))},[]string{"retain the ownership fence"}},allocator=context.temp_allocator)
        written,err:=iface.taskchain_save_facet(&fx.repo,domain.Task_Attempt_Facet{
            task_id=task.task_id,chain_id=chain.chain_id,owner_user_id=chain.owner_user_id,
            attempt_no=i,kind=FACET_HANDOFF,v=1,body_json=string(raw),writer=FACET_WRITER_AGENT,written_at=platform.clock_now(&fx.clock),
        })
        testing.expect(t,written,err.message)
    }
    for _ in 0..<5 do summary_test_rebuild(t,fx,chain)
    summary,present,_:=iface.taskchain_get_chain_summary(&fx.repo,chain.chain_id,chain.owner_user_id)
    testing.expect(t,present && len(summary.body)<=compact.MAX_BYTES && summary.line_count<=compact.MAX_LINES)
    testing.expect(t,strings.contains(summary.body,"lesson100") && strings.contains(summary.body,"facet:TASK:ATTEMPT:handoff"))
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'"),"0")
    _,set_ok,set_err:=chain_summary_set(&fx.svc,user_auth(),chain.chain_id,"short curated note")
    testing.expect(t,set_ok,set_err.message)
    for _ in 0..<3 do summary_test_rebuild(t,fx,chain)
    summary,_,_=iface.taskchain_get_chain_summary(&fx.repo,chain.chain_id,chain.owner_user_id)
    testing.expect_value(t,summary.curated_body,"short curated note")
    testing.expect(t,strings.contains(summary.body,"short curated note"))
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'"),"0")
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_attempt_facets WHERE kind='handoff'"),"100")
    for i in 1..=100 {
        original,has_original:=get_facet(&fx.svc,task,i,FACET_HANDOFF)
        fetched,fetch_ok,_:=task_fetch(&fx.svc,task,fmt.tprintf("facet:history_task:%d:handoff",i))
        testing.expect(t,has_original && fetch_ok && strings.contains(fetched,original.body_json),"all original attempts remain fetchable verbatim")
    }
    long_note:=strings.concatenate({strings.repeat("curated",200,context.temp_allocator),"CURATED_TAIL"},context.temp_allocator)
    _,notes_saved,_:=chain_summary_set(&fx.svc,user_auth(),chain.chain_id,long_note)
    testing.expect(t,notes_saved)
    original_notes,notes_fetch_ok,_:=task_fetch(&fx.svc,task,"chain-summary")
    testing.expect(t,notes_fetch_ok && strings.contains(original_notes,long_note),"curated input is fetchable beyond the preview budget")
    for i in 0..<30 do _=seed_task(t,fx,chain,fmt.tprintf("pending_task_%d",i))
    notes:=make([dynamic]string,context.temp_allocator)
    for i in 0..<60 do append(&notes,fmt.tprintf("curated note %d",i))
    _,crowded_ok,_:=chain_summary_set(&fx.svc,user_auth(),chain.chain_id,strings.join(notes[:],"\n",context.temp_allocator))
    testing.expect(t,crowded_ok)
    summary_test_rebuild(t,fx,chain)
    crowded,_,_:=iface.taskchain_get_chain_summary(&fx.repo,chain.chain_id,chain.owner_user_id)
    testing.expect(t,strings.contains(crowded.body,"lesson100") && strings.contains(crowded.body,"Decision: retain the ownership fence"),"task/notes volume cannot starve recent lessons and decisions")
    // Genuine pre-upgrade persisted rows can contain a single enormous line.
    old:=strings.repeat("old",20000,context.temp_allocator)
    bounded:=chain_summary_preview(old)
    testing.expect(t,len(bounded)<=compact.MAX_BYTES && len(strings.split_lines(bounded,context.temp_allocator))<=compact.MAX_LINES)
    // Genuine source failure is actionable and persists once per failure edge.
    testing.expect(t,exec_ok(t,fx,"ALTER TABLE task_attempt_facets RENAME TO unavailable_facets"))
    for _ in 0..<3 do summary_test_rebuild(t,fx,chain)
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'"),"1")
    _,edited,_:=chain_summary_set(&fx.svc,user_auth(),chain.chain_id,"notes edited during failure")
    testing.expect(t,edited)
    summary_test_rebuild(t,fx,chain)
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'"),"1")
    summary,_,_=iface.taskchain_get_chain_summary(&fx.repo,chain.chain_id,chain.owner_user_id)
    testing.expect(t,summary.failure_fingerprint!="" && strings.contains(summary.body,"stale"))
    // A real connection close/open loses every service/UoW dedupe cache.
    path:=fmt.tprintf("%s/.cache/heimdall-tests/summary-restart-%d.sqlite",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    defer _=os.remove(path)
    disk,opened,_:=sqlite.open(path)
    if !testing.expect(t,opened) do return
    backup:=sqlite3_backup_init(disk.db,"main",fx.conn.db,"main")
    if !testing.expect(t,backup!=nil) do return
    testing.expect_value(t,sqlite3_backup_step(backup,-1),101)
    testing.expect_value(t,sqlite3_backup_finish(backup),0)
    sqlite.close(&disk);sqlite.close(&fx.conn)
    fx.conn,opened,_=sqlite.open(path)
    if !testing.expect(t,opened) do return
    fixture_wire(fx)
    for _ in 0..<3 do summary_test_rebuild(t,fx,chain)
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'"),"1")
    testing.expect(t,exec_ok(t,fx,"ALTER TABLE unavailable_facets RENAME TO task_attempt_facets"))
    summary_test_rebuild(t,fx,chain)
    summary,_,_=iface.taskchain_get_chain_summary(&fx.repo,chain.chain_id,chain.owner_user_id)
    testing.expect_value(t,summary.failure_fingerprint,"")
    testing.expect(t,exec_ok(t,fx,"ALTER TABLE task_attempt_facets RENAME TO unavailable_facets"))
    summary_test_rebuild(t,fx,chain)
    testing.expect_value(t,scalar_text(fx,"SELECT count(*) FROM task_events WHERE kind='summary_overflow'"),"2")
    testing.expect(t,exec_ok(t,fx,"DELETE FROM chain_summaries"))
    unavailable_pack:=build_pack_json(&fx.svc,chain,task,domain.Task_Lease{},domain.Agent_Instance{})
    testing.expect(t,strings.contains(unavailable_pack,"Chain context unavailable"),"missing projection plus source failure must not look like an empty successful context")

}

@(test)
test_summary_curated_single_line_byte_budget :: proc(t:^testing.T) {
    fx,ok:=fixture_open(t,"summary_bytes");defer fixture_close(fx)
    if !ok do return
    chain:=seed_chain(t,fx,"byte_chain",true)
    _,accepted,err:=chain_summary_set(&fx.svc,user_auth(),chain.chain_id,strings.repeat("x",compact.MAX_BYTES+1,context.temp_allocator))
    testing.expect(t,!accepted && err.code==.Validation_Failed,"one giant line is not a budget bypass")
}
