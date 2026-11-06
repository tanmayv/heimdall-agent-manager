#+feature dynamic-literals
package contracts
import "core:encoding/json"
import "core:testing"

@(test)
owner_rich_aggregate_all_source_adapters_are_strict_and_tuple_keys_do_not_collide :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,ok:=owner_content_document(#load("fixtures/owner-native-aggregate.json",string))
    root,_:=v.(json.Object);metadata,_:=root["metadata"].(json.Array)
    if !testing.expect(t,ok && len(metadata)==18) do return
    for value in metadata {
        entry,_:=value.(json.Object);raw:=owner_string(entry,"raw")
        bundle,valid:=owner_metadata_import_parse(raw)
        if !testing.expect(t,valid,owner_string(entry,"kind")) do return
        b,_:=owner_content_document(raw);o,_:=b.(json.Object)
        records,_:=o["records"].(json.Array);row,_:=records[0].(json.Object)
        row["unknown_field"]=json.String("must not disappear")
        records[0]=row;o["records"]=records
        changed,_:=json.marshal(o,allocator=context.temp_allocator)
        _,valid=owner_metadata_import_parse(string(changed))
        testing.expect(t,!valid,"unknown source fields must reject, not truncate")
        delete_key(&row,"unknown_field");records[0]=row;o["records"]=records
        if len(records)>1 && (bundle.kind=="work_stage" || bundle.kind=="dependency") {
            first,_:=records[0].(json.Object);second,_:=records[1].(json.Object)
            testing.expect(t,owner_metadata_record_key(first,bundle.kind)!=owner_metadata_record_key(second,bundle.kind))
            o["records"]=json.Array{records[0],records[0]}
            duplicated,_:=json.marshal(o,allocator=context.temp_allocator)
            _,valid=owner_metadata_import_parse(string(duplicated));testing.expect(t,!valid)
        }
    }
}
