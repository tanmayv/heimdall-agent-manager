#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

native_work_read :: proc(s:^Store,chain:string,p:json.Object)->Result {
    source,kind:=field(p,"source_revision"),field(p,"kind")
    snapshots,records:="native_work_snapshots","native_work_records"
    if contracts.owner_record_source_kind(kind) {snapshots="native_record_snapshots";records="native_record_values"}
    meta,ok:=query(s.db,fmt.tprintf("SELECT owner_user_id,content_digest,accepted_seq FROM %s WHERE chain_id=? AND source_revision=? AND kind=?",snapshots),chain,source,kind)
    if !ok do return fail("storage_error")
    if len(meta)!=1 do return fail("invalid_scope")
    scope:=payload_hash(encode([5]string{s.account,chain,source,kind,meta[0][1]}))
    after:=""
    if cursor:=field(p,"cursor");cursor!="" {
        if len(cursor)<65 || cursor[:64]!=scope || cursor[64]!=':' do return fail("stale_cursor")
        after=cursor[65:]
    }
    offset:i64
    indexed:=contracts.owner_record_source_kind(kind)
    if indexed && after!="" {
        offset=number(after)
        if offset<0 || offset>100 || fmt.tprintf("%d",offset)!=after do return fail("malformed")
    }
    limit:=number(field(p,"limit"))
    sql:=fmt.tprintf("SELECT record_key,record_json FROM %s WHERE chain_id=? AND source_revision=? AND kind=? AND record_key>? ORDER BY record_key LIMIT ?",records)
    fourth,fifth:=after,fmt.tprintf("%d",limit+1)
    if indexed {
        sql=fmt.tprintf("SELECT record_key,record_json FROM %s WHERE chain_id=? AND source_revision=? AND kind=? ORDER BY record_key LIMIT ? OFFSET ?",records)
        fourth,fifth=fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset)
    }
    rows,read:=query(s.db,sql,chain,source,kind,fourth,fifth)
    if !read do return fail("storage_error")
    items:=make(json.Array,0,len(rows),context.temp_allocator)
    next:=""
    for row,i in rows {
        if i>=int(limit) {next=fmt.tprintf("%s:%s",scope,after);if indexed do next=fmt.tprintf("%s:%d",scope,offset+i64(len(items)));break}
        v,valid:=contracts.owner_content_document(row[1])
        if !valid do return fail("storage_error")
        append(&items,v)
        if len(encode(items))>MAX_PAGE-2048 {pop(&items);next=fmt.tprintf("%s:%s",scope,after);if indexed do next=fmt.tprintf("%s:%d",scope,offset+i64(len(items)));break}
        after=row[0]
    }
    if len(rows)>0 && len(items)==0 do return fail("invalid_content")
    result:=doc(map[string]string{"chain_id"=chain,"source_revision"=source,"kind"=kind,"owner_user_id"=meta[0][0],"accepted_seq"=meta[0][2],"next_cursor"=next})
    result["items"]=items
    return Result{code="ok",body=encode(result)}
}
