package owner_local

import "core:fmt"
import "core:sync"

// A handle is valid only while it is Store.active on its owning thread. Nested
// candidates are explicit savepoints; releasing one never commits the parent.
Transaction :: struct {
    store:^Store,
    parent:^Transaction,
    thread:int,
    serial:i64,
    base_seq:i64,
}
transaction_begin :: proc(s:^Store,tx:^Transaction) -> bool {
    if tx.store!=nil || sync.atomic_load(&s.tx_thread)==sync.current_thread_id() do return false
    sync.mutex_lock(&s.mutex)
    if s.db==nil || s.unusable || s.tx_serial==0x7fffffffffffffff {
        storage_failure_note(s,"begin refused: store closed or unusable")
        sync.mutex_unlock(&s.mutex);return false
    }
    if !exec(s.db,"BEGIN IMMEDIATE") { storage_failure_note(s,"begin");sync.mutex_unlock(&s.mutex);return false }
    rows,ok:=query(s.db,"SELECT account_id,owner_bridge_id,owner_key_id,incarnation,commit_seq FROM runtime_database WHERE singleton=1")
    if !ok || len(rows)!=1 || rows[0][0]!=s.account || rows[0][1]!=s.owner || rows[0][2]!=s.owner_key || number(rows[0][3])!=s.incarnation {
        storage_failure_note(s,"begin: runtime identity or incarnation differs" if ok else "begin")
        _=exec(s.db,"ROLLBACK");sync.mutex_unlock(&s.mutex);return false
    }
    s.tx_serial+=1
    tx^=Transaction{s,nil,sync.current_thread_id(),s.tx_serial,number(rows[0][4])}
    s.active=tx
    sync.atomic_store(&s.tx_thread,tx.thread)
    return true
}
transaction_current :: proc(tx:^Transaction) -> bool {
    return tx!=nil && tx.store!=nil && tx.thread==sync.current_thread_id() && tx.store.active==tx
}
transaction_savepoint :: proc(parent,child:^Transaction) -> bool {
    if !transaction_current(parent) || child.store!=nil do return false
    s:=parent.store
    if s.tx_failed || s.tx_serial==0x7fffffffffffffff do return false
    s.tx_serial+=1
    if !exec(s.db,fmt.tprintf("SAVEPOINT candidate_%d",s.tx_serial)) do return false
    child^=Transaction{s,parent,parent.thread,s.tx_serial,parent.base_seq}
    s.active=child
    return true
}
transaction_commit :: proc(tx:^Transaction) -> bool {
    if !transaction_current(tx) do return false
    s:=tx.store
    if s.tx_failed {transaction_rollback(tx);return false}
    sql:="COMMIT"
    if tx.parent!=nil do sql=fmt.tprintf("RELEASE candidate_%d",tx.serial)
    if !exec(s.db,sql) { transaction_rollback(tx);return false }
    s.active=tx.parent
    tx.store=nil
    if tx.parent==nil {sync.atomic_store(&s.tx_thread,0);sync.mutex_unlock(&s.mutex)}
    return true
}
transaction_rollback :: proc(tx:^Transaction) {
    if !transaction_current(tx) do return
    s:=tx.store
    if tx.parent!=nil {
        if !exec(s.db,fmt.tprintf("ROLLBACK TO candidate_%d; RELEASE candidate_%d",tx.serial,tx.serial)) do s.tx_failed=true
    } else {
        // Before ROLLBACK replaces the connection's error state.
        storage_failure_note(s,"rollback")
        _=exec(s.db,"ROLLBACK")
        // SQLITE_FULL can already have rolled back automatically. A connection
        // still in a transaction after rollback is quarantined until reopen.
        if sqlite3_get_autocommit(s.db)==0 do s.unusable=true
        s.tx_failed=false
    }
    s.active=tx.parent
    tx.store=nil
    if tx.parent==nil {sync.atomic_store(&s.tx_thread,0);sync.mutex_unlock(&s.mutex)}
}

// Records why a transaction did not commit: the step plus the connection's
// current SQLite error (of conn, default the store connection). Caller holds
// Store.mutex or owns the Store exclusively (open). Never allocates.
storage_failure_note :: proc(s:^Store,step:string,conn:DB=nil) {
    db:=conn if conn!=nil else s.db
    code:i32=-1
    msg:cstring="no connection"
    if db!=nil { code=i32(sqlite3_extended_errcode(db));msg=sqlite3_errmsg(db) }
    text:=fmt.bprintf(s.last_failure[:],"%s: sqlite %d %s (unusable=%v)",step,code,msg,s.unusable)
    s.last_failure_len=len(text)
}

// storage_diagnostic describes the store's state and the last uncommitted
// transaction, for logging a storage_error. Never blocks: a transaction still
// held (by any thread) is itself reported. Temp-allocated.
storage_diagnostic :: proc(s:^Store) -> string {
    if !sync.mutex_try_lock(&s.mutex) do return fmt.tprintf("transaction held by thread %d",sync.atomic_load(&s.tx_thread))
    defer sync.mutex_unlock(&s.mutex)
    return fmt.tprintf("open=%v unusable=%v last_failure=%q",s.db!=nil,s.unusable,string(s.last_failure[:s.last_failure_len]))
}
