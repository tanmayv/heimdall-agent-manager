#+feature dynamic-literals
package sqlite

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:os"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
legacy_source_guard_inventory :: proc(t:^testing.T) {
    conn,opened,_:=open(":memory:")
    if !testing.expect(t,opened) do return
    defer close(&conn)
    migrated,err:=run_migrations(&conn)
    if !testing.expectf(t,migrated,"migration: %s",err.message) do return
    rows,ok:=legacy_metadata(&conn,`SELECT m.name,p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p
      WHERE m.type='table' AND p.name IN ('chain_id','task_chain_id','task_id','conversation_id') ORDER BY m.name,p.name`,2)
    testing.expect(t,ok)
    // These are independent producer/runtime metadata, derived search, or the
    // owner routing/fencing tables themselves. They are not canonical task
    // rows. The migration transport must separately drain runtime producers.
    exceptions:=map[string]bool{"agent_instances"=true,"shell_sessions"=true,"issues"=true,"task_chain_search_changes"=true,
      "owner_local_chains"=true,"owner_local_titles"=true,"owner_legacy_source_generations"=true,"owner_legacy_source_effects"=true,"owner_legacy_migrations"=true}
    defer delete(exceptions)
    for r in rows {
        if exceptions[r[0]] do continue
        for op in ([3]string{"insert","update","delete"}) {
            guards,found:=legacy_metadata(&conn,"SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?",1,fmt.tprintf("owner_legacy_guard_%s_%s",r[0],op))
            testing.expectf(t,found && len(guards)==1,"canonical scope %s.%s requires explicit %s guard",r[0],r[1],op)
        }
    }
}

legacy_seed_source :: proc(t:^testing.T,conn:^Conn) -> domain.Legacy_Migration_Selection {
    testing.expect(t,exec(conn,`INSERT INTO task_chains(chain_id,owner_user_id,title,kind,created_at,updated_at)
      VALUES('chain','account','source','mixed_work','time','time'),('other','account','other','mixed_work','time','time');
      INSERT INTO tasks(task_id,chain_id,owner_user_id,title,created_at,updated_at)
      VALUES('task','chain','account','source task','time','time'),('other_task','other','account','other task','time','time');`))
    s:=legacy_test_selection()
    rows,ok:=legacy_metadata(conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    if testing.expect(t,ok && len(rows)==1) {
        // work revision includes actual task creation, not an assumed schema default.
        s.expected_work_revision=legacy_test_number(rows[0][0])
    }
    return s
}

legacy_test_number :: proc(s:string)->i64 {
    n:i64
    for b in s do n=n*10+i64(b-'0')
    return n
}

@(test)
legacy_selection_freeze_cas_replay_and_canonical_write_backstops :: proc(t:^testing.T) {
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,s).code,domain.Error_Code.None)
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,s).code,domain.Error_Code.None)
    wrong:=s;wrong.owner_bridge_id="another"
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,wrong).code,domain.Error_Code.Conflict)
    wrong=s;wrong.account_id="another"
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,wrong).code,domain.Error_Code.Conflict)
    f,found,err:=repo.legacy_source_get(repo.ctx,"account","chain")
    testing.expect(t,found && err.code==.None && f.state=="draining" && f.revision==1)
    _,found,err=repo.legacy_source_get(repo.ctx,"another","chain")
    testing.expect(t,!found && err.code==.None)
    // Checkpointing/mutation can still drain, but it invalidates old generation evidence.
    testing.expect(t,exec(&conn,"UPDATE tasks SET title='during drain' WHERE task_id='task'"))
    old_generation:=f.generation
    f,_,_=repo.legacy_source_get(repo.ctx,"account","chain")
    testing.expect(t,f.generation>old_generation)
    proof:=strings.repeat("b",64,context.temp_allocator)
    testing.expect_value(t,repo.legacy_source_freeze(repo.ctx,"account","chain","migration",s.selection_digest,proof,1,old_generation).code,domain.Error_Code.Conflict)
    testing.expect_value(t,repo.legacy_source_freeze(repo.ctx,"account","chain","migration",s.selection_digest,proof,1,f.generation).code,domain.Error_Code.None)
    testing.expect_value(t,repo.legacy_source_freeze(repo.ctx,"account","chain","migration",s.selection_digest,proof,1,f.generation).code,domain.Error_Code.None)
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,s).code,domain.Error_Code.None)
    // Raw repository callers, timer folds, content producers and deletes cannot
    // bypass the frozen source merely by avoiding the new transport endpoint.
    for sql in ([6]string{
      "UPDATE tasks SET title='late' WHERE task_id='task'",
      "UPDATE task_chains SET title='late' WHERE chain_id='chain'",
      "DELETE FROM tasks WHERE task_id='task'",
      "INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,body,created_at,updated_at) VALUES('late','task','chain','account','late','time','time')",
      "INSERT INTO task_events(task_id,chain_id,owner_user_id,ts_ms,actor_kind,actor_id,kind,payload_json) VALUES('task','chain','account',1,'hub','','late','{}')",
      "INSERT INTO task_chain_members(chain_id,agent_instance_id,owner_user_id,created_at) VALUES('chain','instance','account','time')",
    }) { testing.expectf(t,!exec(&conn,sql),"frozen write must fail: %s",sql) }
    testing.expect(t,exec(&conn,"UPDATE tasks SET title='allowed' WHERE task_id='other_task'"))
    testing.expect(t,!exec(&conn,"UPDATE owner_legacy_migrations SET state='draining',revision=revision+1,quiescence_digest='' WHERE chain_id='chain'"),"no implicit source resume")
    testing.expect(t,!exec(&conn,"DELETE FROM owner_legacy_migrations WHERE chain_id='chain'"),"no fence deletion")
    testing.expect(t,!exec(&conn,"INSERT INTO task_comments(comment_id,task_id,chain_id,owner_user_id,body,created_at,updated_at) VALUES('false_scope','task','other','account','late','time','time')"),"task reference cannot evade frozen chain guard")
}

