#+feature dynamic-literals
package executor_local

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// Executor-issued credentials authenticate only their current exact confirmed
// child. They are never inserted into the legacy Hub-token store. Callers must
// additionally query the daemon and verify current paired keys before relay.
child_bootstrap :: proc(s:^Store,instance,secret:string,now:i64)->(string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    now:=store_now(s,now) // C1: decide with max(caller clock, store clock), under the store mutex
    return child_bootstrap_locked(s,instance,secret,now)
}
// The executor-issued credential of instance's active reservation, confirmed
// or not yet. Startup bookkeeping only (arming, readiness timers): it grants
// no task authority, which still needs child_bootstrap's exact confirmed child.
child_issued_secret :: proc(s:^Store,instance:string,allocator:=context.temp_allocator)->(string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || instance=="" do return "",false
    rows,ok:=query(s.db,`SELECT i.token_secret FROM executor_issuances i JOIN executor_reservations r ON r.instance_id=i.instance_id
      WHERE i.instance_id=? AND r.state='active'`,instance)
    if !ok || len(rows)!=1 || rows[0][0]=="" do return "",false
    return strings.clone(rows[0][0],allocator),true
}
child_token :: proc(s:^Store,secret:string,now:i64)->(instance,bootstrap:string,valid:bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    now:=store_now(s,now) // C1: decide with max(caller clock, store clock), under the store mutex
    if s.db==nil || s.unusable || secret=="" do return "","",false
    rows,ok:=query(s.db,"SELECT instance_id FROM executor_issuances WHERE token_secret=?",secret)
    if !ok || len(rows)!=1 do return "","",false
    raw,authenticated:=child_bootstrap_locked(s,rows[0][0],secret,now)
    return rows[0][0],raw,authenticated
}
child_bootstrap_locked :: proc(s:^Store,instance,secret:string,now:i64)->(string,bool) {
    now:=store_now(s,now) // C1: the store's single clock source
    if s.db==nil || s.unusable || instance=="" || secret=="" || now<=0 do return "",false
    rows,ok:=query(s.db,`SELECT b.document,i.token_secret,r.expires_ms,r.hard_ms,r.deadline_version,
      r.executor_incarnation,r.observed_incarnation,r.launch_key,i.configuration,
      (SELECT clock_high_ms FROM executor_runtime),(SELECT recovery_state FROM executor_runtime),
      (SELECT incarnation FROM executor_owner_watermarks WHERE owner_bridge_id=r.owner_bridge_id)
      FROM executor_reservations r JOIN executor_bootstraps b USING(reservation_id)
      JOIN executor_issuances i ON i.instance_id=r.instance_id
      WHERE r.instance_id=? AND r.state='active' AND r.launch_state='confirmed'`,instance)
    if !ok || len(rows)!=1 do return "",false
    row:=rows[0]
    if crypto.compare_constant_time(transmute([]byte)secret,transmute([]byte)row[1])!=1 ||
       max(now,number(row[9]))>=number(row[2]) || max(now,number(row[9]))>=number(row[3]) || number(row[5])!=s.incarnation ||
       number(row[6])!=s.incarnation || (row[10]!="ready" && row[10]!="clock_uncertain") {return "",false} // C1: monotonic clamp
    b,valid:=contracts.executor_parse(row[0],"bootstrap")
    if !valid || !scope(s,b) || field(b,"instance_id")!=instance || field(b,"launch_key")!=row[7] ||
       field(b,"token_generation")!=contracts.owner_payload_digest(secret) ||
       field(b,"configuration_digest")!=contracts.owner_payload_digest(row[8]) ||
       field(b,"hard_ms")!=row[3] ||
       num(b,"owner_incarnation")!=number(row[11]) {return "",false}
    if field(b,"deadline_version")!=row[4] || field(b,"expires_ms")!=row[2] {
        a,confirmed:=child_renewal_locked(s,field(b,"reservation_id"),row[4],row[2],row[3])
        if !confirmed || num(a,"deadline_version")<=num(b,"deadline_version") || num(a,"expires_ms")<num(b,"expires_ms") do return "",false
        for name in ([11]string{"protocol_version","account_id","owner_bridge_id","executor_bridge_id","chain_id",
            "reservation_id","grant_generation","owner_incarnation","executor_incarnation","prepare_digest","hard_ms"}) {
            if field(a,name)!=field(b,name) do return "",false
        }
    }
    return row[0],true
}

