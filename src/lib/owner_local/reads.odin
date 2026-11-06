#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

read_result :: proc(s:^Store,c:json.Object,payload:string,revision:i64) -> Result {
    method,chain,task:=field(c,"method"),field(c,"chain_id"),field(c,"task_id")
    p,_:=contracts.owner_parse(payload,contracts.owner_payload_kind(method))
    if method=="receipt.read" {
        rows,ok:=query(s.db,"SELECT method,result_json,commit_seq,chain_id,task_id FROM command_receipts WHERE principal_id=? AND operation_id=?",field(c,"principal_id"),field(p,"operation_id"))
        if !ok do return fail("storage_error")
        if len(rows)!=1 || rows[0][3]!=chain do return fail("invalid_scope")
        return Result{code="ok",body=rows[0][1],seq=number(rows[0][2]),replay=true}
    }
    scope:=contracts.owner_payload_digest(encode([5]string{s.account,chain,task,method,fmt.tprintf("%d",revision)}))
    cursor:=field(p,"cursor")
    offset:i64
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || offset>MAX_RECORDS || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    limit:=number(field(p,"limit"))
    result:=make(map[string]json.Value,context.temp_allocator)
    result["chain_id"]=json.String(chain); result["task_id"]=json.String(task); result["revision"]=json.String(fmt.tprintf("%d",revision))
    rows:[dynamic][]string
    ok:bool
    if method=="chain.read" {
        header,found:=query(s.db,"SELECT title,description FROM task_chains WHERE chain_id=?",chain)
        if !found || len(header)!=1 do return fail("invalid_scope")
        result["title"]=json.String(header[0][0]);result["description"]=json.String(header[0][1])
        rows,ok=query(s.db,"SELECT task_id,title,revision FROM tasks WHERE chain_id=? ORDER BY task_id LIMIT ? OFFSET ?",chain,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    } else {
        header,found:=query(s.db,"SELECT title,body FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !found || len(header)!=1 do return fail("invalid_scope")
        result["title"]=json.String(header[0][0]);result["body"]=json.String(header[0][1])
        rows,ok=query(s.db,"SELECT operation_id,principal_id,body,seq FROM task_comments WHERE chain_id=? AND task_id=? ORDER BY seq LIMIT ? OFFSET ?",chain,task,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    }
    if !ok do return fail("storage_error")
    items:=make([dynamic]json.Value,context.temp_allocator)
    budget:=len(encode(result))
    for row,i in rows {
        if i>=int(limit) do break
        item:json.Object
        if method=="chain.read" { item=doc(map[string]string{"task_id"=row[0],"title"=row[1],"revision"=row[2]}) } else {
            item=doc(map[string]string{"operation_id"=row[0],"principal_id"=row[1],"body"=row[2],"seq"=row[3]})
        }
        n:=len(encode(item))
        if budget+n>MAX_PAGE do break
        budget+=n
        append(&items,item)
    }
    next:=""
    if len(items)<len(rows) { next=fmt.tprintf("%s:%d",scope,offset+i64(len(items))) }
    result["items"]=json.Array(items);result["next_cursor"]=json.String(next)
    return Result{code="ok",body=encode(result)}
}
pending :: proc(s:^Store,limit:=20) -> (rows:[dynamic][]string,ok:bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    return query(s.db,"SELECT intent_id,payload_json,chain_id FROM runtime_intents WHERE published=0 ORDER BY commit_seq LIMIT ?",fmt.tprintf("%d",min(limit,20)))
}
acknowledge :: proc(s:^Store,id:string) -> bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    _,ok:=query(s.db,"UPDATE runtime_intents SET published=1 WHERE intent_id=?",id)
    return ok
}
genesis_for :: proc(s:^Store,chain:string) -> string {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    rows,ok:=query(s.db,"SELECT genesis_json FROM chain_genesis WHERE chain_id=?",chain)
    if !ok || len(rows)!=1 do return ""
    return rows[0][0]
}
directory_pin :: proc(s:^Store) -> (i64,string) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    rows,ok:=query(s.db,"SELECT directory_version,directory_hash FROM runtime_database WHERE singleton=1")
    if !ok || len(rows)!=1 do return -1,""
    return number(rows[0][0]),rows[0][1]
}
