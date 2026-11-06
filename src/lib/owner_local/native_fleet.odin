#+feature dynamic-literals
package owner_local

import "core:fmt"
import contracts "odin_test:contracts"

// Source snapshots retain the native fleet row independently from operational
// policy. Neither import nor policy editing enrolls or launches a child.
native_fleet_insert :: proc(s:^Store,source:string,p:contracts.Owner_Fleet_Policy) -> string {
    _,ok:=query(s.db,"INSERT INTO native_fleet_policies VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        p.task_chain_id,source,p.agent_id,p.provider_profile,fmt.tprintf("%d",p.capacity),
        fmt.tprintf("%d",p.min_warm),fmt.tprintf("%d",p.idle_ttl_seconds),p.bridge_models_json,
        p.provider,p.model,p.roles_json,p.bridge_id,p.paused_roles_json,p.created_at,p.updated_at)
    if !ok do return "storage_error"
    return "ok"
}
native_fleet_document :: proc(row:[]string) -> contracts.Owner_Fleet_Policy {
    p:=fleet_policy_document(row)
    p.agent_id=row[2]
    return p
}
native_fleet_policy_matches :: proc(s:^Store,source:string,p:contracts.Owner_Fleet_Policy) -> string {
    rows,ok:=query(s.db,"SELECT * FROM native_fleet_policies WHERE chain_id=? AND source_revision=? AND agent_id=?",p.task_chain_id,source,p.agent_id)
    if !ok do return "storage_error"
    if len(rows)!=1 do return "invalid_scope"
    original:=native_fleet_document(rows[0])
    if encode(original)!=encode(p) do return "operation_conflict"
    return "ok"
}
