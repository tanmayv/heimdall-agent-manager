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

@(test)
legacy_import_freeze_refuses_busy_chain_without_any_write :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    testing.expect(t,exec(&conn,`
      INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery)
        VALUES('lease','task','chain','account',1,'inst','work','g','e','h','wake');
      UPDATE tasks SET state='in_review' WHERE task_id='task';
      BEGIN;
      INSERT INTO workflow_runs(run_id,chain_id,owner_user_id,title,definition_ref,spec_json,inputs_json,current_execution_no,request_id,request_hash,created_by_kind,created_by_id,created_at,updated_at,revision)
        VALUES('run','chain','account','Run','def:1','{}','{}',1,'req','hash','user','account','c','u',1);
      INSERT INTO workflow_run_executions(run_id,execution_no,chain_id,owner_user_id,state,resolved_inputs_json,output_manifest_json,revision)
        VALUES('run',1,'chain','account','running','{}','{}',1);
      COMMIT;`))
    rows,_:=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    _,blockers,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect_value(t,err.code,domain.Error_Code.None)
    codes:=make([dynamic]string,context.temp_allocator)
    for b in blockers do append(&codes,b.code)
    testing.expect_value(t,strings.join(codes[:],",",context.temp_allocator),"live_leases,running_workflows,tasks_in_review")
    _,found,_:=repo.legacy_source_get(repo.ctx,"account","chain")
    testing.expect(t,!found,"a refused selection writes nothing and never strands the chain draining")
    testing.expect(t,exec(&conn,"UPDATE tasks SET title='still writable' WHERE task_id='task'"))
    // Once idle, the same selection freezes in one transaction.
    testing.expect(t,exec(&conn,"DELETE FROM task_leases; UPDATE tasks SET state='ready'; UPDATE workflow_run_executions SET state='succeeded',revision=2"))
    rows,_=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    f,none,ferr:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect(t,ferr.code==.None && len(none)==0 && f.state=="frozen" && contracts.owner_hex(f.quiescence_digest,64))
    replay,_,rerr:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect(t,rerr.code==.None && replay.revision==f.revision && replay.quiescence_digest==f.quiescence_digest,"exact replay is read-only")
    other:=s;other.owner_bridge_id="another"
    _,_,cerr:=repo.legacy_migration_freeze_now(repo.ctx,other)
    testing.expect_value(t,cerr.code,domain.Error_Code.Conflict)
}

@(test)
legacy_import_frozen_writes_rejected_and_pending_merge_blocks :: proc(t:^testing.T) {
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
    testing.expect(t,exec(&conn,"INSERT INTO task_events(task_id,chain_id,owner_user_id,ts_ms,actor_kind,actor_id,kind,payload_json) VALUES('task','chain','account',2,'hub','','merged','{}')"))
    rows,_:=legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    s.expected_work_revision=legacy_test_number(rows[0][0])
    f,blocked,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    testing.expect(t,err.code==.None && len(blocked)==0 && f.state=="frozen")
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
