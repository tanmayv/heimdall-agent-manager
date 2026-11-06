#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import compact "odin_test:lib/context_compaction"
import contracts "odin_test:contracts"

// Complete source index, ordered by immutable reference. Only called under the
// Store transaction AFTER chain read authorization. Never includes credentials.
context_sources :: proc(s:^Store,chain:string) -> ([dynamic][]string,bool) {
    return query(s.db,`SELECT kind,ref,body FROM (
 SELECT 'task' kind,task_id ref,json_object('task_id',task_id,'title',title,'body',body,'revision',revision) body FROM tasks WHERE chain_id=?
 UNION ALL SELECT 'requirements',task_id||':'||revision,json_object('task_id',task_id,'revision',revision,'brief',brief_json) FROM task_requirements WHERE chain_id=?
 UNION ALL SELECT 'submission',task_id||':'||attempt,json_object('task_id',task_id,'attempt',attempt,'summary',summary,'head',head,'requirements_revision',requirements_revision) FROM local_submissions WHERE chain_id=?
 UNION ALL SELECT 'handoff',principal_id||':'||operation_id,json_object('task_id',task_id,'principal_id',principal_id,'operation_id',operation_id,'kind',kind,'summary',summary,'next_steps',next_steps,'waiting_on',waiting_on,'seq',seq) FROM local_handoffs WHERE chain_id=?
 UNION ALL SELECT 'comment',principal_id||':'||operation_id,json_object('task_id',task_id,'principal_id',principal_id,'operation_id',operation_id,'body',body,'seq',seq) FROM task_comments WHERE chain_id=?
 ) ORDER BY kind,ref`,chain,chain,chain,chain,chain)
}

// Snapshot-coherent lazy materialization. Source checkpoint and projection are
// observed in the same transaction. Failure never returns a stale success.
context_materialize :: proc(s:^Store,chain:string) -> (json.Object,bool) {
    if s.active==nil || !transaction_current(s.active) do return nil,false
    state,ok:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !ok || len(state)!=1 do return nil,false
    header,found:=query(s.db,"SELECT title,description FROM task_chains WHERE chain_id=?",chain)
    if !found || len(header)!=1 do return nil,false
    seq:=state[0][0]
    old,read:=query(s.db,"SELECT algorithm,version,source_seq,source_digest,source_count,body FROM local_chain_context WHERE chain_id=?",chain)
    if !read do return nil,false
    version:i64=1
    digest,body,count:="","",""
    if len(old)==1 && old[0][0]=="1" && old[0][2]==seq {
        version=number(old[0][1]);digest=old[0][3];count=old[0][4];body=old[0][5]
    } else {
        sources,source_ok:=context_sources(s,chain)
        if !source_ok do return nil,false
        if len(old)==1 do version=number(old[0][1])+1
        count=fmt.tprintf("%d",len(sources))
        digest=contracts.owner_payload_digest(encode(struct{account,chain,seq:string,header:[]string,sources:[dynamic][]string}{s.account,chain,seq,header[0],sources}))
        items:=make([dynamic]string,context.temp_allocator)
        append(&items,fmt.tprintf("Coordinator input (chain description): %s",header[0][1]))
        active,active_ok:=query(s.db,"SELECT t.task_id,t.title,COALESCE(l.state,'unconfigured') FROM tasks t LEFT JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id WHERE t.chain_id=? ORDER BY t.task_id",chain)
        if !active_ok do return nil,false
        for row in active do append(&items,fmt.tprintf("[%s] %s: %s",row[0],row[2],row[1]))
        lessons,lessons_ok:=query(s.db,"SELECT task_id,kind,summary,next_steps FROM local_handoffs WHERE chain_id=? ORDER BY seq DESC LIMIT 256",chain)
        if !lessons_ok do return nil,false
        seen:=make(map[string]bool,context.temp_allocator)
        for row in lessons {
            lesson:=strings.join(row[1:]," ",context.temp_allocator)
            if seen[lesson] do continue
            seen[lesson]=true
            append(&items,fmt.tprintf("[%s] %s",row[0],lesson))
        }
        recent,recent_ok:=query(s.db,"SELECT task_id,attempt,summary FROM local_submissions WHERE chain_id=? ORDER BY rowid DESC LIMIT 32",chain)
        if !recent_ok do return nil,false
        for row in recent do append(&items,fmt.tprintf("[submission %s:%s] %s",row[0],row[1],row[2]))
        body=compact.project(fmt.tprintf("# Chain %s: %s",chain,header[0][0]),
            fmt.tprintf("Projection v1; checkpoint %s; %s sources. Fetch full originals with signed context.read (cursor pages); no source is deleted.",seq,count),items[:])
        if _,saved:=query(s.db,"INSERT INTO local_chain_context VALUES(?,1,?,?,?,?,?) ON CONFLICT(chain_id) DO UPDATE SET algorithm=excluded.algorithm,version=excluded.version,source_seq=excluded.source_seq,source_digest=excluded.source_digest,source_count=excluded.source_count,body=excluded.body",
            chain,fmt.tprintf("%d",version),seq,digest,count,body);!saved do return nil,false
    }
    return doc(map[string]string{"algorithm"="1","version"=fmt.tprintf("%d",version),"source_seq"=seq,"source_digest"=digest,"source_count"=count,"freshness"="snapshot","body"=body,"fetch_method"="context.read"}),true
}

// One bounded source chunk per page. Cursor binds account/chain/checkpoint,
// row and byte offset, retrieving every original including giant one-liners.
context_history :: proc(s:^Store,chain:string,p:json.Object) -> Result {
    sources,ok:=context_sources(s,chain)
    state,read:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !ok || !read || len(state)!=1 do return fail("storage_error")
    scope:=contracts.owner_payload_digest(encode([3]string{s.account,chain,state[0][0]}))
    index,offset:i64
    cursor:=field(p,"cursor")
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=3 || parts[0]!=scope do return fail("stale_cursor")
        index=number(parts[1]);offset=number(parts[2])
        if index<0 || index>=i64(len(sources)) || offset<0 || fmt.tprintf("%d",index)!=parts[1] || fmt.tprintf("%d",offset)!=parts[2] do return fail("malformed")
    }
    if len(sources)==0 do return Result{code="ok",body=encode(doc(map[string]string{"kind"="context_source","next_cursor"="","source_count"="0","revision"=state[0][0]}))}
    row:=sources[index]
    if offset>i64(len(row[2])) || (offset<i64(len(row[2])) && row[2][offset]&0xc0==0x80) do return fail("malformed")
    end:=min(i64(len(row[2])),offset+8192)
    for end>offset && end<i64(len(row[2])) && row[2][end]&0xc0==0x80 {end-=1}
    next:=""
    if end<i64(len(row[2])) {next=fmt.tprintf("%s:%d:%d",scope,index,end)} else if index+1<i64(len(sources)) {next=fmt.tprintf("%s:%d:0",scope,index+1)}
    body:=encode(doc(map[string]string{"kind"="context_source","source_kind"=row[0],"source_ref"=row[1],"body"=row[2][offset:end],"offset"=fmt.tprintf("%d",offset),"next_cursor"=next,"source_count"=fmt.tprintf("%d",len(sources)),"revision"=state[0][0]}))
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
