package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import "core:strings"
import "core:time"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"

// Notification stages use the existing append-only executor receipt journal.
// The first ticket survives Bridge restart; daemon journal loss must be queried
// with that ticket and can never turn into a replacement Prepare.
Notification_Ticket :: struct {pid,ticket,input_profile,document,message:string}
notification_effect :: proc(n:json.Object)->string {
    fields:=make([dynamic]string,context.temp_allocator)
    for f in contracts.executor_schema("notification") {
        switch f.name {
        case "signature","issued_ms","request_expires_ms","expires_ms","deadline_version":
        case: append(&fields,field(n,f.name))
        }
    }
    return contracts.owner_payload_digest(encode(fields[:]))
}
notification_current_locked :: proc(s:^Store,n:json.Object,message:string,key:contracts.Owner_Verified_Key,now:i64)->string {
    if !scope(s,n) || !contracts.executor_verify("notification",n,key) || num(n,"executor_incarnation")!=s.incarnation do return "invalid_scope"
    rows,ok:=query(s.db,`SELECT b.document,r.owner_incarnation,r.executor_incarnation,r.grant_generation,
        r.deadline_version,r.expires_ms,r.hard_ms,r.prepare_digest,r.launch_key,
        d.clock_high_ms,d.recovery_state
      FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
      JOIN executor_runtime d ON d.singleton=1
      JOIN executor_chain_owners o ON o.chain_id=r.chain_id AND o.owner_bridge_id=r.owner_bridge_id AND o.owner_key_id=?
      WHERE r.reservation_id=? AND r.owner_bridge_id=? AND r.chain_id=?
        AND r.state='active' AND r.launch_state='confirmed' AND r.observed_incarnation=d.incarnation`,
        key.key_id,field(n,"reservation_id"),key.principal_id,field(n,"chain_id"))
    if !ok do return "storage_error"
    if len(rows)!=1 do return "no_current_target"
    row:=rows[0];b,parsed:=contracts.executor_parse(row[0],"bootstrap")
    // C1: monotonic clamp; the clock never makes a target unavailable.
    if !parsed || !contracts.executor_notification_matches(n,b,message,key,max(now,number(row[9]))) || (row[10]!="ready" && row[10]!="clock_uncertain") do return "no_current_target"
    names:=[8]string{"owner_incarnation","executor_incarnation","grant_generation","deadline_version","expires_ms","hard_ms","prepare_digest","launch_key"}
    for name,i in names do if field(n,name)!=row[i+1] do return "no_current_target"
    return "ok"
}
notification_current :: proc(s:^Store,n:json.Object,message:string,key:contracts.Owner_Verified_Key,now:i64)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    return s.db!=nil && !s.unusable && notification_current_locked(s,n,message,key,now)=="ok"
}
notification_stage :: proc(s:^Store,n:json.Object,message:string,key:contracts.Owner_Verified_Key,stage:string,now:i64)->Result {
    if stage!="ticket" && stage!="dispatch" && stage!="result" do return fail("invalid_stage")
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return fail("storage_error")
    if code:=notification_current_locked(s,n,message,key,now);code!="ok" do return fail(code)
    prior,found:=receipt(s,field(n,"owner_bridge_id"),fmt.tprintf("notification_%s_%s",field(n,"intent_id"),stage),
        fmt.tprintf("notification.%s",stage),notification_effect(n))
    if found do return prior
    return fail("not_found")
}
// Called only after exact physical observation under the startup I/O gate.
// For dispatch, the caller has just consumed a fresh checkpoint-specific nonce.
notification_record :: proc(s:^Store,n:json.Object,message:string,key:contracts.Owner_Verified_Key,stage,body:string,now:i64)->Result {
    if stage!="ticket" && stage!="dispatch" && stage!="result" do return fail("invalid_stage")
    if len(body)>8192 do return fail("invalid_content")
    _,valid:=contracts.owner_content_document(body)
    if !valid do return fail("invalid_content")
    if stage=="ticket" {
        ticket:Notification_Ticket
        if json.unmarshal_string(body,&ticket,.JSON,context.temp_allocator)!=nil ||
           !contracts.owner_field_valid(ticket.pid,"positive") || !contracts.pty_notification_id_valid(ticket.ticket) ||
           !contracts.pty_notification_id_valid(ticket.input_profile) || ticket.message!=message {return fail("invalid_content")}
        original,parsed:=contracts.executor_parse(ticket.document,"notification")
        if !parsed || !contracts.executor_verify("notification",original,key) ||
           notification_effect(original)!=notification_effect(n) {return fail("invalid_content")}
    }
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    if code:=notification_current_locked(s,n,message,key,now);code!="ok" do return fail(code)
    digest:=notification_effect(n);operation:=fmt.tprintf("notification_%s_%s",field(n,"intent_id"),stage)
    prior,found:=receipt(s,field(n,"owner_bridge_id"),operation,fmt.tprintf("notification.%s",stage),digest)
    if found do return prior
    if stage!="ticket" {
        ticket,ticketed:=receipt(s,field(n,"owner_bridge_id"),fmt.tprintf("notification_%s_ticket",field(n,"intent_id")),"notification.ticket",digest)
        if !ticketed || ticket.code!="ok" do return fail("ticket_required")
    }
    if code:=clock(s,now);code!="" do return fail(code)
    count,read:=query(s.db,"SELECT count(*) FROM executor_receipts")
    if !read || len(count)!=1 do return fail("storage_error")
    if number(count[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    _,saved:=query(s.db,"INSERT INTO executor_receipts VALUES(?,?,?,?,?,?)",field(n,"owner_bridge_id"),operation,
        fmt.tprintf("notification.%s",stage),digest,field(n,"reservation_id"),body)
    if !saved || !commit(s) do return fail("storage_error")
    return Result{code="ok",body=body}
}

notification_challenge :: proc(s:^Store,raw,message:string,attempt:i64,owner_key,self:contracts.Owner_Verified_Key,
    now:i64,sign:Signer)->(Fence_Challenge,bool) {
    started:=time.tick_now()
    n,valid:=contracts.executor_parse(raw,"notification")
    if !valid || attempt<=0 || sign.sign==nil || !notification_current(s,n,message,owner_key,now) do return {},false
    nonce:[32]byte
    if !random.fill(nonce[:]) do return {},false
    q:=make(json.Object,context.temp_allocator)
    for f in contracts.executor_schema("notification_fence_request") do q[f.name]=json.String(field(n,f.name))
    digest,_:=contracts.executor_digest("notification",n)
    q["notification"]=json.String(raw);q["claim_attempt"]=json.String(fmt.tprintf("%d",attempt))
    q["action_digest"]=json.String(digest);q["challenge"]=json.String(vault.hex_encode_lower(nonce[:],context.temp_allocator))
    q["issued_ms"]=json.String(fmt.tprintf("%d",now))
    q["request_expires_ms"]=json.String(fmt.tprintf("%d",min(now+contracts.EXECUTOR_FENCE_TTL_MS,num(n,"request_expires_ms"),num(n,"expires_ms"))))
    q["key_id"]=json.String(self.key_id);q["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    signature,signed:=sign.sign(sign.ctx,"notification_fence_request",q)
    if !signed do return {},false
    q["signature"]=json.String(signature)
    if !contracts.executor_verify("notification_fence_request",q,self) do return {},false
    return Fence_Challenge{strings.clone(encode(q)),strings.clone(raw),false,started},true
}
notification_fence_accept :: proc(s:^Store,p:^Fence_Challenge,raw,message:string,owner_key,self:contracts.Owner_Verified_Key,now:i64)->Current_Owner_Fence {
    if p==nil || p.consumed do return {}
    q,valid:=contracts.executor_parse(p.request,"notification_fence_request")
    n,parsed:=contracts.executor_parse(p.action,"notification")
    r,reply:=contracts.executor_parse(raw,"notification_fence_reply")
    elapsed:=time.tick_since(p.started)
    if !valid || !parsed || !reply || elapsed<0 ||
       elapsed>=time.Duration(num(q,"request_expires_ms")-num(q,"issued_ms"))*time.Millisecond || now>=num(q,"request_expires_ms") {
        p.consumed=true
        return {}
    }
    if !notification_current(s,n,message,owner_key,now) ||
       !contracts.executor_notification_fence_matches(r,q,n,owner_key,self,now) {return {}}
    p.consumed=true
    return {true,field(r,"prepare_digest"),num(r,"owner_incarnation"),num(r,"owner_commit_seq")}
}
