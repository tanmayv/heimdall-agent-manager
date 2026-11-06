package contracts
import "core:encoding/json"
import "core:testing"
@(test)
owner_work_shared_strict_documents :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,parsed:=owner_content_document(string(#load("fixtures/owner-work.json")))
    if !testing.expect(t,parsed) do return
    cases,_:=v.(json.Array)
    for value in cases {
        item,_:=value.(json.Object);expected,_:=item["valid"].(json.Boolean)
        _,valid:=owner_work_document(owner_string(item,"raw"),owner_string(item,"method"))
        testing.expect(t,valid==bool(expected),owner_string(item,"raw"))
    }
}
