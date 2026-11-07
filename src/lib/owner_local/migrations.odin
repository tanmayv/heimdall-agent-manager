package owner_local

import "core:encoding/json"

SCHEMA_VERSION :: 33
MIGRATION_033 :: #load("migration_033.sql")
MIGRATION_032 :: #load("migration_032.sql")
MIGRATION_031 :: #load("migration_031.sql")
MIGRATION_030 :: #load("migration_030.sql")
MIGRATION_029 :: #load("migration_029.sql")
MIGRATION_028 :: #load("migration_028.sql")
MIGRATION_027 :: #load("migration_027.sql")
MIGRATION_026 :: #load("migration_026.sql")
MIGRATION_025 :: #load("migration_025.sql")
MIGRATION_024 :: #load("migration_024.sql")
MIGRATION_023 :: #load("migration_023.sql")
MIGRATION_022 :: #load("migration_022.sql")
MIGRATION_021 :: #load("migration_021.sql")
MIGRATION_020 :: #load("migration_020.sql")
MIGRATION_019 :: #load("migration_019.sql")
MIGRATION_018 :: #load("migration_018.sql")
MIGRATION_017 :: #load("migration_017.sql")
MIGRATION_016 :: #load("migration_016.sql")
MIGRATION_015 :: #load("migration_015.sql")
MIGRATION_014 :: #load("migration_014.sql")
MIGRATION_013 :: #load("migration_013.sql")
MIGRATION_012 :: #load("migration_012.sql")
MIGRATION_011 :: #load("migration_011.sql")
MIGRATION_010 :: #load("migration_010.sql")
MIGRATION_009 :: #load("migration_009.sql")
MIGRATION_008 :: #load("migration_008.sql")
MIGRATION_007 :: #load("migration_007.sql")
MIGRATION_006 :: #load("migration_006.sql")
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
    if version<=5 {
        if !exec(db,string(MIGRATION_006)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=6 WHERE singleton=1") do return false
    }
    if version<=6 {
        if !exec(db,string(MIGRATION_007)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=7 WHERE singleton=1") do return false
    }
    if version<=7 {
        if !exec(db,string(MIGRATION_008)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=8 WHERE singleton=1") do return false
    }
    if version<=8 {
        if !exec(db,string(MIGRATION_009)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=9 WHERE singleton=1") do return false
    }
    if version<=9 {
        if !exec(db,string(MIGRATION_010)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=10 WHERE singleton=1") do return false
    }
    if version<=10 {
        if !exec(db,string(MIGRATION_011)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=11 WHERE singleton=1") do return false
    }
    if version<=11 {
        if !exec(db,string(MIGRATION_012)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=12 WHERE singleton=1") do return false
    }
    if version<=12 {
        if !exec(db,string(MIGRATION_013)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=13 WHERE singleton=1") do return false
    }
    if version<=13 {
        if !exec(db,string(MIGRATION_014)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=14 WHERE singleton=1") do return false
    }
    if version<=14 {
        if !exec(db,string(MIGRATION_015)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=15 WHERE singleton=1") do return false
    }
    if version<=15 {
        if !exec(db,string(MIGRATION_016)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=16 WHERE singleton=1") do return false
    }
    if version<=16 {
        if !exec(db,string(MIGRATION_017)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=17 WHERE singleton=1") do return false
    }
    if version<=17 {
        if !exec(db,string(MIGRATION_018)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=18 WHERE singleton=1") do return false
    }
    if version<=18 {
        if !exec(db,string(MIGRATION_019)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=19 WHERE singleton=1") do return false
    }
    if version<=19 {
        if !exec(db,string(MIGRATION_020)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=20 WHERE singleton=1") do return false
    }
    if version<=20 {
        if !exec(db,string(MIGRATION_021)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=21 WHERE singleton=1") do return false
    }
    if version<=21 {
        if !exec(db,string(MIGRATION_022)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=22 WHERE singleton=1") do return false
    }
    if version<=22 {
        if !exec(db,string(MIGRATION_023)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=23 WHERE singleton=1") do return false
    }
    if version<=23 {
        if !exec(db,string(MIGRATION_024)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=24 WHERE singleton=1") do return false
    }
    if version<=24 {
        if !exec(db,string(MIGRATION_025)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=25 WHERE singleton=1") do return false
    }
    if version<=25 {
        if !exec(db,string(MIGRATION_026)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=26 WHERE singleton=1") do return false
    }
    if version<=26 {
        if !exec(db,string(MIGRATION_027)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=27 WHERE singleton=1") do return false
    }
    if version<=27 {
        if !exec(db,string(MIGRATION_028)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=28 WHERE singleton=1") do return false
    }
    if version<=28 {
        if !migration_029_release_budget_controls(db) do return false
        if !exec(db,string(MIGRATION_029)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=29 WHERE singleton=1") do return false
    }
    if version<=29 {
        // Re-runnable: the column may survive a test downgrade of the version.
        columns,read:=query(db,"SELECT 1 FROM pragma_table_info('chain_genesis') WHERE name='import_manifest_hash'")
        if !read do return false
        if len(columns)==0 && !exec(db,"ALTER TABLE chain_genesis ADD COLUMN import_manifest_hash TEXT NOT NULL DEFAULT ''") do return false
        if !exec(db,string(MIGRATION_030)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=30 WHERE singleton=1") do return false
    }
    if version<=30 {
        columns,read:=query(db,"SELECT 1 FROM pragma_table_info('task_comments') WHERE name='created_at'")
        if !read do return false
        if len(columns)==0 && !exec(db,"ALTER TABLE task_comments ADD COLUMN created_at TEXT NOT NULL DEFAULT ''") do return false
        if !exec(db,string(MIGRATION_031)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=31 WHERE singleton=1") do return false
    }
    if version<=31 {
        if !exec(db,string(MIGRATION_032)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=32 WHERE singleton=1") do return false
    }
    if version<=32 {
        if !exec(db,string(MIGRATION_033)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=33 WHERE singleton=1") do return false
    }
    if !exec(db,"COMMIT") do return false
    committed=true
    return true
}

// V29 removes the owner-local attempt budget. A task blocked only by the budget
// overlay must not stay stuck once that overlay's table is gone: restore the
// independent control the overlay saved (prior_json), or clear the overlay.
// The table may be absent when an older schema never created it.
migration_029_release_budget_controls :: proc(db:DB) -> bool {
    present,ok:=query(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='budget_control_owners'")
    if !ok do return false
    if len(present)>0 {
        owners,read:=query(db,"SELECT chain_id,task_id,reason,prior_json FROM budget_control_owners ORDER BY chain_id,task_id")
        if !read do return false
        for owner in owners {
            chain,task,reason:=owner[0],owner[1],owner[2]
            prior:[dynamic][]string
            if json.unmarshal_string(owner[3],&prior,.JSON,context.temp_allocator)!=nil do return false
            if len(prior)>1 || (len(prior)==1 && len(prior[0])!=4) do return false
            controls,found:=query(db,"SELECT mode,reason FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
            if !found do return false
            if len(controls)!=1 do continue
            if controls[0][0]=="held" {
                // A hold placed over the overlay resumes to the saved control.
                resume,waiting:="ready",""
                if len(prior)==1 { resume=prior[0][0];waiting=prior[0][3];if resume=="held" do resume=prior[0][1] }
                if _,ok=query(db,"UPDATE local_controls SET resume_state=?,waiting_on=? WHERE chain_id=? AND task_id=?",resume,waiting,chain,task);!ok do return false
            } else if controls[0][0]=="blocked" && controls[0][1]==reason {
                if len(prior)==0 {
                    if _,ok=query(db,"DELETE FROM local_controls WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
                } else if _,ok=query(db,"UPDATE local_controls SET mode=?,resume_state=?,reason=?,waiting_on=? WHERE chain_id=? AND task_id=?",prior[0][0],prior[0][1],prior[0][2],prior[0][3],chain,task);!ok do return false
            } else do continue
            if _,ok=query(db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
        }
    }
    // Only owner rows identify overlay blocks. A block without one is a genuine
    // lease.block whose free-text reason may coincide with a budget word, so it
    // is left untouched.
    return true
}

INTENT_IDENTITY_TRIGGER :: `CREATE TRIGGER intent_identity_immutable BEFORE UPDATE ON runtime_intents
WHEN NEW.intent_id IS NOT OLD.intent_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.commit_seq IS NOT OLD.commit_seq
 OR NEW.principal_id IS NOT OLD.principal_id OR NEW.operation_id IS NOT OLD.operation_id OR NEW.kind IS NOT OLD.kind
 OR NEW.destination_bridge IS NOT OLD.destination_bridge OR NEW.exact_fence_json IS NOT OLD.exact_fence_json
 OR NEW.payload_json IS NOT OLD.payload_json OR NEW.payload_digest IS NOT OLD.payload_digest
BEGIN SELECT RAISE(ABORT,'immutable intent'); END;`
