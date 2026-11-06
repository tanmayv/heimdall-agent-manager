package contracts
import "core:encoding/json"
import "core:testing"
@(test)
executor_shared_strict_wire_vectors :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    v,ok:=owner_content_document(#load("fixtures/executor-v1.json",string));root,_:=v.(json.Object)
    if !testing.expect(t,ok) do return
    good,_:=root["valid"].(json.Array)
    for item in good {
        row,_:=item.(json.Object);kind:=owner_string(row,"kind")
        o,valid:=executor_parse(owner_string(row,"raw"),kind)
        if !testing.expect(t,valid) do return
        canonical,c_ok:=executor_canonical(kind,o);testing.expect(t,c_ok)
        testing.expect_value(t,canonical,owner_string(row,"canonical"))
        digest,d_ok:=executor_digest(kind,o);testing.expect(t,d_ok)
        testing.expect_value(t,digest,owner_string(row,"digest"))
    }
    bad,_:=root["invalid"].(json.Array)
    for item in bad {
        row,_:=item.(json.Object);_,valid:=executor_parse(owner_string(row,"raw"),owner_string(row,"kind"))
        testing.expect(t,!valid,owner_string(row,"name"))
    }
}
