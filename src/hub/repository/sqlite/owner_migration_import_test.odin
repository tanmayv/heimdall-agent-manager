#+feature dynamic-literals
package sqlite

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

// A chain with every exported kind, Unicode text and enough comment volume to
// span several export documents.
legacy_import_seed_rich :: proc(t:^testing.T,conn:^Conn) -> domain.Legacy_Migration_Selection {
    s:=legacy_seed_source(t,conn)
    big:=strings.repeat("é界",40000,context.temp_allocator)
    testing.expect(t,exec(conn,`
      UPDATE tasks SET state='done',brief_json='{"goal":"Ship","acceptance":["Works"]}',priority='p0',attempt_no=2 WHERE task_id='task';
      INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at,state,blocked_on_json)
        VALUES('blocked','chain','account','Blocked ☃','2001-01-01T00:00:00Z','2001-01-02T00:00:00Z','backlog','{"kind":"human","reason":"needs keys"}');
      INSERT INTO work_dependencies(dependency_id,chain_id,owner_user_id,dependent_kind,dependent_id,prerequisite_kind,prerequisite_id,created_by_kind,created_by_id,created_at) VALUES('dep_1','chain','account','task','blocked','task','task','user','account','t1');
      INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain','inst_1','agt_1','account','worker','t2');
      INSERT INTO task_chain_directories(directory_id,chain_id,owner_user_id,path,created_at,updated_at) VALUES('dir_1','chain','account','/repo/项目','t3','t3');
      INSERT INTO chain_summaries(chain_id,owner_user_id,body,line_count,version,updated_at,curated_body) VALUES('chain','account','raw',1,2,'t4','curated ☃');
      INSERT INTO task_events(task_id,chain_id,owner_user_id,ts_ms,actor_kind,actor_id,kind,payload_json) VALUES('task','chain','account',5,'user','account','created','{"title":"x"}');
      INSERT INTO task_attempts(task_id,attempt_no,chain_id,owner_user_id,started_at,ended_at,holder_instance_id,outcome) VALUES('task',1,'chain','account','s','e','inst_1','submitted');
      INSERT INTO task_attempt_facets(task_id,attempt_no,chain_id,owner_user_id,kind,body_json,writer,written_at) VALUES('task',1,'chain','account','handoff','{"summary":"done"}','agent','w');
      INSERT INTO task_reviews(task_id,chain_id,owner_user_id,attempt_no,role,reviewer_kind,verdict,created_at) VALUES('task','chain','account',1,'','user','approve','r');`))
    for i in 0..<3 {
        testing.expect(t,exec(conn,fmt.tprintf("INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,author_agent_instance_id,body,created_at,updated_at) VALUES('c%d','task','chain','account','inst_1','%s','2001-0%d','2001-0%d')",i,big,i,i)))
    }
    rows,ok:=legacy_metadata(conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    if testing.expect(t,ok && len(rows)==1) do s.expected_work_revision=legacy_test_number(rows[0][0])
    return s
}

// The Hub engine is removed: a busy chain is no longer refused. The freeze
// transaction neutralizes it (leases ended, in-progress work force-held,
// running workflows cancelled, outstanding effects retired, review carried)
// and records what it did on the selection row; the export names the
// force-held tasks.
@(test)
legacy_import_freeze_neutralizes_busy_chain :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    testing.expect(t,exec(&conn,`
      INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at,state) VALUES('busy','chain','account','busy','time','time','in_progress');
      INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery)
        VALUES('lease','busy','chain','account',1,'inst','work','g','e','h','wake');
      UPDATE tasks SET state='in_review',attempt_no=1 WHERE task_id='task';
      INSERT INTO owner_legacy_source_generations VALUES('chain','account',1);
      INSERT INTO owner_legacy_source_effects(effect_id,chain_id,account_id,bridge_id,kind,input_digest,generation,state,command_id)
        VALUES('eff','chain','account','brg','wake','bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',1,'outstanding','cmd_1');
      BEGIN;
      INSERT INTO workflow_runs(run_id,chain_id,owner_user_id,title,definition_ref,spec_json,inputs_json,current_execution_no,request_id,request_hash,created_by_kind,created_by_id,created_at,updated_at,revision)
        VALUES('run','chain','account','Run','def:1','{}','{}',1,'req','hash','user','account','c','u',1);
      INSERT INTO workflow_run_executions(run_id,execution_no,chain_id,owner_user_id,state,resolved_inputs_json,output_manifest_json,revision)
        VALUES('run',1,'chain','account','running','{}','{}',1);
      COMMIT;`))
    blockers,_:=repo.legacy_migration_blockers(repo.ctx,"chain")
    testing.expect(t,len(blockers)>=4,"preflight still reports the live work (informational)")
    rows,_:=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    stale:=s;stale.expected_work_revision-=1
    _,_,serr:=repo.legacy_migration_freeze_now(repo.ctx,stale)
    testing.expect_value(t,serr.code,domain.Error_Code.Conflict)
    f,refused,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expectf(t,err.code==.None && len(refused)==0 && f.state=="frozen" && contracts.owner_hex(f.quiescence_digest,64),"busy chain freezes: %v %s",err.code,err.message)
    testing.expect_value(t,f.forced_held_json,`["busy"]`)
    for code in ([]string{`"code":"live_leases_ended","count":1,"items":["lease"]`,`"code":"tasks_in_review_carried","count":1,"items":["task"]`,`"code":"workflows_cancelled","count":1,"items":["run:1"]`,`"code":"effects_resolved","count":1,"items":["eff"]`,`"code":"tasks_force_held","count":1,"items":["busy"]`}) {
        testing.expectf(t,strings.contains(f.neutralized_json,code),"neutralized %s in %s",code,f.neutralized_json)
    }
    rows,_=legacy_metadata(&conn,`SELECT (SELECT count(*) FROM task_leases),(SELECT state FROM workflow_run_executions WHERE run_id='run'),(SELECT state FROM owner_legacy_source_effects WHERE effect_id='eff'),(SELECT state FROM tasks WHERE task_id='busy')`,4)
    testing.expect(t,len(rows)==1 && rows[0][0]=="0" && rows[0][1]=="cancelled" && rows[0][2]=="retired" && rows[0][3]=="in_progress","leases ended, run cancelled, effect retired, legacy rows otherwise untouched")
    export,eerr:=repo.legacy_migration_export(repo.ctx,"account","chain",s.migration_id)
    testing.expect_value(t,eerr.code,domain.Error_Code.None)
    m,parsed:=contracts.owner_migration_manifest_parse(export.manifest)
    testing.expect(t,parsed && len(m.forced_held)==1 && m.forced_held[0]=="busy","the manifest names the force-held task")
    replay,_,rerr:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect(t,rerr.code==.None && replay.revision==f.revision && replay.quiescence_digest==f.quiescence_digest && replay.neutralized_json==f.neutralized_json,"exact replay is read-only")
    other:=s;other.owner_bridge_id="another"
    _,_,cerr:=repo.legacy_migration_freeze_now(repo.ctx,other)
    testing.expect_value(t,cerr.code,domain.Error_Code.Conflict)
}

