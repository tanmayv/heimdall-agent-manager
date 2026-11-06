#+feature dynamic-literals
package contracts

import "core:testing"
import "core:encoding/json"

@(test)
native_metadata_strict_source_shapes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for raw in ([6]string{string(#load("fixtures/owner-native-metadata-members.json")),string(#load("fixtures/owner-native-metadata-directories.json")),string(#load("fixtures/owner-native-metadata-chain.json")),string(#load("fixtures/owner-native-metadata-task.json")),string(#load("fixtures/owner-native-metadata-comment.json")),string(#load("fixtures/owner-native-metadata-summary.json"))}) {
        bundle,ok:=owner_metadata_import_parse(raw)
        testing.expect(t,ok && bundle.owner_user_id=="native_owner")
        root,_:=owner_content_document(raw);object,_:=root.(json.Object)
        items,_:=object["records"].(json.Array);row,_:=items[0].(json.Object)
        row["unknown"]=json.String("ignored")
        object["records"]=json.Array{row}
        changed,_:=json.marshal(object)
        _,valid:=owner_metadata_import_parse(string(changed));testing.expect(t,!valid)
        delete_key(&row,"unknown")
        row["owner_user_id"]=json.String("other")
        object["records"]=json.Array{row}
        changed,_=json.marshal(object)
        _,valid=owner_metadata_import_parse(string(changed));testing.expect(t,!valid)
        row["owner_user_id"]=json.String("native_owner")
        row["updated_at" if bundle.kind=="summary" else "created_at"]=json.Integer(123)
        object["records"]=json.Array{row}
        changed,_=json.marshal(object)
        _,valid=owner_metadata_import_parse(string(changed));testing.expect(t,!valid)
    }
    value,_:=owner_content_document(string(#load("fixtures/owner-native-metadata-directories.json")))
    bundle,_:=value.(json.Object);items,_:=bundle["records"].(json.Array);row,_:=items[0].(json.Object)
    row["vcs_info_json"]=json.String(`{"x":1,"x":2}`)
    bundle["records"]=json.Array{row}
    encoded,_:=json.marshal(bundle)
    _,valid:=owner_metadata_import_parse(string(encoded));testing.expect(t,!valid)
}

@(test)
native_metadata_fact_types_keys_and_nested_json_are_strict :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for kind in ([4]string{"chain","task","comment","summary"}) {
        // Use the rich fixture to establish a valid source record.
        raw:=""
        switch kind {
        case "chain": raw=string(#load("fixtures/owner-native-metadata-chain.json"))
        case "task": raw=string(#load("fixtures/owner-native-metadata-task.json"))
        case "comment": raw=string(#load("fixtures/owner-native-metadata-comment.json"))
        case "summary": raw=string(#load("fixtures/owner-native-metadata-summary.json"))
        }
        bundle,ok:=owner_metadata_import_parse(raw);if !testing.expect(t,ok) do return
        row:=bundle.records[0]
        for f in owner_metadata_fact_fields(kind) {
            before:=row[f.name]
            row[f.name]=json.Null{}
            testing.expect(t,!owner_metadata_fact_valid(row,kind))
            row[f.name]=before
            if f.kind=="integer" {
                row[f.name]=json.Integer(-1)
                testing.expect(t,!owner_metadata_fact_valid(row,kind))
                row[f.name]=json.String("1")
                testing.expect(t,!owner_metadata_fact_valid(row,kind))
            }
            if f.kind=="object" {
                row[f.name]=json.String(`{"x":1,"x":2}`)
                testing.expect(t,!owner_metadata_fact_valid(row,kind))
            }
            row[f.name]=before
        }
        value,_:=owner_content_document(raw);root,_:=value.(json.Object)
        root["records"]=json.Array{row,row}
        encoded,_:=json.marshal(root)
        _,valid:=owner_metadata_import_parse(string(encoded));testing.expect(t,!valid)
    }
}