@(test)
legacy_source_schema_failure_rolls_back_all_guards_and_marker_then_retries :: proc(t:^testing.T) {
    for marker_failure in ([2]bool{false,true}) {
        conn,opened,_:=open(":memory:")
        if !testing.expect(t,opened) do return
        defer close(&conn)
        migrated,_:=run_migrations(&conn,stop_before="204_owner_legacy_source_fences.sql")
        if !testing.expect(t,migrated) do return
        _=legacy_seed_source(t,&conn)
        if marker_failure {
            testing.expect(t,exec(&conn,"CREATE TEMP TRIGGER reject_204_marker BEFORE INSERT ON schema_migrations WHEN NEW.version='204_owner_legacy_source_fences.sql' BEGIN SELECT RAISE(ABORT,'marker failure'); END"))
        } else {
            testing.expect(t,exec(&conn,"CREATE TRIGGER owner_legacy_guard_tasks_update BEFORE UPDATE ON tasks BEGIN SELECT 1; END"))
        }
        migrated,_=run_migrations(&conn)
        testing.expect(t,!migrated)
        testing.expect(t,!sqlite_object_exists(&conn,"owner_legacy_migrations"),"partial schema must roll back")
        testing.expect(t,!migration_applied(&conn,"204_owner_legacy_source_fences.sql"),"failed schema must not be marked applied")
        testing.expect_value(t,sqlite3_get_autocommit(conn.db),0+1)
        if marker_failure {
            testing.expect(t,exec(&conn,"DROP TRIGGER reject_204_marker"))
        } else {
            testing.expect(t,exec(&conn,"DROP TRIGGER owner_legacy_guard_tasks_update"))
        }
        migrated,_=run_migrations(&conn)
        testing.expect(t,migrated)
        testing.expect(t,migration_applied(&conn,"204_owner_legacy_source_fences.sql"))
        rows,ok:=legacy_metadata(&conn,"SELECT title FROM tasks WHERE task_id='task'",1)
        testing.expect(t,ok && len(rows)==1 && rows[0][0]=="source task")
    }
}

