#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

// Current policy is the newest immutable accepted version per durable agent.
// M3 consumes this policy; existing launched-child bindings and live leases are
// independent. As in the native upsert, editing placement never retires a lease.
fleet_policy_set :: proc(s:^Store,c:json.Object,raw:string,seq:i64) -> string {
    if !transaction_current(s.active) do return "storage_error"
    policy,valid:=contracts.owner_fleet_policy_parse(raw)
    chain:=field(c,"chain_id")
    if !valid do return "invalid_content"
    if policy.task_chain_id!=chain do return "invalid_scope"
    counts,read:=query(s.db,"SELECT count(*) FROM local_fleet_policy_versions")
    if !read do return "storage_error"
    if number(counts[0][0])>=MAX_RECORDS do return "retention_capacity"
    // Identity/create time belong to the original row, not the editing clock.
    old,found:=query(s.db,"SELECT created_at FROM local_fleet_policy_current WHERE chain_id=? AND agent_id=?",chain,policy.agent_id)
    if !found do return "storage_error"
    if len(old)>0 && old[0][0]!=policy.created_at do return "operation_conflict"
    stamp:=fmt.tprintf("%d",seq)
    _,ok:=query(s.db,"INSERT INTO local_fleet_policy_versions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      chain,policy.agent_id,stamp,policy.provider_profile,fmt.tprintf("%d",policy.capacity),
      fmt.tprintf("%d",policy.min_warm),fmt.tprintf("%d",policy.idle_ttl_seconds),
      policy.bridge_models_json,policy.provider,policy.model,policy.roles_json,policy.bridge_id,
      policy.paused_roles_json,policy.created_at,policy.updated_at)
    if !ok do return "storage_error"
    for paused in 0..=1 {
        roles,_:=contracts.owner_fleet_roles(policy.paused_roles_json if paused==1 else policy.roles_json,paused==1)
        for role in roles {
            if _,ok=query(s.db,"INSERT INTO local_fleet_policy_roles VALUES(?,?,?,?,?)",chain,policy.agent_id,stamp,role,fmt.tprintf("%d",paused)); !ok do return "storage_error"
        }
    }
    models,_:=contracts.owner_fleet_models(policy.bridge_models_json)
    for bridge,model in models {
        if _,ok=query(s.db,"INSERT INTO local_fleet_policy_models VALUES(?,?,?,?,?,?,?)",chain,policy.agent_id,stamp,bridge,model.provider_profile,model.provider,model.model); !ok do return "storage_error"
    }
    return "ok"
}

fleet_policy_document :: proc(row:[]string) -> contracts.Owner_Fleet_Policy {
    return contracts.Owner_Fleet_Policy{
        task_chain_id=row[0],agent_id=row[1],provider_profile=row[3],
        capacity=number(row[4]),min_warm=number(row[5]),idle_ttl_seconds=number(row[6]),
        bridge_models_json=row[7],provider=row[8],model=row[9],roles_json=row[10],
        bridge_id=row[11],paused_roles_json=row[12],created_at=row[13],updated_at=row[14],
    }
}
// Paged ordinary source-shaped rows. The chain CAS revision invalidates every
// old page token on any accepted chain mutation. A page never authorizes reads.
fleet_policy_read :: proc(s:^Store,chain:string,p:json.Object,revision:i64) -> Result {
    scope:=contracts.owner_payload_digest(encode([4]string{s.account,chain,"fleet.policy.v1",fmt.tprintf("%d",revision)}))
    after:=""
    if cursor:=field(p,"cursor"); cursor!="" {
        // IDs may themselves contain colons: split only at the digest boundary.
        if len(cursor)<65 || cursor[:64]!=scope || cursor[64]!=':' do return fail("stale_cursor")
        after=cursor[65:]
        if !contracts.owner_field_valid(after,"id") do return fail("malformed")
    }
    rows,ok:=query(s.db,"SELECT * FROM local_fleet_policy_current WHERE chain_id=? AND agent_id>? ORDER BY agent_id LIMIT ?",chain,after,fmt.tprintf("%d",number(field(p,"limit"))+1))
    if !ok do return fail("storage_error")
    result:=doc(map[string]string{"chain_id"=chain,"revision"=fmt.tprintf("%d",revision),"next_cursor"=""})
    items:=make([dynamic]json.Value,context.temp_allocator)
    last:=after
    for row,i in rows {
        if i>=int(number(field(p,"limit"))) do break
        document:=fleet_policy_document(row)
        value,valid:=contracts.owner_content_document(encode(document))
        if !valid do return fail("storage_error")
        item:=make(json.Object,context.temp_allocator)
        item["policy"]=value
        item["accepted_seq"]=json.String(row[2])
        append(&items,item)
        result["items"]=json.Array(items)
        result["next_cursor"]=json.String(fmt.tprintf("%s:%s",scope,row[1]))
        if len(encode(result))>MAX_PAGE {
            ordered_remove(&items,len(items)-1)
            break
        }
        last=row[1]
    }
    if len(rows)>0 && len(items)==0 do return fail("invalid_content")
    next:=""
    if len(items)<len(rows) do next=fmt.tprintf("%s:%s",scope,last)
    result["items"]=json.Array(items)
    result["next_cursor"]=json.String(next)
    return Result{code="ok",body=encode(result)}
}
