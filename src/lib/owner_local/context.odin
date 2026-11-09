#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:c"
import "core:crypto/sha2"
import vault "odin_test:lib/vault"
import "core:fmt"
import "core:strings"
import compact "odin_test:lib/context_compaction"
import contracts "odin_test:contracts"

// Complete source index, ordered by immutable reference. Only called under the
// Store transaction AFTER chain read authorization. Never includes credentials.
CONTEXT_SOURCE_SQL :: `SELECT kind,ref,body FROM (
 SELECT 'task' kind,task_id ref,json_object('task_id',task_id,'title',title,'body',body,'revision',revision,'priority',COALESCE((SELECT priority FROM local_task_priority_versions p WHERE p.chain_id=tasks.chain_id AND p.task_id=tasks.task_id ORDER BY accepted_seq DESC LIMIT 1),'p2')) body FROM tasks WHERE chain_id=?1
 UNION ALL SELECT 'curated_summary',CAST(accepted_seq AS TEXT),json_object('accepted_seq',accepted_seq,'curated_body',curated_body) FROM local_chain_summary_versions WHERE chain_id=?1
 UNION ALL SELECT 'requirements',json_array(task_id,CAST(revision AS TEXT)),json_object('task_id',task_id,'revision',revision,'brief',brief_json) FROM task_requirements WHERE chain_id=?1
 UNION ALL SELECT 'submission',json_array(task_id,CAST(attempt AS TEXT)),json_object('task_id',task_id,'attempt',attempt,'summary',summary,'head',head,'requirements_revision',requirements_revision) FROM local_submissions WHERE chain_id=?1
 UNION ALL SELECT 'handoff',json_array(principal_id,operation_id),json_object('task_id',task_id,'principal_id',principal_id,'operation_id',operation_id,'kind',kind,'summary',summary,'next_steps',next_steps,'waiting_on',waiting_on,'seq',seq) FROM local_handoffs WHERE chain_id=?1
 UNION ALL SELECT 'comment',json_array(principal_id,operation_id),json_object('task_id',task_id,'principal_id',principal_id,'operation_id',operation_id,'body',body,'seq',seq) FROM task_comments WHERE chain_id=?1
 UNION ALL SELECT 'chain',chain_id,json_object('chain_id',chain_id,'title',title,'description',description,'revision',revision) FROM task_chains WHERE chain_id=?1
 UNION ALL SELECT 'review',json_array(task_id,CAST(attempt AS TEXT),reviewer_agent_id),json_object('task_id',task_id,'attempt',attempt,'reviewer',reviewer_agent_id,'verdict',verdict,'summary',summary,'requirements_revision',requirements_revision) FROM local_reviews WHERE chain_id=?1
 UNION ALL SELECT 'workflow_definition',json_array(workflow_id,CAST(version AS TEXT)),definition_json FROM local_workflow_definitions WHERE chain_id=?1
 UNION ALL SELECT 'workflow_event',json_array(run_id,CAST(event_seq AS TEXT)),json_object('run_id',run_id,'execution',execution,'event_seq',event_seq,'kind',kind,'principal_id',principal_id,'operation_id',operation_id) FROM local_workflow_events WHERE chain_id=?1
 UNION ALL SELECT 'source',json_array(origin_kind,origin_id,episode_id),json_object('origin_kind',origin_kind,'origin_id',origin_id,'episode_id',episode_id,'source_version',source_version,'resolved',resolved,'body',body,'card_id',card_id,'card_closed',card_closed) FROM source_episodes WHERE chain_id=?1
 UNION ALL SELECT 'consumption',json_array(origin_kind,origin_id,episode_id,consumer_fence_hash,CAST(source_version AS TEXT)),json_object('origin_kind',origin_kind,'origin_id',origin_id,'episode_id',episode_id,'source_version',source_version,'consumer_fence_hash',consumer_fence_hash,'result',result,'commit_seq',commit_seq) FROM source_consumptions WHERE chain_id=?1
 )`