@(test)
legacy_import_frozen_writes_rejected_and_pending_merge_closed :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    testing.expect(t,exec(&conn,`
      INSERT INTO task_chain_directories(directory_id,chain_id,owner_user_id,path,vcs_kind,created_at,updated_at) VALUES('d','chain','account','/r','git','t','t');
      UPDATE tasks SET state='done' WHERE task_id='task';
      INSERT INTO task_events(task_id,chain_id,owner_user_id,ts_ms,actor_kind,actor_id,kind,payload_json) VALUES('task','chain','account',1,'hub','','approved','{}');`))
    blockers,_:=repo.legacy_migration_blockers(repo.ctx,"chain")
    testing.expect(t,len(blockers)==1 && blockers[0].code=="pending_merges")
    // A pending merge no longer refuses the import: it is closed (imported as
    // done; the unmerged branch stays where it is) and recorded.
    rows,_:=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    f,blocked,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect(t,err.code==.None && len(blocked)==0 && f.state=="frozen")
    testing.expect(t,strings.contains(f.neutralized_json,`"code":"merges_closed","count":1,"items":["task"]`),f.neutralized_json)
    for sql in ([4]string{
      "UPDATE tasks SET title='late' WHERE task_id='task'",
      "INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,body,created_at,updated_at) VALUES('late','task','chain','account','late','t','t')",
      "INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('l','task','chain','account',1,'i','work','g','e','h','wake')",
      "INSERT INTO chain_summaries(chain_id,owner_user_id,updated_at) VALUES('chain','account','late')",
    }) { testing.expectf(t,!exec(&conn,sql),"frozen write must fail: %s",sql) }
}

