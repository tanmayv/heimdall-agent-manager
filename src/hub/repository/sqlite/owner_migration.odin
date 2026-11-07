package sqlite

import "core:fmt"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Bounded internal metadata queries. All returned values are request-temporary;
// no aggregate bodies or signed input envelopes pass through this helper.
legacy_metadata :: proc(conn:^Conn,sql:string,columns:int,args:..string) -> ([][]string,bool) {
    stmt:sqlite3_stmt
    if sqlite3_prepare_v2(conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return nil,false
    defer sqlite3_finalize(stmt)
    for arg,i in args do bind_text(stmt,i+1,arg)
    rows:=make([dynamic][]string,context.temp_allocator)
    for {
        rc:=sqlite3_step(stmt)
        if rc==SQLITE_DONE do return rows[:],true
        if rc!=SQLITE_ROW || len(rows)>=100000 do return nil,false
        row:=make([]string,columns,context.temp_allocator)
        for &v,i in row do v=strings.clone(column_text_unowned(stmt,i),context.temp_allocator)
        append(&rows,row)
    }
}
legacy_storage_error :: proc() -> domain.Domain_Error { return domain.domain_error(.Internal_Error,"legacy source fence storage failed") }
legacy_conflict :: proc() -> domain.Domain_Error { return domain.domain_error(.Conflict,"legacy source fence conflicts or remains unresolved") }

legacy_migration_select :: proc(ctx:rawptr,s:domain.Legacy_Migration_Selection) -> domain.Domain_Error {
    if s.account_id=="" || s.chain_id=="" || s.migration_id=="" || s.owner_bridge_id=="" || s.owner_key_id=="" || !contracts.owner_hex(s.selection_digest,64) || s.expected_work_revision<0 do return domain.domain_error(.Validation_Failed,"invalid legacy migration selection")
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,err:=iface.unit_of_work_begin(&uf)
    if !opened do return err
    committed:=false
    defer { if !committed do iface.unit_of_work_rollback(&tx) }
    rows,ok:=legacy_metadata(impl.conn,`SELECT account_id,chain_id,migration_id,owner_bridge_id,owner_key_id,selection_digest
      FROM owner_legacy_migrations WHERE migration_id=? OR chain_id=?`,6,s.migration_id,s.chain_id)
    if !ok do return legacy_storage_error()
    if len(rows)>0 {
        if len(rows)!=1 || rows[0][0]!=s.account_id || rows[0][1]!=s.chain_id || rows[0][2]!=s.migration_id || rows[0][3]!=s.owner_bridge_id || rows[0][4]!=s.owner_key_id || rows[0][5]!=s.selection_digest do return legacy_conflict()
        // Read-only exact replay does not restore the writer or reopen grants.
        return {}
    }
    rows,ok=legacy_metadata(impl.conn,`SELECT work_revision FROM task_chains WHERE chain_id=? AND owner_user_id=?
      AND NOT EXISTS(SELECT 1 FROM owner_local_chains WHERE chain_id=?)`,1,s.chain_id,s.account_id,s.chain_id)
    if !ok do return legacy_storage_error()
    if len(rows)!=1 || rows[0][0]!=fmt.tprintf("%d",s.expected_work_revision) do return legacy_conflict()
    _,ok=legacy_metadata(impl.conn,"INSERT OR IGNORE INTO owner_legacy_source_generations VALUES(?,?,0)",0,s.chain_id,s.account_id)
    if !ok do return legacy_storage_error()
    _,ok=legacy_metadata(impl.conn,`INSERT INTO owner_legacy_migrations(migration_id,chain_id,account_id,owner_bridge_id,owner_key_id,selection_digest,state,revision)
      VALUES(?,?,?,?,?,?,'draining',1)`,0,s.migration_id,s.chain_id,s.account_id,s.owner_bridge_id,s.owner_key_id,s.selection_digest)
    if !ok do return legacy_conflict()
    committed,err=iface.unit_of_work_commit(&tx)
    return err
}

legacy_source_get :: proc(ctx:rawptr,account,chain:string) -> (domain.Legacy_Source_Fence,bool,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    rows,ok:=legacy_metadata(impl.conn,`SELECT m.migration_id,m.owner_bridge_id,m.owner_key_id,m.selection_digest,m.state,m.quiescence_digest,m.revision,g.generation
      FROM owner_legacy_migrations m JOIN owner_legacy_source_generations g ON g.chain_id=m.chain_id AND g.account_id=m.account_id
      WHERE m.account_id=? AND m.chain_id=?`,8,account,chain)
    if !ok do return {},false,legacy_storage_error()
    if len(rows)==0 do return {},false,{}
    r:=rows[0]
    revision,_:=strconv.parse_i64(r[6]);generation,_:=strconv.parse_i64(r[7])
    return domain.Legacy_Source_Fence{selection={account_id=account,chain_id=chain,migration_id=r[0],owner_bridge_id=r[1],owner_key_id=r[2],selection_digest=r[3]},state=r[4],quiescence_digest=r[5],revision=revision,generation=generation},true,{}
}

legacy_effect_prepare :: proc(ctx:rawptr,e:domain.Legacy_Source_Effect) -> (i64,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    // Without the task transaction a crash can commit a task grant with no
    // corresponding effect fence. Refuse such a caller rather than repair it.
    if sqlite3_get_autocommit(impl.conn.db)!=0 do return 0,legacy_conflict()
    if !contracts.owner_field_valid(e.command_id,"id") do return 0,domain.domain_error(.Validation_Failed,"original legacy command identity required")
    if e.account_id=="" || e.chain_id=="" || e.effect_id=="" || e.bridge_id=="" || !contracts.owner_hex(e.input_digest,64) || (e.kind!="wake" && e.kind!="stop" && e.kind!="merge") do return 0,domain.domain_error(.Validation_Failed,"invalid source effect fence")
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,err:=iface.unit_of_work_begin(&uf)
    if !opened do return 0,err
    committed:=false
    defer { if !committed do iface.unit_of_work_rollback(&tx) }
    rows,ok:=legacy_metadata(impl.conn,"SELECT account_id,chain_id,bridge_id,kind,input_digest,generation,command_id FROM owner_legacy_source_effects WHERE effect_id=?",7,e.effect_id)
    if !ok do return 0,legacy_storage_error()
    if len(rows)>0 {
        r:=rows[0]
        if r[0]!=e.account_id || r[1]!=e.chain_id || r[2]!=e.bridge_id || r[3]!=e.kind || r[4]!=e.input_digest || r[6]!=e.command_id do return 0,legacy_conflict()
        n,_:=strconv.parse_i64(r[5]);return n,{}
    }
    rows,ok=legacy_metadata(impl.conn,"SELECT 1 FROM owner_legacy_source_effects WHERE account_id=? LIMIT 1 OFFSET 99999",1,e.account_id)
    if !ok do return 0,legacy_storage_error()
    if len(rows)>0 do return 0,domain.domain_error(.Conflict,"legacy source effect retention capacity reached; drain before further dispatch")
    rows,ok=legacy_metadata(impl.conn,"SELECT 1 FROM task_chains WHERE chain_id=? AND owner_user_id=?",1,e.chain_id,e.account_id)
    if !ok do return 0,legacy_storage_error()
    if len(rows)!=1 do return 0,legacy_conflict()
    _,ok=legacy_metadata(impl.conn,"INSERT OR IGNORE INTO owner_legacy_source_generations VALUES(?,?,0)",0,e.chain_id,e.account_id)
    if !ok do return 0,legacy_storage_error()
    rows,ok=legacy_metadata(impl.conn,"UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=? AND account_id=? RETURNING generation",1,e.chain_id,e.account_id)
    if !ok || len(rows)!=1 do return 0,legacy_storage_error()
    generation:=rows[0][0]
    _,ok=legacy_metadata(impl.conn,`INSERT INTO owner_legacy_source_effects(effect_id,chain_id,account_id,bridge_id,kind,input_digest,generation,state,command_id)
      VALUES(?,?,?,?,?,?,?,'outstanding',?)`,0,e.effect_id,e.chain_id,e.account_id,e.bridge_id,e.kind,e.input_digest,generation,e.command_id)
    if !ok do return 0,legacy_conflict()
    n,_:=strconv.parse_i64(generation)
    committed,err=iface.unit_of_work_commit(&tx)
    return n,err
}

legacy_source_freeze :: proc(ctx:rawptr,account,chain,migration,selection_digest,quiescence_digest:string,revision,generation:i64) -> domain.Domain_Error {
    if !contracts.owner_hex(selection_digest,64) || !contracts.owner_hex(quiescence_digest,64) || revision<1 || revision==0x7fffffffffffffff || generation<0 do return domain.domain_error(.Validation_Failed,"invalid source quiescence evidence")
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,err:=iface.unit_of_work_begin(&uf)
    if !opened do return err
    committed:=false
    defer { if !committed do iface.unit_of_work_rollback(&tx) }
    f,found,ferr:=legacy_source_get(ctx,account,chain)
    if ferr.code!=.None do return ferr
    if !found || f.selection.migration_id!=migration || f.selection.selection_digest!=selection_digest || f.generation!=generation do return legacy_conflict()
    if f.state=="frozen" {
        if f.revision!=revision+1 || f.quiescence_digest!=quiescence_digest do return legacy_conflict()
        return {}
    }
    if f.state!="draining" || f.revision!=revision do return legacy_conflict()
    rows,ok:=legacy_metadata(impl.conn,`SELECT 1 FROM task_leases WHERE chain_id=?
      UNION ALL SELECT 1 FROM owner_legacy_source_effects WHERE chain_id=? AND state='outstanding' LIMIT 1`,1,chain,chain)
    if !ok do return legacy_storage_error()
    if len(rows)>0 do return legacy_conflict()
    _,ok=legacy_metadata(impl.conn,`UPDATE owner_legacy_migrations SET state='frozen',revision=revision+1,frozen_generation=?,quiescence_digest=?
      WHERE chain_id=? AND account_id=? AND migration_id=? AND revision=? AND state='draining'`,0,fmt.tprintf("%d",generation),quiescence_digest,chain,account,migration,fmt.tprintf("%d",revision))
    if !ok do return legacy_conflict()
    committed,err=iface.unit_of_work_commit(&tx)
    return err
}
