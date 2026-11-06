package sqlite

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

owner_registry_publish :: proc(ctx:rawptr,r:domain.Owner_Registry_Record) -> domain.Domain_Error {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    factory:SQLite_Unit_Of_Work_Factory
    uf:=new_unit_of_work_factory(&factory,impl.conn,nil)
    tx,opened,err:=iface.unit_of_work_begin(&uf)
    if !opened do return err
    done:=false
    defer { if !done do iface.unit_of_work_rollback(&tx) }
    sql:="INSERT OR IGNORE INTO owner_local_chains VALUES(?,?,?,?,?,?,?)"
    stmt:sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return domain.domain_error(.Internal_Error,"registry write failed")
    bind_text(stmt,1,r.chain_id);bind_text(stmt,2,r.account_id);bind_text(stmt,3,r.owner_bridge_id);bind_text(stmt,4,r.owner_key_id);bind_text(stmt,5,r.creator_id);bind_text(stmt,6,r.genesis_digest);bind_text(stmt,7,r.genesis_json)
    inserted:=sqlite3_step(stmt)==SQLITE_DONE
    sqlite3_finalize(stmt)
    if !inserted do return domain.domain_error(.Conflict,"registry genesis conflicts")
    rows,list_err:=owner_registry_list(ctx,r.account_id,r.chain_id,"","",1)
    defer { for &row in rows do owner_registry_destroy(&row); delete(rows) }
    if list_err.code!=.None do return list_err
    // Lookup includes the routing row even before its first title exists.
    if len(rows)!=1 || rows[0].owner_bridge_id!=r.owner_bridge_id || rows[0].owner_key_id!=r.owner_key_id || rows[0].genesis_digest!=r.genesis_digest || rows[0].creator_id!=r.creator_id do return domain.domain_error(.Conflict,"immutable registry binding conflicts")
    sql="INSERT INTO owner_local_titles VALUES(?,?,?,?) ON CONFLICT(chain_id,task_id) DO UPDATE SET metadata_revision=excluded.metadata_revision,registry_json=excluded.registry_json WHERE excluded.metadata_revision>owner_local_titles.metadata_revision"
    if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return domain.domain_error(.Internal_Error,"registry write failed")
    bind_text(stmt,1,r.chain_id);bind_text(stmt,2,r.task_id);sqlite3_bind_int64(stmt,3,r.metadata_revision);bind_text(stmt,4,r.registry_json)
    written:=sqlite3_step(stmt)==SQLITE_DONE
    sqlite3_finalize(stmt)
    if !written do return domain.domain_error(.Internal_Error,"registry write failed")
    // Same revision must be byte-identical; a lower revision is a harmless stale
    // outbox replay and can never replace a newer entry or deletion tombstone.
    sql="SELECT metadata_revision,registry_json FROM owner_local_titles WHERE chain_id=? AND task_id=?"
    if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return domain.domain_error(.Internal_Error,"registry read failed")
    bind_text(stmt,1,r.chain_id);bind_text(stmt,2,r.task_id)
    row_ok:=sqlite3_step(stmt)==SQLITE_ROW
    conflict:=!row_ok || (sqlite3_column_int64(stmt,0)==r.metadata_revision && column_text_unowned(stmt,1)!=r.registry_json)
    sqlite3_finalize(stmt)
    if conflict do return domain.domain_error(.Conflict,"metadata revision conflicts")
    committed,commit_err:=iface.unit_of_work_commit(&tx)
    done=committed
    return commit_err
}
owner_registry_destroy :: proc(r:^domain.Owner_Registry_Record) {
    delete(r.account_id);delete(r.chain_id);delete(r.owner_bridge_id);delete(r.owner_key_id);delete(r.creator_id)
    delete(r.genesis_digest);delete(r.genesis_json);delete(r.task_id);delete(r.registry_json)
}
owner_registry_list :: proc(ctx:rawptr,account,chain,after_chain,after_task:string,limit:int) -> ([]domain.Owner_Registry_Record,domain.Domain_Error) {
    impl:=(^Taskchain_Repo_SQLite)(ctx)
    sql:=`SELECT c.account_id,c.chain_id,c.owner_bridge_id,c.owner_key_id,c.creator_id,c.genesis_digest,c.genesis_json,
      COALESCE(t.task_id,''),COALESCE(t.registry_json,''),COALESCE(t.metadata_revision,0)
      FROM owner_local_chains c LEFT JOIN owner_local_titles t ON t.chain_id=c.chain_id
      WHERE c.account_id=? AND (?='' OR c.chain_id=?) AND (c.chain_id>? OR (c.chain_id=? AND COALESCE(t.task_id,'')>?))
      ORDER BY c.chain_id,COALESCE(t.task_id,'') LIMIT ?`
    stmt:sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=SQLITE_OK do return nil,domain.domain_error(.Internal_Error,"registry read failed")
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,account);bind_text(stmt,2,chain);bind_text(stmt,3,chain);bind_text(stmt,4,after_chain);bind_text(stmt,5,after_chain);bind_text(stmt,6,after_task);sqlite3_bind_int(stmt,7,i32(clamp(limit,1,100)))
    out:=make([dynamic]domain.Owner_Registry_Record)
    for {
        rc:=sqlite3_step(stmt)
        if rc==SQLITE_DONE do return out[:],{}
        if rc!=SQLITE_ROW { for &r in out do owner_registry_destroy(&r);delete(out);return nil,domain.domain_error(.Internal_Error,"registry read failed") }
        append(&out,domain.Owner_Registry_Record{column_text(stmt,0),column_text(stmt,1),column_text(stmt,2),column_text(stmt,3),column_text(stmt,4),column_text(stmt,5),column_text(stmt,6),column_text(stmt,7),column_text(stmt,8),sqlite3_column_int64(stmt,9)})
    }
}
