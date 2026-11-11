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