@(test)
legacy_import_export_digest_round_trip_is_stable_and_complete :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_import_seed_rich(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    _,notfrozen:=repo.legacy_migration_export(repo.ctx,"account","chain","migration")
    testing.expect_value(t,notfrozen.code,domain.Error_Code.Conflict)
    f,blocked,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    if !testing.expect(t,err.code==.None && len(blocked)==0 && f.state=="frozen") do return
    first,e1:=repo.legacy_migration_export(repo.ctx,"account","chain","migration")
    second,e2:=repo.legacy_migration_export(repo.ctx,"account","chain","migration")
    if !testing.expect(t,e1.code==.None && e2.code==.None) do return
    testing.expect_value(t,second.manifest_digest,first.manifest_digest)
    testing.expect_value(t,second.manifest,first.manifest)
    testing.expect_value(t,contracts.owner_payload_digest(first.manifest),first.manifest_digest)
    m,valid:=contracts.owner_migration_manifest_parse(first.manifest)
    if !testing.expect(t,valid) do return
    testing.expect(t,m.chain_id=="chain" && m.migration_id=="migration" && m.selection_digest==s.selection_digest && m.source_generation==f.generation)
    testing.expect_value(t,len(m.documents),len(first.documents))
    comment_docs:=0
    per_kind:=make(map[string]int,context.temp_allocator)
    for ref,i in m.documents {
        rows,ok:=contracts.owner_migration_document_parse(first.documents[i],ref)
        testing.expectf(t,ok,"document %d verifies against its manifest hash",i)
        per_kind[ref.kind]+=len(rows)
        if ref.kind=="comment" do comment_docs+=1
    }
    testing.expect(t,comment_docs>1,"large comments span several bounded documents")
    for k,i in m.kinds {
        spec:=contracts.OWNER_MIGRATION_EXPORT_KINDS[i]
        expected,_:=legacy_count(&conn,fmt.tprintf("SELECT count(*) FROM %s WHERE %s",spec.table,spec.scope),"chain")
        testing.expectf(t,k.rows==expected && i64(per_kind[k.kind])==expected,"kind %s exports every row (%d/%d)",k.kind,k.rows,expected)
    }
    task_rows,_:=contracts.owner_migration_document_parse(first.documents[1],m.documents[1])
    blocked_title:=""
    for r in task_rows { row,_:=r.(json.Object);if contracts.owner_string(row,"task_id")=="blocked" do blocked_title=contracts.owner_string(row,"title") }
    testing.expect_value(t,blocked_title,"Blocked ☃")
    testing.expect(t,len(m.archival_only)==len(contracts.OWNER_MIGRATION_ARCHIVAL_ONLY),"unrepresentable kinds are stated explicitly")
    // A tampered document no longer matches its manifest entry.
    tampered:=strings.concatenate({first.documents[0][:len(first.documents[0])-2]," ]}"},context.temp_allocator)
    _,ok:=contracts.owner_migration_document_parse(tampered,m.documents[0])
    testing.expect(t,!ok)
}

