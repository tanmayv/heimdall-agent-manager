#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Actions name one episode, never "the latest origin". Producer resolution,
// delivery, acknowledgement and retirement are independent durable evidence.
source_command :: proc(s:^Store,c:json.Object,body:string,seq,now:i64) -> string {
    method,chain:=field(c,"method"),field(c,"chain_id")
    kind:="source_action"
    if method=="source.observe" do kind="source_fact"
    p,valid:=contracts.owner_parse(body,kind)
    if !valid do return "malformed"
    origin,id,episode,version:=field(p,"origin_kind"),field(p,"origin_id"),field(p,"episode_id"),field(p,"source_version")
    if method=="source.observe" && (origin=="local.review" || origin=="local.workflow") do return "invalid_scope"
    rows,ok:=query(s.db,"SELECT source_version,resolved,ack_floor,retired_floor,delivered_floor,deadline_ms,card_id,card_closed,body FROM source_episodes WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=?",chain,origin,id,episode)
    if !ok do return "storage_error"
    if method=="source.observe" {
        if len(field(p,"body"))>MAX_BODY || len(encode(field(p,"body")))>MAX_ENCODED_FIELD do return "invalid_content"
        if len(rows)>0 && (number(version)<=number(rows[0][0]) || rows[0][1]=="1") do return "stale_revision"
        _,ok=query(s.db,"INSERT INTO source_episodes(chain_id,origin_kind,origin_id,episode_id,source_version,resolved,deadline_ms,body) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(chain_id,origin_kind,origin_id,episode_id) DO UPDATE SET source_version=excluded.source_version,resolved=excluded.resolved,deadline_ms=excluded.deadline_ms,body=excluded.body",chain,origin,id,episode,version,field(p,"resolved"),field(p,"deadline_ms"),field(p,"body"))
        if !ok do return "storage_error"
        return "ok" if source_pin(s,c,origin,id,episode) else "storage_error"
    }
    if len(rows)!=1 do return "stale_revision"
    // ACK/retirement refer to an exact committed consumption, which may predate
    // later producer facts or resolution. They cannot advance beyond that
    // producer; the consumption lookup below still requires its exact fence.
    historical:=method=="source.ack" || method=="source.retire"
    if historical {
        if number(version)>number(rows[0][0]) do return "stale_revision"
    } else if rows[0][0]!=version do return "stale_revision"
    switch method {
    case "source.consume":
        caps,read:=query(s.db,"SELECT capability_json FROM local_leases WHERE chain_id=? AND retired_seq IS NULL AND expires_ms>? UNION ALL SELECT capability_json FROM local_review_sessions WHERE chain_id=? AND expires_ms>?",chain,fmt.tprintf("%d",now),chain,fmt.tprintf("%d",now))
        if !read do return "storage_error"
        current:=false
        for cap in caps do if payload_hash(cap[0])==field(p,"consumer_fence_hash") do current=true
        if !current do return "invalid_scope"
        if len(field(p,"result"))>MAX_BODY do return "invalid_content"
        _,ok=query(s.db,"INSERT INTO source_consumptions VALUES(?,?,?,?,?,?,?,?,?,?)",chain,origin,id,episode,field(p,"consumer_fence_hash"),version,field(c,"principal_id"),field(c,"operation_id"),fmt.tprintf("%d",seq),field(p,"result"))
    case "source.ack", "source.retire":
        consumed,read:=query(s.db,"SELECT 1 FROM source_consumptions WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=? AND source_version=? AND consumer_fence_hash=?",chain,origin,id,episode,version,field(p,"consumer_fence_hash"))
        if !read do return "storage_error"
        if len(consumed)!=1 do return "invalid_scope"
        if method=="source.ack" {
            _,ok=query(s.db,"UPDATE source_episodes SET ack_floor=max(ack_floor,?) WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=?",version,chain,origin,id,episode)
        } else {
            _,ok=query(s.db,"UPDATE source_episodes SET retired_floor=max(retired_floor,?) WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=?",version,chain,origin,id,episode)
        }
    case "source.escalate":
        if rows[0][1]=="1" || number(rows[0][5])>now || number(rows[0][2])>=number(version) || number(rows[0][3])>=number(version) || rows[0][6]!="" do return "operation_conflict"
        card:=payload_hash(encode([4]string{chain,origin,id,episode}))
        _,ok=query(s.db,"UPDATE source_episodes SET card_id=? WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=?",card,chain,origin,id,episode)
    case "source.resolve":
        // A later same-origin recurrence cannot veto this episode's resolution.
        if rows[0][1]!="1" do return "operation_conflict"
        _,ok=query(s.db,"UPDATE source_episodes SET card_closed=1 WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=?",chain,origin,id,episode)
    case: return "malformed"
    }
    if !ok {
        if sqlite3_errcode(s.db)==19 do return "operation_conflict"
        return "storage_error"
    }
    return "ok" if source_pin(s,c,origin,id,episode) else "storage_error"
}
source_pin :: proc(s:^Store,c:json.Object,origin,id,episode:string)->bool {
    _,ok:=query(s.db,"INSERT OR IGNORE INTO source_receipt_pins VALUES(?,?,?,?,?,?)",field(c,"principal_id"),field(c,"operation_id"),field(c,"chain_id"),origin,id,episode)
    return ok
}

