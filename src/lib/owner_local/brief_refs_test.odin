#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

pinned_brief :: proc(refs:[]string) -> string {
    o:=doc(map[string]string{"goal"="Use immutable evidence"})
    o["acceptance"]=json.Array{json.String("Preserve pins")}
    a:=make(json.Array,0,len(refs),context.temp_allocator)
    for ref in refs do append(&a,json.String(ref))
    o["inputs"]=a
    return encode(o)
}
pinned_edit :: proc(f:^Fixture,refs:[]string,op:string,revision:string="5") -> Result {
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,pinned_brief(refs))}))
    return invoke(f,command(f,"requirements.edit",op,"task",p,revision),p)
}
@(test)
brief_input_pins_authorize_local_chain_and_reject_mutable_missing_or_ambiguous_refs :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"pinned_import","4").code,"ok")
    before:=metadata_state(f)
    for ref in ([7]string{"output:task","output:task:3","output:other:3:1","output:task:9:1","facet:task:3:output","facet:task:3:unknown:1","#999999999"}) {
        got:=pinned_edit(f,[]string{ref},fmt.tprintf("reject_%d",len(ref)))
        testing.expect(t,got.code=="invalid_scope" || got.code=="invalid_content")
        testing.expect_value(t,metadata_state(f),before)
    }
    refs:=[]string{"output:task:3:1"}
    got:=pinned_edit(f,refs,"pinned_accept")
    if !testing.expect_value(t,got.code,"ok") do return
    pinned,ok:=brief_inputs_read(&f.store,"chain","task","2",pinned_brief(refs))
    testing.expect(t,ok && strings.contains(pinned,"native_history") && strings.contains(pinned,"import_pending"))
    testing.expect(t,metadata_replay(f,"pinned_accept").replay)
    // A different owner-local chain cannot read this retained immutable record.
    _,code:=brief_inputs_resolve(&f.store,"other_chain",pinned_brief(refs))
    testing.expect_value(t,code,"invalid_scope")
    testing.expect(t,!exec(f.store.db,"UPDATE local_brief_inputs SET inputs_json='[]'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_brief_inputs"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,found:=brief_inputs_read(&f.store,"chain","task","2",pinned_brief(refs))
    testing.expect(t,found)
    testing.expect_value(t,after,pinned)
    // Present pinned records through the actual signed child boundary.
    child:=lease_child()
    present:=lifecycle_call(f,child,"requirements.present","pinned_present",`{"requirements_revision":"2"}`,cap,"6")
    testing.expect_value(t,present.code,"ok")
    v,_:=contracts.owner_content_document(present.body);o,_:=v.(json.Object)
    testing.expect_value(t,field(o,"resolved_inputs"),pinned)
}
@(test)
brief_input_pin_statement_and_commit_rollback_are_atomic_with_requirements :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    testing.expect_value(t,native_import_call(f,native_history_fixture(),"pin_rollback_import","4").code,"ok")
    before:=metadata_state(f)
    pins,_:=query(f.store.db,"SELECT * FROM local_brief_inputs")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER pin_fail BEFORE INSERT ON local_events WHEN NEW.kind='requirements.edit' BEGIN SELECT RAISE(ABORT,'fixture'); END"))
    testing.expect_value(t,pinned_edit(f,[]string{"output:task:3:1"},"pin_statement").code,"storage_error")
    testing.expect_value(t,metadata_state(f),before)
    testing.expect(t,exec(f.store.db,"DROP TRIGGER pin_fail; CREATE TABLE pin_parent(id INTEGER PRIMARY KEY); CREATE TABLE pin_ref(id INTEGER REFERENCES pin_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER pin_fail AFTER INSERT ON local_brief_inputs BEGIN INSERT INTO pin_ref VALUES(1); END"))
    testing.expect_value(t,pinned_edit(f,[]string{"output:task:3:1"},"pin_commit").code,"storage_error")
    testing.expect_value(t,metadata_state(f),before)
    after,_:=query(f.store.db,"SELECT * FROM local_brief_inputs")
    testing.expect_value(t,encode(after),encode(pins))
}

@(test)
brief_native_facet_shorthand_pins_unique_version_before_later_import :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    bundle,_:=contracts.owner_parse(native_history_fixture(),"native_history_bundle")
    v,_:=contracts.owner_request_document(field(bundle,"facets"));facets,_:=v.(json.Array)
    first,second:="",""
    for value in facets {
        raw,_:=value.(json.String)
        row,_:=contracts.owner_parse(string(raw),"native_history_facet")
        if field(row,"kind")=="output" && field(row,"attempt_no")=="3" {
            if field(row,"v")=="1" do first=string(raw)
            if field(row,"v")=="2" do second=string(raw)
        }
    }
    bundle["facets"]=json.String(encode([1]string{first}));bundle["events"]=json.String("[]")
    testing.expect_value(t,native_import_call(f,encode(bundle),"unique_facet_import","4").code,"ok")
    refs:=[]string{"facet:task:3:output"}
    testing.expect_value(t,pinned_edit(f,refs,"unique_facet_pin").code,"ok")
    pinned,found:=brief_inputs_read(&f.store,"chain","task","2",pinned_brief(refs))
    testing.expect(t,found)
    bundle["source_revision"]=json.String("snapshot_8");bundle["facets"]=json.String(encode([1]string{second}))
    testing.expect_value(t,native_import_call(f,encode(bundle),"later_facet_import","6").code,"ok")
    _,code:=brief_inputs_resolve(&f.store,"chain",pinned_brief(refs))
    testing.expect_value(t,code,"invalid_content")
    after,ok:=brief_inputs_read(&f.store,"chain","task","2",pinned_brief(refs))
    testing.expect(t,ok);testing.expect_value(t,after,pinned)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,ok=brief_inputs_read(&f.store,"chain","task","2",pinned_brief(refs))
    testing.expect(t,ok);testing.expect_value(t,after,pinned)
}
