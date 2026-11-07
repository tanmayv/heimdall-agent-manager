#+feature dynamic-literals
package executor_local

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// One ledger per execution device, shared by all owners and launch purposes.
// No task tables or task mutation APIs exist in this package.
Store :: struct {mutex:sync.Mutex, db,writer:DB, account,executor,operator_key:string, incarnation:i64, unusable,clock_uncertain:bool}
MAX_RECORDS :: 100000
Result :: struct {code,body:string,replay:bool}
Resolved_Resources :: struct {directory_key,provider_profile,instance_id,configuration_revision:string}
Current_Owner_Fence :: struct {
    // Trusted result of current owner validation, never decoded from a request.
    current:bool,
    prepare_digest:string,
    owner_incarnation,commit_seq:i64,
}
Child_Observation :: struct {
    // Trusted exact daemon query result. PID/timeout alone is never absence.
    instance,launch_key:string,
    executor_incarnation:i64,
    present:bool,
}
Intent :: struct {reservation,kind,instance,launch_key,document:string,incarnation:i64}
field :: contracts.owner_string
number :: proc(s:string)->i64 {n,_:=strconv.parse_i64(s);return n}
num :: contracts.executor_number
encode :: proc(v:$T)->string {b,e:=json.marshal(v,allocator=context.temp_allocator);if e!=nil do return "";return string(b)}
fail :: proc(code:string)->Result {return {code=code}}
open :: proc(s:^Store,path,account,executor,operator_key:string)->bool {
    if s.db!=nil || account=="" || executor=="" || operator_key=="" do return false
    if sqlite3_open(strings.clone_to_cstring(fmt.tprintf("%s.writer",path),context.temp_allocator),&s.writer)!=0 {close(s);return false}
    if !exec(s.writer,"CREATE TABLE IF NOT EXISTS writer_lock(id INTEGER); BEGIN EXCLUSIVE;") {close(s);return false}
    if sqlite3_open(strings.clone_to_cstring(path,context.temp_allocator),&s.db)!=0 {close(s);return false}
    when ODIN_OS!=.Windows {
        if os.chmod(path,{.Read_User,.Write_User})!=nil || os.chmod(fmt.tprintf("%s.writer",path),{.Read_User,.Write_User})!=nil {close(s);return false}
    }
    if !exec(s.db,"PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; BEGIN IMMEDIATE;") {close(s);return false}
    good:=false
    defer if !good { _=exec(s.db,"ROLLBACK");close(s) }
    tables,ok:=query(s.db,"SELECT name FROM sqlite_master WHERE type='table' AND name='executor_runtime'")
    if !ok do return false
    if len(tables)==0 {
        existing,read:=query(s.db,"SELECT name FROM sqlite_master WHERE type='table'")
        if !read || len(existing)>0 || !exec(s.db,string(#load("schema.sql"))) do return false
        if _,written:=query(s.db,"INSERT INTO executor_runtime VALUES(1,3,?,?,?,1,0,'ready',0,0)",account,executor,operator_key);!written do return false
    } else {
        rows,read:=query(s.db,"SELECT schema_version,account_id,executor_bridge_id,operator_key_id,incarnation FROM executor_runtime WHERE singleton=1")
        if !read || len(rows)!=1 || (rows[0][0]!="1" && rows[0][0]!="2" && rows[0][0]!="3") || rows[0][1]!=account || rows[0][2]!=executor || rows[0][3]!=operator_key || number(rows[0][4])==0x7fffffffffffffff do return false
        if rows[0][0]=="1" && !exec(s.db,string(#load("migration_002.sql"))) do return false
        if (rows[0][0]=="1" || rows[0][0]=="2") && !exec(s.db,string(#load("migration_003.sql"))) do return false
        if !exec(s.db,"UPDATE executor_runtime SET incarnation=incarnation+1,recovery_state='reconciling'; UPDATE executor_reservations SET state='released' WHERE state='prepared';") do return false
    }
    rows,read:=query(s.db,"SELECT incarnation FROM executor_runtime WHERE singleton=1")
    if !read || len(rows)!=1 || !exec(s.db,"COMMIT") do return false
    s.incarnation=number(rows[0][0]);s.account=strings.clone(account);s.executor=strings.clone(executor);s.operator_key=strings.clone(operator_key)
    good=true
    return true
}
close :: proc(s:^Store) {
    if s.db!=nil {_=exec(s.db,"ROLLBACK");_=sqlite3_close(s.db);s.db=nil}
    if s.writer!=nil {_=exec(s.writer,"ROLLBACK");_=sqlite3_close(s.writer);s.writer=nil}
    delete(s.account);delete(s.executor);delete(s.operator_key)
    s.account="";s.executor="";s.operator_key="";s.incarnation=0;s.unusable=false;s.clock_uncertain=false
}
begin :: proc(s:^Store)->bool {return s.db!=nil && !s.unusable && exec(s.db,"BEGIN IMMEDIATE")}
rollback :: proc(s:^Store) {
    _=exec(s.db,"ROLLBACK")
    if sqlite3_get_autocommit(s.db)==0 do s.unusable=true
    if s.clock_uncertain {
        if !exec(s.db,"UPDATE executor_runtime SET recovery_state='clock_uncertain'") do s.unusable=true
        s.clock_uncertain=false
    }
}
commit :: proc(s:^Store)->bool {if exec(s.db,"COMMIT") do return true;rollback(s);return false}
scope :: proc(s:^Store,o:json.Object)->bool {return field(o,"account_id")==s.account && field(o,"executor_bridge_id")==s.executor}
clock :: proc(s:^Store,now:i64,require_ready:=true)->string {
    rows,ok:=query(s.db,"SELECT clock_high_ms,recovery_state FROM executor_runtime WHERE singleton=1")
    if !ok || len(rows)!=1 do return "storage_error"
    if now<0 || now<number(rows[0][0]) {s.clock_uncertain=true;return "clock_uncertain"}
    if require_ready && rows[0][1]!="ready" do return "recovery_required"
    _,ok=query(s.db,"UPDATE executor_runtime SET clock_high_ms=? WHERE singleton=1",fmt.tprintf("%d",now))
    return "" if ok else "storage_error"
}
request_live :: proc(o:json.Object,now:i64)->bool {
    expires:=num(o,"request_expires_ms")
    return expires>now && expires-now<=contracts.OWNER_REQUEST_TTL_MS
}
receipt :: proc(s:^Store,owner,op,kind,digest:string)->(Result,bool) {
    rows,ok:=query(s.db,"SELECT kind,input_digest,result_json FROM executor_receipts WHERE owner_bridge_id=? AND operation_id=?",owner,op)
    if !ok do return fail("storage_error"),true
    if len(rows)==0 do return {},false
    if rows[0][0]!=kind || rows[0][1]!=digest do return fail("operation_conflict"),true
    return Result{"ok",rows[0][2],true},true
}
save_receipt :: proc(s:^Store,o:json.Object,kind,digest,body:string)->bool {
    _,ok:=query(s.db,"INSERT INTO executor_receipts VALUES(?,?,?,?,?,?)",field(o,"owner_bridge_id"),field(o,"operation_id"),kind,digest,field(o,"reservation_id"),body)
    return ok
}
result_body :: proc(s:^Store,id:string)->(string,bool) {
    rows,ok:=query(s.db,"SELECT reservation_id,state,prepare_digest,launch_key,deadline_version,expires_ms,hard_ms,launch_state,executor_incarnation FROM executor_reservations WHERE reservation_id=?",id)
    if !ok || len(rows)!=1 do return "",false
    row:=rows[0]
    return encode(struct{reservation_id,state,prepare_digest,launch_key,deadline_version,expires_ms,hard_ms,launch_state,executor_incarnation,child_incarnation:string}{row[0],row[1],row[2],row[3],row[4],row[5],row[6],row[7],fmt.tprintf("%d",s.incarnation),row[8]}),true
}
install_policy :: proc(s:^Store,raw:string,key:contracts.Owner_Verified_Key,now:i64)->Result {
    context.allocator=context.temp_allocator
    o,valid:=contracts.executor_parse(raw,"policy")
    if !valid do return fail("malformed")
    if !scope(s,o) || key.key_id!=s.operator_key || !contracts.executor_verify("policy",o,key) do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("policy",o)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    prior,read:=query(s.db,"SELECT input_digest FROM executor_policies WHERE revision=?",field(o,"policy_revision"))
    if !read do return fail("storage_error")
    if len(prior)>0 {
        if prior[0][0]!=digest do return fail("operation_conflict")
        return Result{"ok",field(o,"policy_revision"),true}
    }
    if code:=clock(s,now);code!="" do return fail(code)
    quota,q_ok:=query(s.db,"SELECT count(*) FROM executor_policies")
    if !q_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS do return fail("retention_capacity")
    rows,ok:=query(s.db,"SELECT policy_revision,(SELECT count(*) FROM executor_reservations WHERE state!='released') FROM executor_runtime WHERE singleton=1")
    if !ok || len(rows)!=1 do return fail("storage_error")
    if num(o,"policy_revision")!=number(rows[0][0])+1 do return fail("stale_revision")
    if rows[0][1]!="0" do return fail("resources_not_drained")
    // Released reservations retain foreign keys; slots persist and may only
    // be removed from admission, never erased from historical identity.
    if !exec(s.db,"UPDATE executor_slots SET enabled=0") do return fail("storage_error")
    v,_:=contracts.owner_request_document(field(o,"slots_json"));slots,_:=v.(json.Array)
    for slot in slots {
        row,_:=slot.(json.Object)
        if _,written:=query(s.db,"INSERT INTO executor_slots VALUES(?,?,?) ON CONFLICT(slot_id) DO UPDATE SET provider_profile=excluded.provider_profile,enabled=excluded.enabled",field(row,"slot_id"),field(row,"provider_profile"),field(row,"enabled"));!written do return fail("storage_error")
    }
    if _,written:=query(s.db,"INSERT INTO executor_policies VALUES(?,?,?)",field(o,"policy_revision"),digest,raw);!written do return fail("storage_error")
    if _,written:=query(s.db,"UPDATE executor_runtime SET policy_revision=?,device_capacity=? WHERE singleton=1",field(o,"policy_revision"),field(o,"device_capacity"));!written do return fail("storage_error")
    if !commit(s) do return fail("storage_error")
    return Result{code="ok",body=field(o,"policy_revision")}
}
owner_watermark :: proc(s:^Store,owner:string,inc:i64)->bool {
    rows,ok:=query(s.db,"SELECT incarnation FROM executor_owner_watermarks WHERE owner_bridge_id=?",owner)
    if !ok || (len(rows)>0 && inc<number(rows[0][0])) do return false
    _,ok=query(s.db,"INSERT INTO executor_owner_watermarks VALUES(?,?) ON CONFLICT(owner_bridge_id) DO UPDATE SET incarnation=excluded.incarnation",owner,fmt.tprintf("%d",inc))
    return ok
}
prepare :: proc(s:^Store,raw:string,key:contracts.Owner_Verified_Key,now:i64,resources:Resolved_Resources)->Result {
    context.allocator=context.temp_allocator
    o,valid:=contracts.executor_parse(raw,"prepare")
    if !valid do return fail("malformed")
    if !scope(s,o) || !contracts.executor_verify("prepare",o,key) do return fail("invalid_scope")
    digest,_:=contracts.executor_digest("prepare",o)
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    if !begin(s) do return fail("storage_error")
    defer rollback(s)
    if prior,found:=receipt(s,field(o,"owner_bridge_id"),field(o,"operation_id"),"prepare",digest);found do return prior
    if resources.directory_key!=field(o,"directory_key") || resources.provider_profile!=field(o,"provider_profile") ||
       resources.instance_id!=field(o,"instance_id") || resources.configuration_revision!=field(o,"configuration_revision") { return fail("invalid_resources") }
    if !request_live(o,now) || num(o,"prepare_until_ms")<=now || num(o,"prepare_until_ms")-now>contracts.EXECUTOR_PREPARE_TTL_MS do return fail("expired")
    if code:=clock(s,now);code!="" do return fail(code)
    if num(o,"executor_incarnation")!=s.incarnation do return fail("stale_incarnation")
    if !owner_watermark(s,field(o,"owner_bridge_id"),num(o,"owner_incarnation")) do return fail("stale_owner")
    quota,q_ok:=query(s.db,"SELECT (SELECT count(*) FROM executor_reservations),(SELECT count(*) FROM executor_receipts)")
    if !q_ok do return fail("storage_error")
    if number(quota[0][0])>=MAX_RECORDS || number(quota[0][1])>=MAX_RECORDS do return fail("retention_capacity")
    rows,read:=query(s.db,"SELECT policy_revision,device_capacity,(SELECT count(*) FROM executor_reservations WHERE state!='released') FROM executor_runtime WHERE singleton=1")
    if !read || len(rows)!=1 do return fail("storage_error")
    if rows[0][0]!=field(o,"policy_revision") do return fail("stale_policy")
    if number(rows[0][2])>=number(rows[0][1]) do return fail("capacity_exhausted")
    slots,found:=query(s.db,"SELECT 1 FROM executor_slots WHERE slot_id=? AND provider_profile=? AND enabled=1",field(o,"slot_id"),field(o,"provider_profile"))
    if !found do return fail("storage_error")
    if len(slots)!=1 do return fail("invalid_slot")
    conflicts,checked:=query(s.db,"SELECT 1 FROM executor_reservations WHERE state!='released' AND (slot_id=? OR instance_id=? OR (directory_key!='' AND directory_key=?))",field(o,"slot_id"),field(o,"instance_id"),field(o,"directory_key"))
    if !checked do return fail("storage_error")
    if len(conflicts)>0 do return fail("resource_conflict")
    existing,existing_ok:=query(s.db,"SELECT 1 FROM executor_reservations WHERE reservation_id=?",field(o,"reservation_id"))
    if !existing_ok do return fail("storage_error")
    if len(existing)>0 do return fail("operation_conflict")
    launch_key:=contracts.owner_payload_digest(encode([3]string{s.executor,field(o,"reservation_id"),digest}))
    _,written:=query(s.db,"INSERT INTO executor_reservations VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'prepared',?,'none',0)",
        field(o,"reservation_id"),field(o,"owner_bridge_id"),field(o,"operation_id"),field(o,"chain_id"),field(o,"slot_id"),field(o,"instance_id"),field(o,"directory_key"),
        digest,raw,field(o,"owner_incarnation"),field(o,"executor_incarnation"),field(o,"grant_generation"),"1",field(o,"prepare_until_ms"),field(o,"prepare_until_ms"),field(o,"hard_ms"),launch_key)
    if !written do return fail("storage_error")
    body,ok:=result_body(s,field(o,"reservation_id"))
    if !ok || !save_receipt(s,o,"prepare",digest,body) || !commit(s) do return fail("storage_error")
    return Result{code="ok",body=body}
}