// Canonical task producers share the caller transaction. Exact reviewer result
// consumption is recorded before producer resolution, and enqueues one durable
// local-inbox intent under the same command receipt.
source_lifecycle :: proc(tx:^Transaction,c,p:json.Object,seq,now:i64)->bool {
    s:=tx.store
    chain,task,method:=field(c,"chain_id"),field(c,"task_id"),field(c,"method")
    version:=fmt.tprintf("%d",seq)
    if task!="" {
        state,ok:=query(s.db,"SELECT state,attempt FROM lifecycle_state WHERE chain_id=? AND task_id=?",chain,task)
        if !ok do return false
        if len(state)==1 {
            // A submit that settled at once (no reviewer owed, no user gate)
            // awaits no review.
            if (method=="lease.submit" || method=="lifecycle.force_submit") && state[0][0]=="in_review" {
                if _,ok=query(s.db,"INSERT INTO source_episodes(chain_id,origin_kind,origin_id,episode_id,source_version,resolved,deadline_ms,body) VALUES(?,'local.review',?,?,?,0,?,?)",chain,task,state[0][1],version,fmt.tprintf("%d",now+LEASE_TTL_MS),"Independent review awaiting required verdicts");!ok do return false
                if !source_pin(s,c,"local.review",task,state[0][1]) do return false
            }
            if method=="review.post" {
                rows,read:=query(s.db,"SELECT source_version FROM source_episodes WHERE chain_id=? AND origin_kind='local.review' AND origin_id=? AND episode_id=?",chain,task,field(p,"attempt"))
                if !read do return false
                // Historical submissions upgraded from V7 have no source row.
                if len(rows)==1 {
                    if !source_pin(s,c,"local.review",task,field(p,"attempt")) do return false
                    fence:=field(c,"capability_digest")
                    if fence=="" do fence=payload_hash(encode([2]string{field(c,"principal_id"),field(c,"operation_id")}))
                    result:=encode(doc(map[string]string{"verdict"=field(p,"verdict"),"payload_digest"=field(c,"payload_digest"),"role"=field(p,"role")}))
                    if _,ok=query(s.db,"INSERT INTO source_consumptions VALUES(?,'local.review',?,?,?,?,?,?,?,?)",chain,task,field(p,"attempt"),fence,rows[0][0],field(c,"principal_id"),field(c,"operation_id"),version,result);!ok do return false
                    if _,ok=query(s.db,"UPDATE source_episodes SET source_version=? WHERE chain_id=? AND origin_kind='local.review' AND origin_id=? AND episode_id=?",version,chain,task,field(p,"attempt"));!ok do return false
                    action:=encode(doc(map[string]string{"origin_kind"="local.review","origin_id"=task,"episode_id"=field(p,"attempt"),"source_version"=rows[0][0],"consumer_fence_hash"=fence,"result"=result}))
                    if !intent_enqueue(tx,Intent_Input{chain=chain,principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind="source.delivery",destination=fmt.tprintf("review:%s:%s:%s",task,field(p,"attempt"),field(p,"role")),fence=action,payload=action}) do return false
                }
            }
            if _,ok=query(s.db,"UPDATE source_episodes SET resolved=1,source_version=? WHERE chain_id=? AND origin_kind='local.review' AND origin_id=? AND resolved=0 AND (episode_id!=? OR ?!='in_review')",version,chain,task,state[0][1],state[0][0]);!ok do return false
        }
    }
    // Workflow producers resolve superseded generations independently, retaining
    // pending cards for cold discovery just like review producers.
    runs,ok:=query(s.db,"SELECT run_id,execution,state FROM local_workflow_executions WHERE chain_id=?",chain)
    if !ok do return false
    for run in runs {
        if _,ok=query(s.db,"INSERT OR IGNORE INTO source_episodes(chain_id,origin_kind,origin_id,episode_id,source_version,resolved,deadline_ms,body) VALUES(?,'local.workflow',?,?,?,0,?,?)",chain,run[0],run[1],version,fmt.tprintf("%d",now+LEASE_TTL_MS),"Workflow execution awaiting stages");!ok do return false
        if run[2]!="running" {
            if _,ok=query(s.db,"UPDATE source_episodes SET resolved=1,source_version=? WHERE chain_id=? AND origin_kind='local.workflow' AND origin_id=? AND episode_id=? AND resolved=0",version,chain,run[0],run[1]);!ok do return false
        }
    }
    return true
}
source_intent :: proc(tx:^Transaction,c:json.Object,body:string,seq:i64) -> bool {
    method:=field(c,"method")
    if method!="source.consume" && method!="source.escalate" do return true
    p,valid:=contracts.owner_parse(body,"source_action")
    if !valid do return false
    p["result"]=json.String(payload_hash(field(p,"result")))
    return intent_enqueue(tx,Intent_Input{chain=field(c,"chain_id"),principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind="source.delivery",destination=field(p,"episode_id"),fence=encode(p),payload=body})
}
source_delivered :: proc(s:^Store,chain,fence:string) -> bool {
    p,valid:=contracts.owner_parse(fence,"source_action")
    if !valid do return false
    _,ok:=query(s.db,"UPDATE source_episodes SET delivered_floor=max(delivered_floor,?) WHERE chain_id=? AND origin_kind=? AND origin_id=? AND episode_id=? AND source_version>=?",field(p,"source_version"),chain,field(p,"origin_kind"),field(p,"origin_id"),field(p,"episode_id"),field(p,"source_version"))
    return ok
}
source_inventory :: proc(s:^Store,chain,cursor:string,limit:i64) -> Result {
    if limit<1 || limit>100 do return fail("malformed")
    state,read:=query(s.db,"SELECT commit_seq FROM runtime_database")
    if !read || len(state)!=1 do return fail("storage_error")
    scope:=payload_hash(encode([2]string{chain,state[0][0]}))
    offset:i64
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || offset>MAX_RECORDS || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    rows,ok:=query(s.db,"SELECT origin_kind,origin_id,episode_id,source_version,resolved,ack_floor,retired_floor,delivered_floor,deadline_ms,card_id,card_closed,body FROM source_episodes WHERE chain_id=? AND (resolved=0 OR (card_id!='' AND card_closed=0)) ORDER BY origin_kind,origin_id,episode_id LIMIT ? OFFSET ?",chain,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    if !ok do return fail("storage_error")
    chain_rows,chain_read:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !chain_read || len(chain_rows)!=1 do return fail("storage_error")
    items:=make([dynamic][]string,context.temp_allocator)
    for row,i in rows {
        if i>=int(limit) do break
        append(&items,row)
        candidate:=encode(struct{kind,revision:string,items:[dynamic][]string,next_cursor:string}{"sources",chain_rows[0][0],items,fmt.tprintf("%s:%d",scope,offset+i64(len(items)))})
        if len(candidate)>MAX_PAGE {ordered_remove(&items,len(items)-1);break}
    }
    if len(items)==0 && len(rows)>0 do return fail("invalid_content")
    next:=""
    if len(items)<len(rows) do next=fmt.tprintf("%s:%d",scope,offset+i64(len(items)))
    body:=encode(struct{kind,revision:string,items:[dynamic][]string,next_cursor:string}{"sources",chain_rows[0][0],items,next})
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