context_sources :: proc(s:^Store,chain:string,offset:i64=0,limit:i64=MAX_RECORDS) -> ([dynamic][]string,bool) {
    return query(s.db,fmt.tprintf("%s ORDER BY kind,ref LIMIT ?2 OFFSET ?3",CONTEXT_SOURCE_SQL),chain,fmt.tprintf("%d",limit),fmt.tprintf("%d",offset))
}

// Stream exact framed source bytes directly from SQLite. A large retained
// history never becomes a giant allocated JSON array just to hash provenance.
context_source_digest :: proc(s:^Store,chain,seq:string) -> (string,i64,bool) {
    stmt:Stmt
    sql:=fmt.tprintf("%s ORDER BY kind,ref",CONTEXT_SOURCE_SQL)
    if sqlite3_prepare_v2(s.db,strings.clone_to_cstring(sql,context.temp_allocator),-1,&stmt,nil)!=0 do return "",0,false
    defer sqlite3_finalize(stmt)
    if sqlite3_bind_text(stmt,1,strings.clone_to_cstring(chain,context.temp_allocator),c.int(len(chain)),rawptr(~uintptr(0)))!=0 do return "",0,false
    hash:sha2.Context_256
    sha2.init_256(&hash)
    prefix:=encode([4]string{"heimdall-context-source-v2",s.account,chain,seq})
    sha2.update(&hash,transmute([]byte)prefix)
    count:i64
    for {
        rc:=sqlite3_step(stmt)
        if rc==101 do break
        if rc!=100 do return "",0,false
        for i in 0..<3 {
            n:=int(sqlite3_column_bytes(stmt,c.int(i)))
            frame:[8]byte
            for j in 0..<8 do frame[j]=byte(u64(n)>>u64(j*8))
            sha2.update(&hash,frame[:])
            bytes:=([^]byte)(rawptr(sqlite3_column_text(stmt,c.int(i))))[:n]
            sha2.update(&hash,bytes)
        }
        count+=1
    }
    digest:[32]byte
    sha2.final(&hash,digest[:])
    return vault.hex_encode_lower(digest[:],context.temp_allocator),count,true
}

// Snapshot-coherent lazy materialization. Source checkpoint and projection are
// observed in the same transaction. Failure never returns a stale success.
context_materialize :: proc(s:^Store,chain:string) -> (json.Object,bool) {
    if s.active==nil || !transaction_current(s.active) do return nil,false
    state,ok:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !ok || len(state)!=1 do return nil,false
    header,found:=query(s.db,"SELECT title,description,COALESCE((SELECT curated_body FROM local_chain_summary_versions s WHERE s.chain_id=task_chains.chain_id ORDER BY accepted_seq DESC LIMIT 1),'') FROM task_chains WHERE chain_id=?",chain)
    if !found || len(header)!=1 do return nil,false
    seq:=state[0][0]
    old,read:=query(s.db,"SELECT algorithm,version,source_seq,source_digest,source_count,body FROM local_chain_context WHERE chain_id=?",chain)
    if !read do return nil,false
    version:i64=1
    digest,body,count:="","",""
    if len(old)==1 && old[0][0]=="2" && old[0][2]==seq {
        version=number(old[0][1]);digest=old[0][3];count=old[0][4];body=old[0][5]
    } else {
        source_hash,source_count,source_ok:=context_source_digest(s,chain,seq)
        if !source_ok do return nil,false
        if len(old)==1 do version=number(old[0][1])+1
        count=fmt.tprintf("%d",source_count)
        digest=source_hash
        items:=make([dynamic]string,context.temp_allocator)
        append(&items,fmt.tprintf("Coordinator input (chain description): %s",header[0][1]))
        if header[0][2]!="" do append(&items,fmt.tprintf("Curated notes: %s",header[0][2]))
        pending,pending_ok:=query(s.db,"SELECT origin_kind,origin_id,episode_id,body FROM source_episodes WHERE chain_id=? AND (resolved=0 OR (card_id!='' AND card_closed=0)) ORDER BY source_version DESC,origin_kind,origin_id,episode_id LIMIT 16",chain)
        if !pending_ok do return nil,false
        for row in pending do append(&items,fmt.tprintf("[unresolved %s:%s:%s] %s",row[0],row[1],row[2],row[3]))
        active,active_ok:=query(s.db,"SELECT t.task_id,t.title,COALESCE(l.state,'unconfigured') FROM tasks t LEFT JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id WHERE t.chain_id=? ORDER BY CASE WHEN l.state IN ('done','cancelled') THEN 1 ELSE 0 END,t.task_id LIMIT 16",chain)
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
            fmt.tprintf("Projection v2; checkpoint %s; %s sources. Fetch full originals with signed context.read (cursor pages); no source is deleted.",seq,count),items[:])
        if _,saved:=query(s.db,"INSERT INTO local_chain_context VALUES(?,2,?,?,?,?,?) ON CONFLICT(chain_id) DO UPDATE SET algorithm=excluded.algorithm,version=excluded.version,source_seq=excluded.source_seq,source_digest=excluded.source_digest,source_count=excluded.source_count,body=excluded.body",
            chain,fmt.tprintf("%d",version),seq,digest,count,body);!saved do return nil,false
    }
    return doc(map[string]string{"algorithm"="2","version"=fmt.tprintf("%d",version),"source_seq"=seq,"source_digest"=digest,"source_count"=count,"freshness"="snapshot","body"=body,"fetch_method"="context.read"}),true
}

