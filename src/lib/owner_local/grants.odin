package owner_local

import "core:fmt"
import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Scope is exactly one account/immutable owner/chain and one enrolled browser
// key. Content keys confer no grant authority. Only the genesis creator and the
// paired root (under an explicit enabled policy) may administer grants.
GRANT_MAX_TTL_MS :: 30*24*60*60*1000
Grant_Proof :: struct {
    root: vault.Root_Pin, // durable paired root, never a request assertion
    target: contracts.Owner_Verified_Key, // verified in the same current directory
}
grant_root :: proc(key:contracts.Owner_Verified_Key,proof:Grant_Proof)->bool {
    root:=proof.root
    return root.set && key.enrolled && !key.revoked && key.kind=="device" &&
      key.principal_id==vault.root_pin_device_id(&root) && key.key_id==key.principal_id &&
      key.public_key==vault.hex_encode_lower(root.sign_pub[:],context.temp_allocator)
}
grant_policy :: proc(s:^Store,chain:string)->(i64,bool,bool) {
    rows,ok:=query(s.db,"SELECT revision,recovery_enabled FROM local_grant_policy WHERE chain_id=?",chain)
    if !ok do return 0,false,false
    if len(rows)==0 do return 0,false,true
    return number(rows[0][0]),rows[0][1]=="1",true
}
grant_admin :: proc(s:^Store,chain:string,key:contracts.Owner_Verified_Key,proof:Grant_Proof)->bool {
    rows,ok:=query(s.db,"SELECT creator,creator_key FROM task_chains WHERE chain_id=?",chain)
    if !ok || len(rows)!=1 do return false
    if rows[0][0]==key.principal_id && rows[0][1]==key.key_id do return true
    _,enabled,read:=grant_policy(s,chain)
    return read && enabled && grant_root(key,proof)
}
grant_write :: proc(s:^Store,c,p:json.Object,command_raw,payload:string,key:contracts.Owner_Verified_Key,proof:Grant_Proof,now,seq:i64)->string {
    chain,method:=field(c,"chain_id"),field(c,"method")
    if method=="grant.recover" {
        _,enabled,ok:=grant_policy(s,chain)
        if !ok do return "storage_error"
        // Recovery is a narrow root-signed operation, not a content-read grant.
        if !enabled || !grant_root(key,proof) do return "invalid_scope"
    } else if !grant_admin(s,chain,key,proof) do return "invalid_scope"
    if method=="grant.policy" {
        revision,_,ok:=grant_policy(s,chain)
        if !ok do return "storage_error"
        if number(field(p,"policy_revision"))!=revision+1 do return "stale_revision"
        if _,ok=query(s.db,"INSERT INTO local_grant_policy VALUES(?,?,?) ON CONFLICT(chain_id) DO UPDATE SET revision=excluded.revision,recovery_enabled=excluded.recovery_enabled",chain,field(p,"policy_revision"),field(p,"recovery_enabled"));!ok do return "storage_error"
    } else {
        target,target_key:=field(p,"principal_id"),field(p,"key_id")
        if method=="grant.revoke" {
            rows,ok:=query(s.db,"UPDATE local_grants SET revoked=1,revision=revision+1 WHERE chain_id=? AND principal_id=? AND key_id=? RETURNING revision",chain,target,target_key)
            if !ok do return "storage_error"
            if len(rows)!=1 do return "invalid_scope"
        } else {
            t:=proof.target
            if t.account_id!=s.account || t.principal_id!=target || t.key_id!=target_key ||
              t.kind!="device" || !t.enrolled || t.revoked || target!=target_key { return "invalid_scope" }
            expires:=number(field(p,"expires_ms"))
            if expires<=now || expires-now>GRANT_MAX_TTL_MS do return "expired"
            if field(p,"can_read")!="1" do return "invalid_scope"
            rows,ok:=query(s.db,"SELECT count(*),count(CASE WHEN principal_id=? AND key_id=? THEN 1 END) FROM local_grants WHERE chain_id=?",target,target_key,chain)
            if !ok do return "storage_error"
            if number(rows[0][0])>=MAX_RECORDS && rows[0][1]=="0" do return "retention_capacity"
            if _,ok=query(s.db,`INSERT INTO local_grants VALUES(?,?,?,1,?,?,?,0)
              ON CONFLICT(chain_id,principal_id,key_id) DO UPDATE SET revision=local_grants.revision+1,
              expires_ms=excluded.expires_ms,can_read=excluded.can_read,can_mutate=excluded.can_mutate,revoked=0`,
              chain,target,target_key,field(p,"expires_ms"),field(p,"can_read"),field(p,"can_mutate"));!ok do return "storage_error"
        }
    }
    if _,ok:=query(s.db,"INSERT INTO local_grant_audit VALUES(?,?,?,?,?,?)",chain,fmt.tprintf("%d",seq),key.principal_id,field(c,"operation_id"),command_raw,payload);!ok do return "storage_error"
    return "ok"
}
grant_read :: proc(s:^Store,c,p:json.Object,revision:i64,key:contracts.Owner_Verified_Key,proof:Grant_Proof)->Result {
    chain:=field(c,"chain_id")
    if !grant_admin(s,chain,key,proof) do return fail("invalid_scope")
    policy,enabled,ok:=grant_policy(s,chain)
    if !ok do return fail("storage_error")
    scope:=contracts.owner_payload_digest(encode([3]string{chain,key.principal_id,fmt.tprintf("%d",revision)}))
    offset:i64
    if cursor:=field(p,"cursor");cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || offset>MAX_RECORDS || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    limit:=number(field(p,"limit"))
    rows,read:=query(s.db,"SELECT principal_id,key_id,revision,expires_ms,can_read,can_mutate,revoked FROM local_grants WHERE chain_id=? ORDER BY principal_id,key_id LIMIT ? OFFSET ?",chain,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    if !read do return fail("storage_error")
    next:=""
    visible:=rows[:]
    if len(rows)>int(limit) { visible=rows[:int(limit)];next=fmt.tprintf("%s:%d",scope,offset+limit) }
    body:=encode(struct {revision,policy_revision,recovery_enabled,next_cursor:string, grants:[][]string}{
      fmt.tprintf("%d",revision),fmt.tprintf("%d",policy),"1" if enabled else "0",next,visible})
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
