package owner_local

SCHEMA_VERSION :: 5
MIGRATION_005 :: #load("migration_005.sql")
MIGRATION_004 :: #load("migration_004.sql")
MIGRATION_003 :: #load("migration_003.sql")
MIGRATION_002 :: #load("migration_002.sql")

// Called only while the lifetime writer lock is held, before exposing Store.
// SQLite PRAGMAs that cannot change in a transaction precede all schema writes.
migrate :: proc(db:DB) -> bool {
    if !exec(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;") do return false
    if !exec(db,"BEGIN IMMEDIATE") do return false
    committed:=false
    defer { if !committed do _=exec(db,"ROLLBACK") }
    if !exec(db,"CREATE TABLE IF NOT EXISTS schema_migrations(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL CHECK(version>0))") do return false
    rows,ok:=query(db,"SELECT version FROM schema_migrations WHERE singleton=1")
    if !ok do return false
    version:i64
    if len(rows)>0 do version=number(rows[0][0])
    if version>SCHEMA_VERSION do return false
    if version==0 {
        if !exec(db,string(SCHEMA)) do return false
        if !exec(db,"INSERT INTO schema_migrations VALUES(1,1)") do return false
        version=1
    }
    if version==1 {
        if !exec(db,string(MIGRATION_002)) do return false
        orphans,checked:=query(db,"SELECT intent_id FROM runtime_intents WHERE principal_id='' LIMIT 1")
        if !checked || len(orphans)>0 do return false
        // Backfill exact digests before installing the immutable intent trigger.
        // The SQL migration deliberately leaves existing V1 payload bytes intact.
        rows,ok=query(db,"SELECT intent_id,payload_json FROM runtime_intents")
        if !ok do return false
        for row in rows {
            if _,ok=query(db,"UPDATE runtime_intents SET payload_digest=? WHERE intent_id=?",payload_hash(row[1]),row[0]);!ok do return false
        }
        if !exec(db,INTENT_IDENTITY_TRIGGER) do return false
        if !exec(db,"CREATE TRIGGER intent_settled_immutable BEFORE UPDATE ON runtime_intents WHEN OLD.state='settled' BEGIN SELECT RAISE(ABORT,'settled intent'); END;") do return false
        if _,ok=query(db,"UPDATE schema_migrations SET version=? WHERE singleton=1","2");!ok do return false
    }
    if version<=2 {
        if !exec(db,string(MIGRATION_003)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=3 WHERE singleton=1") do return false
    }
    if version<=3 {
        if !exec(db,string(MIGRATION_004)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=4 WHERE singleton=1") do return false
    }
    if version<=4 {
        if !exec(db,string(MIGRATION_005)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=5 WHERE singleton=1") do return false
    }
    if !exec(db,"COMMIT") do return false
    committed=true
    return true
}

INTENT_IDENTITY_TRIGGER :: `CREATE TRIGGER intent_identity_immutable BEFORE UPDATE ON runtime_intents
WHEN NEW.intent_id IS NOT OLD.intent_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.commit_seq IS NOT OLD.commit_seq
 OR NEW.principal_id IS NOT OLD.principal_id OR NEW.operation_id IS NOT OLD.operation_id OR NEW.kind IS NOT OLD.kind
 OR NEW.destination_bridge IS NOT OLD.destination_bridge OR NEW.exact_fence_json IS NOT OLD.exact_fence_json
 OR NEW.payload_json IS NOT OLD.payload_json OR NEW.payload_digest IS NOT OLD.payload_digest
BEGIN SELECT RAISE(ABORT,'immutable intent'); END;`
