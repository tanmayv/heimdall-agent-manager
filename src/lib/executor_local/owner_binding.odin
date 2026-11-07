#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:sync"
import contracts "odin_test:contracts"

// First observation requires a currently approved creating device and owner.
// After pinning, creator revocation cannot rewrite that historical genesis.
// The current owner Bridge/key must remain enrolled before every read/retry.
bind_owner :: proc(s:^Store,raw:string,creator,owner:contracts.Owner_Verified_Key,now:i64)->Result {
    context.allocator=context.temp_allocator
    g,valid:=contracts.owner_parse(raw,"genesis")
    if !valid do return fail("malformed")
    if field(g,"account_id")!=s.account || owner.account_id!=s.account || owner.kind!="bridge" ||
       owner.principal_id!=field(g,"owner_bridge_id") || owner.key_id!=field(g,"owner_key_id") ||
       !contracts.owner_verify_signature("genesis",g,"owner_signature",owner) {return fail("invalid_scope")}
    digest,_:=contracts.owner_digest("genesis",g)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    rows,ok:=query(s.db,"SELECT owner_bridge_id,owner_key_id,genesis_digest FROM executor_chain_owners WHERE chain_id=?",field(g,"chain_id"))
    if !ok do return fail("storage_error")
    if len(rows)>0 {
        if rows[0][0]!=owner.principal_id || rows[0][1]!=owner.key_id || rows[0][2]!=digest do return fail("owner_mismatch")
        return Result{"ok",digest,true}
    }
    if contracts.owner_verify_genesis(g,s.account,owner.principal_id,creator,owner)!=.None do return fail("invalid_scope")
    if code:=clock(s,now);code!="" do return fail(code)
    quota,read:=query(s.db,"SELECT count(*) FROM executor_chain_owners")
    if !read do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    if _,written:=query(s.db,"INSERT INTO executor_chain_owners VALUES(?,?,?,?,?)",field(g,"chain_id"),owner.principal_id,owner.key_id,digest,raw);!written do return fail("storage_error")
    if !commit(s) do return fail("storage_error")
    return Result{code="ok",body=digest}
}
owner_bound :: proc(s:^Store,request:json.Object,kind:string,key:contracts.Owner_Verified_Key)->bool {
    if !scope(s,request) || (kind!="prepare" && kind!="action") || !contracts.executor_verify(kind,request,key) do return false
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return false
    rows,ok:=query(s.db,"SELECT 1 FROM executor_chain_owners WHERE chain_id=? AND owner_bridge_id=? AND owner_key_id=?",
        field(request,"chain_id"),key.principal_id,key.key_id)
    return ok && len(rows)==1
}
issued_configuration :: proc(s:^Store,instance:string)->(string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return "",false
    rows,ok:=query(s.db,"SELECT configuration FROM executor_issuances WHERE instance_id=?",instance)
    if !ok || len(rows)!=1 do return "",false
    return rows[0][0],true
}
// Bind a fresh prepare to facts this exact executor actually allocated.
// A remote owner's signature cannot create arbitrary instance/token/path facts.
issued_prepare_resources :: proc(s:^Store,p:json.Object)->(Resolved_Resources,bool) {
    if !contracts.executor_valid(p,"prepare") || !scope(s,p) do return {},false
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable || num(p,"executor_incarnation")!=s.incarnation do return {},false
    rows,ok:=query(s.db,"SELECT configuration FROM executor_issuances WHERE instance_id=?",field(p,"instance_id"))
    if !ok || len(rows)!=1 do return {},false
    c,valid:=contracts.owner_parse(rows[0][0],"remote_configuration")
    if !valid do return {},false
    for name in ([14]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","instance_id",
        "launch_epoch","run_count","token_generation","configuration_revision","executor_incarnation","policy_revision","slot_id","provider_profile"}) {
        if field(p,name)!=field(c,name) do return {},false
    }
    if field(p,"directory_key")!=field(c,"directory_key") do return {},false
    mapping,mapped:=query(s.db,"SELECT directory_path,directory_key,enabled FROM executor_directories WHERE directory_id=? ORDER BY revision DESC LIMIT 1",field(c,"directory_id"))
    if !mapped || len(mapping)!=1 || mapping[0][2]!="1" || mapping[0][0]!=field(c,"directory_path") || mapping[0][1]!=field(c,"directory_key") do return {},false
    return Resolved_Resources{field(c,"directory_key"),field(c,"provider_profile"),field(c,"instance_id"),field(c,"configuration_revision")},true
}