@(test)
legacy_source_frozen_state_and_write_refusal_survive_real_reopen :: proc(t:^testing.T) {
    home:=os.get_env("HOME",context.temp_allocator)
    path:=fmt.tprintf("%s/.cache/heimdall-tests/m4a-source-reopen-%d.sqlite",home,time.to_unix_nanoseconds(time.now()))
    defer { for suffix in ([3]string{"","-wal","-shm"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix)) }
    conn,opened,_:=open(path)
    if !testing.expect(t,opened) do return
    defer close(&conn)
    migrated,_:=run_migrations(&conn)
    if !testing.expect(t,migrated) do return
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,s).code,domain.Error_Code.None)
    f,_,_:=repo.legacy_source_get(repo.ctx,"account","chain")
    proof:=strings.repeat("b",64,context.temp_allocator)
    testing.expect_value(t,repo.legacy_source_freeze(repo.ctx,"account","chain","migration",s.selection_digest,proof,1,f.generation).code,domain.Error_Code.None)
    close(&conn)
    conn,opened,_=open(path)
    if !testing.expect(t,opened) do return
    migrated,_=run_migrations(&conn)
    testing.expect(t,migrated,"ordinary restart cannot implicitly resume a frozen source")
    restored,found,err:=repo.legacy_source_get(repo.ctx,"account","chain")
    testing.expect(t,found && err.code==.None && restored.state=="frozen" && restored.quiescence_digest==proof && restored.revision==2)
    testing.expect(t,!exec(&conn,"UPDATE tasks SET title='after restart' WHERE task_id='task'"))
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,s).code,domain.Error_Code.None)
}

@(test)
legacy_effect_fence_is_precommit_exact_replay_and_blocks_empty_lease_freeze :: proc(t:^testing.T) {
    conn,opened:=tmpl_clone_migrated(t)
    if !opened do return
    defer close(&conn)
    s:=legacy_seed_source(t,&conn)
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    effect:=domain.Legacy_Source_Effect{account_id="account",chain_id="chain",effect_id="effect",bridge_id="executor",kind="merge",input_digest=strings.repeat("c",64,context.temp_allocator)}
    _,err:=repo.legacy_effect_prepare(repo.ctx,effect)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,&conn,nil)
    tx,txok,_:=iface.unit_of_work_begin(&uf)
    if !testing.expect(t,txok) do return
    generation:i64
    generation,err=repo.legacy_effect_prepare(repo.ctx,effect)
    testing.expect(t,err.code==.None && generation>0)
    same,replay_err:=repo.legacy_effect_prepare(repo.ctx,effect)
    testing.expect(t,replay_err.code==.None && same==generation)
    changed:=effect;changed.input_digest=strings.repeat("d",64,context.temp_allocator)
    _,err=repo.legacy_effect_prepare(repo.ctx,changed)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    iface.unit_of_work_rollback(&tx)
    rows,ok:=legacy_metadata(&conn,"SELECT 1 FROM owner_legacy_source_effects",1)
    testing.expect(t,ok && len(rows)==0,"rolled-back grant cannot leave an effect fence")
    tx,txok,_=iface.unit_of_work_begin(&uf)
    if !testing.expect(t,txok) do return
    generation,err=repo.legacy_effect_prepare(repo.ctx,effect)
    testing.expect_value(t,err.code,domain.Error_Code.None)
    committed,_:=iface.unit_of_work_commit(&tx)
    testing.expect(t,committed)
    testing.expect_value(t,repo.legacy_migration_select(repo.ctx,s).code,domain.Error_Code.None)
    proof:=strings.repeat("b",64,context.temp_allocator)
    testing.expect_value(t,repo.legacy_source_freeze(repo.ctx,"account","chain","migration",s.selection_digest,proof,1,generation).code,domain.Error_Code.Conflict)
    // The future verified executor-drain admission is the only intended caller
    // of retirement. This storage test supplies its already-verified digest.
    testing.expect(t,exec(&conn,fmt.tprintf("UPDATE owner_legacy_source_effects SET state='retired',retirement_digest='%s' WHERE effect_id='effect'",proof)))
    testing.expect_value(t,repo.legacy_source_freeze(repo.ctx,"account","chain","migration",s.selection_digest,proof,1,generation).code,domain.Error_Code.None)
    tx,txok,_=iface.unit_of_work_begin(&uf)
    if !testing.expect(t,txok) do return
    same,replay_err=repo.legacy_effect_prepare(repo.ctx,effect)
    testing.expect(t,replay_err.code==.None && same==generation,"retired exact replay never issues another effect")
    changed=effect;changed.effect_id="late"
    _,err=repo.legacy_effect_prepare(repo.ctx,changed)
    testing.expect_value(t,err.code,domain.Error_Code.Conflict)
    iface.unit_of_work_rollback(&tx)
}

legacy_test_selection :: proc() -> domain.Legacy_Migration_Selection {
    return {account_id="account",chain_id="chain",migration_id="migration",owner_bridge_id="bridge",owner_key_id="key",selection_digest=strings.repeat("a",64,context.temp_allocator),expected_work_revision=1}
}
