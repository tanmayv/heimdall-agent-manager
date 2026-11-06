#+feature dynamic-literals
package contracts

import "core:testing"
import "core:encoding/json"

@(test)
native_metadata_strict_source_shapes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for raw in ([2]string{string(#load("fixtures/owner-native-metadata-members.json")),string(#load("fixtures/owner-native-metadata-directories.json"))}) {
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
        row["created_at"]=json.Integer(123)
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
