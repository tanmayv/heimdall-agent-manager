#+feature dynamic-literals
package executor_local
import "core:encoding/json"
import "core:fmt"
import "core:sync"
import contracts "odin_test:contracts"

// The canonical resource identity is local to this physical Bridge. Directory
// aliases resolving to one path consequently contend for the same resource.
directory_key :: proc(executor,path:string)->string {
    return contracts.owner_payload_digest(encode([2]string{executor,path}))
}
Directory_Mapping :: struct {path,key:string,revision:i64}
// Public callers resolve only a signed, enabled latest version. Historical
// mappings remain evidence and never become current through replay.
directory_mapping :: proc(s:^Store,id:string)->(Directory_Mapping,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return {},false
    rows,ok:=query(s.db,"SELECT directory_path,directory_key,revision,enabled FROM executor_directories WHERE directory_id=? ORDER BY revision DESC LIMIT 1",id)
    if !ok || len(rows)!=1 || rows[0][3]!="1" do return {},false
    return Directory_Mapping{rows[0][0],rows[0][1],number(rows[0][2])},true
}
// Only host operator authority can provision a mapping. An enabled new mapping
// needs the Bridge's freshly canonicalized existing directory under its trusted
// root. Raw remote path assertions cannot satisfy this trusted local proof.
install_directory :: proc(s:^Store,raw:string,key:contracts.Owner_Verified_Key,now:i64,verified_path:string)->Result {
    context.allocator=context.temp_allocator
    o,valid:=contracts.executor_parse(raw,"directory")
    if !valid do return fail("malformed")
    if !scope(s,o) || key.key_id!=s.operator_key || !contracts.executor_verify("directory",o,key) do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("directory",o)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    prior,read:=query(s.db,"SELECT input_digest FROM executor_directories WHERE directory_id=? AND revision=?",field(o,"directory_id"),field(o,"revision"))
    if !read do return fail("storage_error")
    if len(prior)>0 {
        if prior[0][0]!=digest do return fail("operation_conflict")
        return Result{"ok",field(o,"revision"),true}
    }
    if code:=clock(s,now);code!="" do return fail(code)
    rows,ok:=query(s.db,"SELECT directory_path,directory_key,revision FROM executor_directories WHERE directory_id=? ORDER BY revision DESC LIMIT 1",field(o,"directory_id"))
    if !ok do return fail("storage_error")
    expected:i64=1
    if len(rows)>0 do expected=number(rows[0][2])+1
    if expected<=0 || num(o,"revision")!=expected do return fail("stale_revision")
    path:=field(o,"directory_path")
    if field(o,"enabled")=="1" {
        if verified_path=="" || verified_path!=path do return fail("invalid_resources")
    } else if len(rows)!=1 || rows[0][0]!=path {return fail("invalid_resources")}
    resource:=directory_key(s.executor,path)
    old_key:=rows[0][1] if len(rows)>0 else resource
    busy,busy_ok:=query(s.db,"SELECT 1 FROM executor_live_resources WHERE directory_key IN (?,?) LIMIT 1",resource,old_key)
    if !busy_ok do return fail("storage_error")
    if len(busy)>0 do return fail("resources_not_drained")
    quota,quota_ok:=query(s.db,"SELECT count(*) FROM executor_directories")
    if !quota_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    if _,written:=query(s.db,"INSERT INTO executor_directories VALUES(?,?,?,?,?,?,?)",field(o,"directory_id"),fmt.tprintf("%d",expected),path,resource,field(o,"enabled"),digest,raw);!written do return fail("storage_error")
    if !commit(s) do return fail("storage_error")
    return Result{code="ok",body=field(o,"revision")}
}

enrollment_pin :: proc(s:^Store)->(i64,string,bool) {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if s.db==nil || s.unusable do return 0,"",false
    rows,ok:=query(s.db,"SELECT version,head_hash FROM executor_enrollment_pin WHERE singleton=1")
    if !ok || len(rows)!=1 do return 0,"",false
    return number(rows[0][0]),rows[0][1],true
}
// Persist verified paired-directory observations even when command admission
// later rejects. A rejected command must not roll back a revocation observation.
observe_enrollment :: proc(s:^Store,version:i64,head:string)->bool {
    if version<=0 || !contracts.owner_field_valid(head,"hash") do return false
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return false
    defer rollback(s)
    rows,ok:=query(s.db,"UPDATE executor_enrollment_pin SET version=?,head_hash=? WHERE singleton=1 AND (version<? OR (version=? AND head_hash=?)) RETURNING version",
        fmt.tprintf("%d",version),head,fmt.tprintf("%d",version),fmt.tprintf("%d",version),head)
    return ok && len(rows)==1 && commit(s)
}
