#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Generated once before the first dispatch, stored only in the Bridge ledger.
// A query-only launch recovery must never create a new control credential.
launch_control :: proc(s:^Store,intent:Intent,now:i64)->(string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if intent.kind!="launch" || !begin(s) do return "",false
    defer rollback(s)
    if _,current:=intent_current_locked(s,intent,now);!current do return "",false
    dispatch,read:=query(s.db,"SELECT claim_incarnation FROM executor_intents WHERE reservation_id=? AND kind='launch' AND state='uncertain'",intent.reservation)
    if !read || len(dispatch)!=1 || dispatch[0][0]!="0" do return "",false
    rows,ok:=query(s.db,"SELECT renewal_secret FROM executor_controls WHERE reservation_id=?",intent.reservation)
    if !ok do return "",false
    secret:=""
    if len(rows)==1 {
        secret=rows[0][0]
    } else {
        bytes:[32]byte
        if !random.fill(bytes[:]) do return "",false
        secret=vault.hex_encode_lower(bytes[:],context.temp_allocator)
        if _,written:=query(s.db,"INSERT INTO executor_controls VALUES(?,?)",intent.reservation,secret);!written do return "",false
    }
    if !commit(s) do return "",false
    return secret,true
}

Renewal_Material :: struct {
    reservation,instance,launch_key,secret,action:string,
    version,expires,hard:i64,
}
// Read only exact accepted actions for an already confirmed child of this
// serving incarnation. It cannot adopt a replacement, spawn or grant anything.
renewal_material :: proc(s:^Store,raw:string,now:i64)->(Renewal_Material,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return {},false
    defer rollback(s)
    a,valid:=contracts.executor_parse(raw,"action")
    if !valid || field(a,"method")!="heartbeat" || !scope(s,a) || num(a,"executor_incarnation")!=s.incarnation do return {},false
    if code:=clock(s,now);code!="" do return {},false
    digest,_:=contracts.executor_digest("action",a)
    rows,ok:=query(s.db,`SELECT r.instance_id,r.launch_key,c.renewal_secret FROM executor_reservations r
      JOIN executor_controls c USING(reservation_id) JOIN executor_renewals n USING(reservation_id)
      WHERE r.reservation_id=? AND r.state='active' AND r.launch_state='confirmed'
        AND r.executor_incarnation=? AND r.observed_incarnation=? AND r.deadline_version=?
        AND r.expires_ms=? AND r.hard_ms=? AND r.prepare_digest=? AND r.grant_generation=?
        AND r.owner_bridge_id=? AND r.chain_id=? AND n.deadline_version=r.deadline_version
        AND n.action_digest=? AND n.document=?
        AND (SELECT incarnation FROM executor_owner_watermarks WHERE owner_bridge_id=r.owner_bridge_id)=?
        AND r.expires_ms>CAST(? AS INTEGER) AND r.hard_ms>CAST(? AS INTEGER)`,
        field(a,"reservation_id"),fmt.tprintf("%d",s.incarnation),fmt.tprintf("%d",s.incarnation),field(a,"deadline_version"),
        field(a,"expires_ms"),field(a,"hard_ms"),field(a,"prepare_digest"),field(a,"grant_generation"),
        field(a,"owner_bridge_id"),field(a,"chain_id"),digest,raw,field(a,"owner_incarnation"),fmt.tprintf("%d",now),fmt.tprintf("%d",now))
    if !ok || len(rows)!=1 || !commit(s) do return {},false
    return {field(a,"reservation_id"),rows[0][0],rows[0][1],rows[0][2],raw,
        num(a,"deadline_version"),num(a,"expires_ms"),num(a,"hard_ms")},true
}

// A successful exact daemon reply is required. The caller holds startup I/O
// serialization and rechecks this same material immediately before the IPC.
renewal_confirm :: proc(s:^Store,m:Renewal_Material,now:i64)->bool {
    current,valid:=renewal_material(s,m.action,now)
    if !valid || current!=m do return false
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return false
    defer rollback(s)
    if code:=clock(s,now);code!="" do return false
    rows,ok:=query(s.db,"UPDATE executor_renewals SET state='confirmed' WHERE reservation_id=? AND deadline_version=? AND document=? RETURNING reservation_id",
        m.reservation,fmt.tprintf("%d",m.version),m.action)
    return ok && len(rows)==1 && commit(s)
}

// Caller already holds s.mutex. Only confirmed physical deadline evidence can
// supplement the immutable bootstrap. Never use an owner result or receipt.
child_renewal_locked :: proc(s:^Store,reservation,version,expires,hard:string)->(json.Object,bool) {
    rows,ok:=query(s.db,"SELECT document FROM executor_renewals WHERE reservation_id=? AND deadline_version=? AND state='confirmed'",reservation,version)
    if !ok || len(rows)!=1 do return nil,false
    a,valid:=contracts.executor_parse(rows[0][0],"action")
    return a,valid && field(a,"method")=="heartbeat" && field(a,"reservation_id")==reservation &&
        field(a,"deadline_version")==version && field(a,"expires_ms")==expires && field(a,"hard_ms")==hard
}