@(test)
legacy_import_cutover_registers_route_once_and_keeps_legacy_writes_disabled :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    manifest:=strings.repeat("1",64,context.temp_allocator)
    receipt:=strings.repeat("2",64,context.temp_allocator)
    route:=domain.Owner_Registry_Record{account_id="account",chain_id="chain",owner_bridge_id="bridge",owner_key_id="key",creator_id="device",genesis_digest="gd",genesis_json=`{"g":1}`}
    _,err:=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration",manifest,receipt,route)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    _,_,ferr:=repo.legacy_migration_freeze_now(repo.ctx,s)
    if !testing.expect_value(t,ferr.code,domain.Error_Code.None) do return
    wrong:=route;wrong.owner_bridge_id="other"
    _,err=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration",manifest,receipt,wrong)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    replayed:bool
    replayed,err=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration",manifest,receipt,route)
    testing.expect(t,err.code==.None && !replayed)
    f,_,_:=repo.legacy_source_get(repo.ctx,"account","chain")
    testing.expect(t,f.state=="imported" && f.manifest_digest==manifest && f.receipt_digest==receipt)
    replayed,err=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration",manifest,receipt,route)
    testing.expect(t,err.code==.None && replayed,"exact cutover replay is read-only")
    _,err=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration",strings.repeat("3",64,context.temp_allocator),receipt,route)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    rows,_:=legacy_metadata(&conn,"SELECT owner_bridge_id,genesis_json FROM owner_local_chains WHERE chain_id='chain'",2)
    testing.expect(t,len(rows)==1 && rows[0][0]=="bridge" && rows[0][1]==`{"g":1}`)
    got,found,_:=repo.legacy_migration_get(repo.ctx,"account","migration")
    testing.expect(t,found && got.state=="imported")
    _,found,_=repo.legacy_migration_get(repo.ctx,"other_account","migration")
    testing.expect(t,!found)
    testing.expect(t,!exec(&conn,"UPDATE tasks SET title='after cutover' WHERE task_id='task'"),"the legacy writer stays disabled after cutover")
    testing.expect(t,!exec(&conn,"UPDATE owner_legacy_migrations SET state='frozen',revision=revision+1 WHERE chain_id='chain'"),"imported is terminal")
    // A frozen export remains readable for an exact retry after cutover.
    exported,eerr:=repo.legacy_migration_export(repo.ctx,"account","chain","migration")
    testing.expect(t,eerr.code==.None && len(exported.documents)>0)
}

legacy_import_seed_run :: proc(t:^testing.T,conn:^Conn,state:string,run:="run") {
    testing.expect(t,exec(conn,fmt.tprintf(`BEGIN;
      INSERT INTO workflow_runs(run_id,chain_id,owner_user_id,title,definition_ref,spec_json,inputs_json,current_execution_no,request_id,request_hash,created_by_kind,created_by_id,created_at,updated_at,revision)
        VALUES('%s','chain','account','Run','def:1','{{}}','{{}}',1,'req_%s','hash','user','account','c','u',1);
      INSERT INTO workflow_run_executions(run_id,execution_no,chain_id,owner_user_id,state,resolved_inputs_json,output_manifest_json,revision)
        VALUES('%s',1,'chain','account','%s','{{}}','{{}}',1);
      COMMIT;`,run,run,run,state)))
}

