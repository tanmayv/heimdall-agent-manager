package contracts

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

owner_export_test_manifest :: proc(doc_raw:string,rows:i64)->Owner_Migration_Manifest {
    kinds:=make([dynamic]Owner_Migration_Kind_Count,context.temp_allocator)
    for k in OWNER_MIGRATION_EXPORT_KINDS do append(&kinds,Owner_Migration_Kind_Count{k.kind,k.table,1 if k.kind=="chain" else 0})
    refs:=make([dynamic]Owner_Migration_Document_Ref,context.temp_allocator)
    append(&refs,Owner_Migration_Document_Ref{0,"chain",rows,i64(len(doc_raw)),owner_payload_digest(doc_raw)})
    return {OWNER_MIGRATION_EXPORT_FORMAT,"acct","chain","mig",strings.repeat("a",64,context.temp_allocator),0,3,kinds[:],refs[:],OWNER_MIGRATION_ARCHIVAL_ONLY[:]}
}

@(test)
owner_migration_manifest_and_documents_are_strict :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    doc:=fmt.tprintf(`{{"format":"%s","kind":"chain","index":0,"rows":[{{"chain_id":"chain","work_revision":3,"pinned_at":null}}]}}`,OWNER_MIGRATION_EXPORT_FORMAT)
    m:=owner_export_test_manifest(doc,1)
    raw,_:=json.marshal(m,allocator=context.temp_allocator)
    parsed,ok:=owner_migration_manifest_parse(string(raw))
    if !testing.expect(t,ok) do return
    rows,valid:=owner_migration_document_parse(doc,parsed.documents[0])
    testing.expect(t,valid && len(rows)==1)
    // Manifest counts must agree with the document references.
    bad:=m;bad.kinds=make([]Owner_Migration_Kind_Count,len(m.kinds));copy(bad.kinds,m.kinds);bad.kinds[1].rows=2
    raw,_=json.marshal(bad,allocator=context.temp_allocator)
    _,ok=owner_migration_manifest_parse(string(raw))
    testing.expect(t,!ok,"per-kind count mismatch")
    bad=m;bad.format="other"
    raw,_=json.marshal(bad,allocator=context.temp_allocator)
    _,ok=owner_migration_manifest_parse(string(raw))
    testing.expect(t,!ok,"unknown format")
    // Hash, index, kind and row count all bind the document.
    for mutate in 0..<4 {
        ref:=parsed.documents[0]
        switch mutate {
        case 0: ref.sha256=strings.repeat("b",64)
        case 1: ref.index=1
        case 2: ref.kind="task"
        case 3: ref.rows=2
        }
        _,valid=owner_migration_document_parse(doc,ref)
        testing.expectf(t,!valid,"mutation %d rejected",mutate)
    }
    nested:=fmt.tprintf(`{{"format":"%s","kind":"chain","index":0,"rows":[{{"chain_id":{{"x":1}}}}]}}`,OWNER_MIGRATION_EXPORT_FORMAT)
    ref:=Owner_Migration_Document_Ref{0,"chain",1,i64(len(nested)),owner_payload_digest(nested)}
    _,valid=owner_migration_document_parse(nested,ref)
    testing.expect(t,!valid,"only scalar column values")
}
