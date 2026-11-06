package owner_local
import "core:strings"
import "core:testing"

@(test)
work_v22_upgrade_collision_and_deferred_commit_preserve_live_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    before,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_022);prefix=prefix[:strings.index(prefix,"CREATE TABLE local_chain_member_versions")]
    testing.expect(t,exec(db,V23_TEST_DROP))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=22; CREATE VIEW local_work_chains AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][2]string{{"22","22"}}))
    testing.expect(t,exec(db,"DROP VIEW local_work_chains; CREATE TABLE work_upgrade_parent(id INTEGER PRIMARY KEY); CREATE TABLE work_upgrade_ref(id INTEGER REFERENCES work_upgrade_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER work_upgrade_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=23 BEGIN INSERT INTO work_upgrade_ref VALUES(1); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_work_chains') FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"22","22","0"}}))
    testing.expect(t,exec(db,"DROP TRIGGER work_upgrade_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_:=query(f.store.db,"SELECT lease_id,capability_json,expires_ms,hard_ms,retired_seq FROM local_leases")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","after_work_upgrade",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}