// One bounded source chunk per page. Cursor binds account/chain/checkpoint,
// row and byte offset, retrieving every original including giant one-liners.
context_history :: proc(s:^Store,chain:string,p:json.Object) -> Result {
    if s.active==nil || !transaction_current(s.active) do return fail("invalid_scope")
    counts,ok:=query(s.db,fmt.tprintf("SELECT count(*) FROM (%s)",CONTEXT_SOURCE_SQL),chain)
    state,read:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !ok || len(counts)!=1 || !read || len(state)!=1 do return fail("storage_error")
    chains,chain_ok:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !chain_ok || len(chains)!=1 do return fail("invalid_scope")
    source_count:=number(counts[0][0])
    scope:=contracts.owner_payload_digest(encode([3]string{s.account,chain,state[0][0]}))
    index,offset:i64
    cursor:=field(p,"cursor")
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=3 || parts[0]!=scope do return fail("stale_cursor")
        index=number(parts[1]);offset=number(parts[2])
        if index<0 || index>=source_count || offset<0 || fmt.tprintf("%d",index)!=parts[1] || fmt.tprintf("%d",offset)!=parts[2] do return fail("malformed")
    }
    if source_count==0 do return Result{code="ok",body=encode(doc(map[string]string{"kind"="context_source","next_cursor"="","source_count"="0","revision"=chains[0][0],"source_seq"=state[0][0]}))}
    sources,source_ok:=context_sources(s,chain,index,1)
    if !source_ok || len(sources)!=1 do return fail("storage_error")
    row:=sources[0]
    if offset>i64(len(row[2])) || (offset<i64(len(row[2])) && row[2][offset]&0xc0==0x80) do return fail("malformed")
    end:=min(i64(len(row[2])),offset+8192)
    for end>offset && end<i64(len(row[2])) && row[2][end]&0xc0==0x80 {end-=1}
    next:=""
    if end<i64(len(row[2])) {next=fmt.tprintf("%s:%d:%d",scope,index,end)} else if index+1<source_count {next=fmt.tprintf("%s:%d:0",scope,index+1)}
    body:=encode(doc(map[string]string{"kind"="context_source","source_kind"=row[0],"source_ref"=row[1],"body"=row[2][offset:end],"offset"=fmt.tprintf("%d",offset),"next_cursor"=next,"source_count"=fmt.tprintf("%d",source_count),"revision"=chains[0][0],"source_seq"=state[0][0]}))
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