// This attests an input, not a task grant or deadline renewal. The Bridge must
// hold its startup I/O serialization across the exact daemon query and this
// recheck. The owner still applies its normal journal/capability/receipt rules.
attest_child_request :: proc(s:^Store,instance,secret,input_raw:string,observation:Child_Observation,
    owner_key,executor_key:contracts.Owner_Verified_Key,now:i64,sign:Signer)->Result {
    context.allocator=context.temp_allocator
    input,valid:=contracts.owner_parse(input_raw,"lease_input")
    if !valid {input,valid=contracts.owner_parse(input_raw,"lifecycle_input")}
    if !valid {input,valid=contracts.executor_parse(input_raw,"agent_verb")}
    if !valid do return fail("malformed")
    if sign.sign==nil || now<=0 || now>0x7fffffffffffffff-contracts.EXECUTOR_FENCE_TTL_MS do return fail("invalid_scope")
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    now:=store_now(s,now) // C1: decide with max(caller clock, store clock), under the store mutex
    raw,authenticated:=child_bootstrap_locked(s,instance,secret,now)
    if !authenticated do return fail("invalid_scope")
    b,_:=contracts.executor_parse(raw,"bootstrap")
    if !contracts.executor_verify("bootstrap",b,owner_key) || executor_key.key_id!=s.operator_key ||
       executor_key.principal_id!=s.executor || executor_key.account_id!=s.account ||
       !observation.present || observation.executor_incarnation!=s.incarnation ||
       observation.instance!=instance || observation.launch_key!=field(b,"launch_key") {return fail("invalid_scope")}
    deadline,read:=query(s.db,"SELECT deadline_version,expires_ms,hard_ms FROM executor_reservations WHERE reservation_id=?",field(b,"reservation_id"))
    if !read || len(deadline)!=1 do return fail("storage_error")
    renewal:json.Object
    if deadline[0][0]!=field(b,"deadline_version") {
        confirmed:bool
        renewal,confirmed=child_renewal_locked(s,field(b,"reservation_id"),deadline[0][0],deadline[0][1],deadline[0][2])
        if !confirmed do return fail("invalid_scope")
    }
    r:=make(json.Object,context.temp_allocator)
    for entry in contracts.executor_schema("child_request") do r[entry.name]=b[entry.name]
    digest,_:=contracts.executor_digest("bootstrap",b)
    r["deadline_version"]=json.String(deadline[0][0]);r["expires_ms"]=json.String(deadline[0][1])
    r["bootstrap_digest"]=json.String(digest)
    r["input_digest"]=json.String(contracts.owner_payload_digest(input_raw))
    r["issued_ms"]=json.String(fmt.tprintf("%d",now))
    // The original input may be expired but still name a committed operation.
    // Only the owner may decide receipt replay versus a fresh expired mutation.
    r["request_expires_ms"]=json.String(fmt.tprintf("%d",min(now+contracts.EXECUTOR_FENCE_TTL_MS,num(r,"expires_ms"),num(r,"hard_ms"))))
    r["key_id"]=json.String(executor_key.key_id)
    r["signature"]=json.String(strings.repeat("0",128,context.temp_allocator))
    if !contracts.executor_valid(r,"child_request") || num(r,"request_expires_ms")<=now do return fail("expired")
    signature,signed:=sign.sign(sign.ctx,"child_request",r)
    if !signed do return fail("signer_unavailable")
    r["signature"]=json.String(signature)
    if !contracts.executor_child_request_matches(r,b,input_raw,executor_key,owner_key,now,renewal) do return fail("invalid_scope")
    return Result{code="ok",body=encode(r)}
}
