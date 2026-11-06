package contracts

import "core:encoding/json"
import "core:testing"

@(test)
owner_linked_contracts_require_chain_scope_strict_versions_and_mutation_grant :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    fixture:=owner_fixture(t)
    for method in ([8]string{"linked.put","linked.delete","linked.restore","linked.read","linked.fetch","linked.backup","linked.facet.read","envelope.read"}) {
        c:=owner_fixture_document(t,fixture,"command")
        c["method"]=json.String(method);c["task_id"]=json.String("");c["expected_revision"]=json.String("1")
        testing.expect(t,owner_document_valid("command",c))
        c["task_id"]=json.String("task_1")
        testing.expect(t,!owner_document_valid("command",c))
        c["task_id"]=json.String("")
        grant:=owner_fixture_grant();grant.method=method;grant.task_id="";grant.can_mutate=false
        read:=method=="linked.read" || method=="linked.fetch" || method=="linked.backup" || method=="linked.facet.read" || method=="envelope.read"
        expected:Owner_Auth_Error=.Invalid_Scope
        if read do expected=.None
        testing.expect_value(t,owner_live_admit(c,grant,1000,1),expected)
    }
    for raw in ([5]string{
        `{"kind":"file","object_id":"a","revision":"1"}`,
        `{"kind":"artifact","object_id":"a","revision":"0"}`,
        `{"kind":"artifact","object_id":"a","revision":"01"}`,
        `{"kind":"artifact","object_id":"a","revision":"1","chain_id":"other"}`,
        `{"kind":"artifact","kind":"blob","object_id":"a","revision":"1"}`,
    }) {
        _,ok:=owner_parse(raw,"linked_delete");testing.expect(t,!ok)
    }
    _,ok:=owner_parse(`{"cursor":"","limit":"101"}`,"linked_page");testing.expect(t,!ok)
    _,ok=owner_parse(`{"kind":"artifact","object_id":"a","revision":"1","offset":"-1"}`,"linked_fetch");testing.expect(t,!ok)
}
