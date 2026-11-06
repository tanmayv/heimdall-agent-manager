#+feature dynamic-literals
package owner_local

import "core:strings"
import "core:testing"

@(test)
native_origin_unifies_history_and_metadata_in_both_import_orders :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for metadata_first in ([2]bool{false,true}) {
        f:=fixture(t);defer destroy(f);seed(t,f)
        members,_:=strings.replace_all(string(NATIVE_MEMBERS),"native_owner","original_user",context.temp_allocator)
        if metadata_first {
            testing.expect_value(t,native_metadata_test_call(f,members,"members","2").code,"ok")
        } else {
            testing.expect_value(t,native_import_call(f,native_history_fixture(),"history","1").code,"ok")
        }
        before:=native_metadata_test_state(f)
        revisions,_:=query(f.store.db,"SELECT (SELECT revision FROM task_chains WHERE chain_id='chain'),(SELECT revision FROM tasks WHERE task_id='task')")
        foreign_history,_:=strings.replace_all(native_history_fixture(),"original_user","forged_owner",context.temp_allocator)
        testing.expect_value(t,native_import_call(f,foreign_history,"wrong_history",revisions[0][1]).code,"operation_conflict")
        testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"wrong_members",revisions[0][0]).code,"operation_conflict")
        testing.expect_value(t,native_metadata_test_state(f),before)
        if metadata_first {
            testing.expect_value(t,native_import_call(f,native_history_fixture(),"history","1").code,"ok")
        } else {
            testing.expect_value(t,native_metadata_test_call(f,members,"members",revisions[0][0]).code,"ok")
        }
        rows,ok:=query(f.store.db,"SELECT count(*),owner_user_id FROM native_metadata_origins WHERE chain_id='chain'")
        testing.expect(t,ok && rows[0][0]=="1" && rows[0][1]=="original_user")
        close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
        testing.expect_value(t,native_import_call(f,foreign_history,"wrong_after_restart","2").code,"operation_conflict")
    }
}

@(test)
native_origin_creation_rolls_back_with_rejected_history :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    before:=native_metadata_test_state(f)
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER origin_history_fail BEFORE INSERT ON native_history_records BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"statement","1").code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER origin_history_fail; CREATE TABLE origin_parent(id INTEGER PRIMARY KEY); CREATE TABLE origin_ref(id INTEGER REFERENCES origin_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER origin_history_fail AFTER INSERT ON native_metadata_origins BEGIN INSERT INTO origin_ref VALUES(1); END"))
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"commit","1").code,"storage_error")
    testing.expect_value(t,native_metadata_test_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER origin_history_fail"))
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"other_owner_after_rollback","2").code,"ok")
}

@(test)
native_origin_reconciles_legacy_history_without_rewriting_source :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"legacy_history","1").code,"ok")
    // V17 imports predate native_metadata_origins. Reconstruct that precise
    // condition while retaining the original signed event and source rows.
    testing.expect(t,exec(f.store.db,"DROP TRIGGER native_metadata_origins_no_delete; DELETE FROM native_metadata_origins; CREATE TRIGGER native_metadata_origins_no_delete BEFORE DELETE ON native_metadata_origins BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END"))
    before,_:=query(f.store.db,"SELECT record_json,accepted_seq FROM native_history_records ORDER BY record_kind,record_key")
    state:=native_metadata_test_state(f)
    testing.expect_value(t,native_metadata_test_call(f,string(NATIVE_MEMBERS),"legacy_conflict","3").code,"operation_conflict")
    testing.expect_value(t,native_metadata_test_state(f),state)
    members,_:=strings.replace_all(string(NATIVE_MEMBERS),"native_owner","original_user",context.temp_allocator)
    testing.expect_value(t,native_metadata_test_call(f,members,"legacy_match","3").code,"ok")
    rows,ok:=query(f.store.db,"SELECT o.accepted_seq=(SELECT min(accepted_seq) FROM native_history_records WHERE chain_id=o.chain_id),o.owner_user_id FROM native_metadata_origins o")
    testing.expect(t,ok && rows[0][0]=="1" && rows[0][1]=="original_user")
    after,_:=query(f.store.db,"SELECT record_json,accepted_seq FROM native_history_records ORDER BY record_kind,record_key")
    testing.expect_value(t,encode(after),encode(before))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    rows,ok=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect(t,ok && len(rows)==0)
}

@(test)
native_origin_v19_migration_rejects_conflicting_legacy_owner_atomically :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"original_history","1").code,"ok")
    keep:="SELECT record_json,accepted_seq FROM native_history_records ORDER BY record_kind,record_key"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,V23_TEST_DROP))
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE local_chain_defaults_versions; DROP TABLE local_chain_summary_versions; DROP TRIGGER native_history_origin; DROP TABLE local_fleet_policy_sources; DROP TABLE native_fleet_policies; DROP TABLE native_fleet_snapshots; DROP TABLE local_task_priority_versions"))
    prefix:=string(MIGRATION_019);prefix=prefix[:strings.index(prefix,"CREATE TABLE native_fact_snapshots")]
    testing.expect(t,exec(db,prefix))
    // Older code allowed a history owner different from the metadata origin.
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=19; DROP TRIGGER native_metadata_origins_no_update; UPDATE native_metadata_origins SET owner_user_id='conflicting_owner'; CREATE TRIGGER native_metadata_origins_no_update BEFORE UPDATE ON native_metadata_origins BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='local_task_priority_versions') FROM runtime_database")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"19","19","0"}}))
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER native_metadata_origins_no_update; UPDATE native_metadata_origins SET owner_user_id='original_user'; CREATE TRIGGER native_metadata_origins_no_update BEFORE UPDATE ON native_metadata_origins BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
}