// R3 review blocker: a ticket gated on a workflow run that has not succeeded,
// and a live workflow stage task, cannot be imported as ordinary tickets: the
// import neutralizes them first.
@(test)
legacy_import_releases_workflow_gates_and_archives_live_stage_tasks :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    legacy_import_seed_run(t,&conn,"running")
    legacy_import_seed_run(t,&conn,"succeeded","run_ok")
    testing.expect(t,exec(&conn,`INSERT INTO work_dependencies(dependency_id,chain_id,owner_user_id,dependent_kind,dependent_id,prerequisite_kind,prerequisite_id,created_by_kind,created_by_id,created_at)
        VALUES('dep_ok','chain','account','task','task','workflow_run','run_ok','user','account','t');
      INSERT INTO work_dependencies(dependency_id,chain_id,owner_user_id,dependent_kind,dependent_id,prerequisite_kind,prerequisite_id,created_by_kind,created_by_id,created_at)
        VALUES('dep_gate','chain','account','task','task','workflow_run','run','user','account','t');
      INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at,state,workflow_run_id,workflow_execution_no,stage_key)
        VALUES('stage_live','chain','account','s','t','t','ready','run',1,'build');`))
    blockers,_:=repo.legacy_migration_blockers(repo.ctx,"chain")
    codes:=make([dynamic]string,context.temp_allocator)
    for b in blockers do append(&codes,fmt.tprintf("%s=%s",b.code,strings.join(b.items,"|",context.temp_allocator)))
    testing.expect_value(t,strings.join(codes[:],",",context.temp_allocator),"running_workflows=run:1,workflow_gated_dependencies=dep_gate (task:task needs workflow_run:run),workflow_stage_tasks=stage_live")
    rows,_:=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    f,refused,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expectf(t,err.code==.None && len(refused)==0 && f.state=="frozen","gated chain freezes: %s",err.message)
    // The running run is cancelled, the never-succeeded gate is removed (kept in
    // history) and its ticket force-held; dep_ok on a succeeded run is untouched;
    // the live stage task becomes archival.
    rows,_=legacy_metadata(&conn,`SELECT (SELECT state FROM workflow_run_executions WHERE run_id='run'),(SELECT removed_by_id FROM work_dependencies WHERE dependency_id='dep_gate'),(SELECT removed_at FROM work_dependencies WHERE dependency_id='dep_ok')`,3)
    testing.expect(t,len(rows)==1 && rows[0][0]=="cancelled" && rows[0][1]=="legacy_import" && rows[0][2]=="")
    testing.expect_value(t,f.forced_held_json,`["task"]`)
    for code in ([]string{`"code":"workflows_cancelled"`,`"code":"workflow_gates_released","count":1,"items":["dep_gate"]`,`"code":"workflow_stage_tasks_archived","count":1,"items":["stage_live"]`}) {
        testing.expectf(t,strings.contains(f.neutralized_json,code),"neutralized %s in %s",code,f.neutralized_json)
    }
    _,aerr:=repo.legacy_migration_abort(repo.ctx,"account","chain","migration")
    testing.expect_value(t,aerr.code,domain.Error_Code.None)
    rows,_=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    fresh:=s;fresh.migration_id="migration_refreeze";fresh.selection_digest=strings.repeat("d",64,context.temp_allocator);fresh.expected_work_revision=legacy_test_number(rows[0][0])
    f2,refused2,err2:=repo.legacy_migration_freeze_now(repo.ctx,fresh)
    testing.expectf(t,err2.code==.None && len(refused2)==0 && f2.state=="frozen","re-freeze after abort: %s",err2.message)
    testing.expect_value(t,f2.forced_held_json,`["task"]`)
}

// R3 review: an unfinished migration can be aborted by the account owner,
// returning the chain to its legacy writer; it can never be cut over or
// re-frozen afterwards, and an imported migration cannot be aborted.
@(test)
legacy_import_abort_releases_frozen_chain_and_fences_the_selection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    _,err:=repo.legacy_migration_abort(repo.ctx,"account","chain","migration")
    testing.expect_value(t,err.code,domain.Error_Code.Not_Found)
    f,_,ferr:=repo.legacy_migration_freeze_now(repo.ctx,s)
    if !testing.expect(t,ferr.code==.None && f.state=="frozen") do return
    testing.expect(t,!exec(&conn,"UPDATE tasks SET title='frozen' WHERE task_id='task'"))
    testing.expect(t,!exec(&conn,"DELETE FROM owner_legacy_migrations"),"no deletion without an abort record")
    _,err=repo.legacy_migration_abort(repo.ctx,"other_account","chain","migration")
    testing.expect_value(t,err.code,domain.Error_Code.Not_Found)
    replayed:bool
    replayed,err=repo.legacy_migration_abort(repo.ctx,"account","chain","migration")
    testing.expect(t,err.code==.None && !replayed)
    replayed,err=repo.legacy_migration_abort(repo.ctx,"account","chain","migration")
    testing.expect(t,err.code==.None && replayed,"exact abort replays")
    testing.expect(t,exec(&conn,"UPDATE tasks SET title='writable again' WHERE task_id='task'"),"the legacy writer is released")
    testing.expect(t,exec(&conn,`INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery)
      VALUES('lease','task','chain','account',1,'inst','work','g','e','h','wake'); DELETE FROM task_leases;`),"grants resume")
    route:=domain.Owner_Registry_Record{account_id="account",chain_id="chain",owner_bridge_id="bridge",owner_key_id="key",creator_id="device",genesis_digest="gd",genesis_json="{}"}
    _,err=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration",strings.repeat("1",64),strings.repeat("2",64),route)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    routes,_:=legacy_metadata(&conn,"SELECT 1 FROM owner_local_chains",1)
    testing.expect_value(t,len(routes),0)
    _,found,_:=repo.legacy_migration_get(repo.ctx,"account","migration")
    testing.expect(t,!found,"the owner Bridge can never observe an aborted migration as imported")
    rows,_:=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    _,_,ferr=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect_value(t,ferr.code,domain.Error_Code.Conflict)
    // A new selection may freeze again; once imported it cannot be aborted.
    fresh:=s;fresh.migration_id="migration_2";fresh.selection_digest=strings.repeat("c",64)
    f,_,ferr=repo.legacy_migration_freeze_now(repo.ctx,fresh)
    testing.expect(t,ferr.code==.None && f.state=="frozen")
    _,err=repo.legacy_migration_cutover(repo.ctx,"account","chain","migration_2",strings.repeat("1",64),strings.repeat("2",64),route)
    testing.expect_value(t,err.code,domain.Error_Code.None)
    _,err=repo.legacy_migration_abort(repo.ctx,"account","chain","migration_2")
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    testing.expect(t,!exec(&conn,"DELETE FROM owner_legacy_migrations"),"an imported fence is permanent")
}

// R3 re-review: only an explicit abort record reports a migration aborted.
@(test)
legacy_import_aborted_lookup_is_explicit :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    _,_,found,_:=repo.legacy_migration_aborted(repo.ctx,"account","migration")
    testing.expect(t,!found,"unknown migrations are not aborted")
    _,_,ferr:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect_value(t,ferr.code,domain.Error_Code.None)
    _,_,found,_=repo.legacy_migration_aborted(repo.ctx,"account","migration")
    testing.expect(t,!found,"a frozen migration is not aborted")
    _,err:=repo.legacy_migration_abort(repo.ctx,"account","chain","migration")
    testing.expect_value(t,err.code,domain.Error_Code.None)
    chain,bridge,aborted,_:=repo.legacy_migration_aborted(repo.ctx,"account","migration")
    testing.expect(t,aborted && chain=="chain" && bridge=="bridge")
    _,_,found,_=repo.legacy_migration_aborted(repo.ctx,"other","migration")
    testing.expect(t,!found)
}

// Migration 213: nothing creates a Hub chain or task any more; existing rows
// stay readable, and Import all lists every legacy chain with its state.
@(test)
legacy_hub_chain_inserts_refused_and_import_listing :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    testing.expect(t,!exec(&conn,"INSERT INTO task_chains(chain_id,owner_user_id,title,created_at,updated_at) VALUES('new','account','t','c','u')"),"a new Hub chain is refused")
    testing.expect(t,legacy_fixture_allow_seeding(&conn))
    s:=legacy_seed_source(t,&conn)
    testing.expect(t,exec(&conn,`CREATE TRIGGER hub_chains_removed_tasks_insert BEFORE INSERT ON tasks BEGIN SELECT RAISE(ABORT,'hub_chains_removed'); END;`))
    testing.expect(t,!exec(&conn,"INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at) VALUES('new_task','chain','account','t','c','u')"),"a new Hub task is refused")
    testing.expect(t,exec(&conn,"UPDATE tasks SET title='legacy rows stay updatable until frozen' WHERE task_id='task'"))
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    f,_,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect(t,err.code==.None && f.state=="frozen")
    rows,lerr:=repo.legacy_chain_list(repo.ctx,"account","",10)
    testing.expect_value(t,lerr.code,domain.Error_Code.None)
    testing.expect_value(t,len(rows),2)
    if len(rows)==2 {
        testing.expect(t,rows[0].chain_id=="chain" && rows[0].state=="frozen" && rows[0].migration_id==s.migration_id && rows[0].task_count==1,"selected chain carries its state")
        testing.expect(t,rows[1].chain_id=="other" && rows[1].state=="none" && rows[1].migration_id=="","other chain not yet imported")
    }
    page,_:=repo.legacy_chain_list(repo.ctx,"account","chain",10)
    testing.expect(t,len(page)==1 && page[0].chain_id=="other","keyset paging")
    others,_:=repo.legacy_chain_list(repo.ctx,"someone_else","",10)
    testing.expect_value(t,len(others),0)
}
