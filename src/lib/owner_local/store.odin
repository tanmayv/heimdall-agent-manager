#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// A Store belongs to one enrolled account/owner/profile, with one lifetime writer
// lock. Callers must use a private directory (0700), never a shared Hub database.
Store :: struct {
    mutex: sync.Mutex,
    db, writer: DB,
    account, owner, owner_key: string,
}
SCHEMA :: #load("schema.sql")
MAX_RECORDS :: 100000
MAX_BODY :: 8192
// Two fixed header fields plus one maximum-sized item must fit a page.
// Count JSON string encoding (including quotes), not just decrypted bytes.
MAX_ENCODED_FIELD :: 16384
MAX_PAGE :: 65536
Result :: struct {
    code: string,
    body: string,
    seq: i64,
    replay: bool,
}
Signer :: struct {
    ctx: rawptr,
    sign: proc(ctx:rawptr,kind:string,object:json.Object)->(string,bool),
}

open :: proc(s: ^Store, path, account, owner, owner_key: string) -> bool {
    if s.db != nil || account == "" || owner == "" || owner_key == "" do return false
    // SQLite holds an OS byte-range lock on a separate lifetime lock database.
    // A second process cannot serve this profile, including between transactions.
    if sqlite3_open(strings.clone_to_cstring(fmt.tprintf("%s.writer",path), context.temp_allocator), &s.writer) != 0 do return false
    if !exec(s.writer, "CREATE TABLE IF NOT EXISTS writer_lock(id INTEGER); BEGIN EXCLUSIVE;") { close(s); return false }
    if sqlite3_open(strings.clone_to_cstring(path, context.temp_allocator), &s.db) != 0 { close(s); return false }
    if !exec(s.db, string(SCHEMA)) { close(s); return false }
    if !exec(s.db, "BEGIN IMMEDIATE") { close(s); return false }
    _, inserted := query(s.db, "INSERT OR IGNORE INTO runtime_database(singleton,account_id,owner_bridge_id,owner_key_id) VALUES(1,?,?,?)", account, owner, owner_key)
    rows, read := query(s.db, "SELECT account_id,owner_bridge_id,owner_key_id FROM runtime_database WHERE singleton=1")
    if !inserted || !read || len(rows)!=1 || rows[0][0]!=account || rows[0][1]!=owner || rows[0][2]!=owner_key {
        _ = exec(s.db, "ROLLBACK"); close(s); return false
    }
    if !exec(s.db, "UPDATE runtime_database SET incarnation=incarnation+1; COMMIT") { close(s); return false }
    s.account=strings.clone(account); s.owner=strings.clone(owner); s.owner_key=strings.clone(owner_key)
    return true
}
close :: proc(s: ^Store) {
    if s.db != nil { _ = sqlite3_close(s.db); s.db=nil }
    if s.writer != nil { _ = exec(s.writer, "ROLLBACK"); _ = sqlite3_close(s.writer); s.writer=nil }
    delete(s.account); delete(s.owner); delete(s.owner_key)
    s.account=""; s.owner=""; s.owner_key=""
}
number :: proc(v: string) -> i64 { n,_:=strconv.parse_i64(v); return n }
encode :: proc(v: $T) -> string { b,e:=json.marshal(v, allocator=context.temp_allocator); if e!=nil do return ""; return string(b) }
field :: contracts.owner_string
fail :: proc(code: string) -> Result { return Result{code=code} }
auth_fail :: proc(e: contracts.Owner_Auth_Error) -> Result { return fail(contracts.owner_auth_error_code(e)) }
doc :: proc(values: map[string]string) -> json.Object {
    o:=make(json.Object, context.temp_allocator)
    for k,v in values { o[k]=json.String(v) }
    return o
}
grant :: proc(s:^Store, command:json.Object, now:i64) -> (contracts.Owner_Read_Grant,bool) {
    rows,ok:=query(s.db,"SELECT revision,expires_ms,can_read,can_mutate,revoked FROM local_grants WHERE chain_id=? AND principal_id=? AND key_id=?",field(command,"chain_id"),field(command,"principal_id"),field(command,"key_id"))
    if !ok || len(rows)!=1 do return {},false
    r:=rows[0]
    return contracts.Owner_Read_Grant{account_id=s.account,owner_bridge_id=s.owner,chain_id=field(command,"chain_id"),principal_id=field(command,"principal_id"),key_id=field(command,"key_id"),method=field(command,"method"),
        revision=number(r[0]),expires_ms=number(r[1]),can_read=r[2]=="1",can_mutate=r[3]=="1",revoked=r[4]=="1"},true
}
// Directory verification is done by the Bridge against its paired root before
// entering here. Its pinned sequence/hash is rechecked under the write lock.
// The key is a verified current directory member, never a request assertion.
execute :: proc(s:^Store, command_raw,payload,genesis_raw:string, key,owner_key:contracts.Owner_Verified_Key,
    directory_version:i64,directory_hash:string, now:i64, kr:^vault.Vault_Keyring, sign:Signer) -> Result {
    context.allocator=context.temp_allocator
    c,parsed:=contracts.owner_parse(command_raw,"command")
    if !parsed do return fail("malformed")
    if s.db==nil || key.account_id!=s.account || owner_key.principal_id!=s.owner do return fail("invalid_scope")
    sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
    if !exec(s.db,"BEGIN IMMEDIATE") do return fail("storage_error")
    committed:=false
    defer { if !committed do _=exec(s.db,"ROLLBACK") }
    state,ok:=query(s.db,"SELECT commit_seq,clock_high_ms,directory_version,directory_hash FROM runtime_database WHERE singleton=1")
    if !ok || len(state)!=1 do return fail("storage_error")
    if directory_version<number(state[0][2]) || (directory_version==number(state[0][2]) && directory_hash!=state[0][3]) do return fail("invalid_scope")
    method,chain,task,principal,op:=field(c,"method"),field(c,"chain_id"),field(c,"task_id"),field(c,"principal_id"),field(c,"operation_id")
    g,has_grant:=grant(s,c,now)
    genesis:json.Object
    creating:=method=="chain.create"
    if creating {
        valid:bool
        genesis,valid=contracts.owner_parse(genesis_raw,"genesis")
        if !valid do return fail("malformed")
        if e:=contracts.owner_verify_genesis(genesis,s.account,s.owner,key,owner_key); e!=.None do return auth_fail(e)
        if !contracts.owner_create_binding(c,genesis,payload) do return fail("digest_mismatch")
        if !has_grant {
            existing,looked:=query(s.db,"SELECT chain_id FROM task_chains WHERE chain_id=?",chain)
            if !looked || len(existing)>0 do return fail("invalid_scope")
            g=contracts.Owner_Read_Grant{account_id=s.account,owner_bridge_id=s.owner,chain_id=chain,principal_id=principal,key_id=key.key_id,method=method,revision=1,expires_ms=0x7fffffffffffffff,can_read=true,can_mutate=true}
        }
    } else if !has_grant { return fail("invalid_scope") }
    if e:=contracts.owner_authenticate_command(c,payload,key,g,now);e!=.None do return auth_fail(e)
    if _,pinned:=query(s.db,"UPDATE runtime_database SET directory_version=?,directory_hash=? WHERE singleton=1",fmt.tprintf("%d",directory_version),directory_hash);!pinned do return fail("storage_error")
    digest,_:=contracts.owner_digest("command",c)
    receipts,receipt_ok:=query(s.db,"SELECT method,input_digest,result_json,commit_seq,chain_id,task_id FROM command_receipts WHERE principal_id=? AND operation_id=?",principal,op)
    if !receipt_ok do return fail("storage_error")
    if len(receipts)>0 {
        r:=receipts[0]
        if r[0]!=method || r[1]!=digest || r[4]!=chain || r[5]!=task do return fail("operation_conflict")
        if !exec(s.db,"COMMIT") do return fail("storage_error")
        committed=true
        return Result{code="ok",body=r[2],seq=number(r[3]),replay=true}
    }
    revision:i64
    chains,chain_ok:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !chain_ok do return fail("storage_error")
    if len(chains)>0 do revision=number(chains[0][0])
    if creating && revision>0 do return fail("operation_conflict")
    if !creating && revision==0 do return fail("invalid_scope")
    if method=="task.comment" || method=="task.read" {
        tasks,found:=query(s.db,"SELECT revision FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !found || len(tasks)!=1 do return fail("invalid_scope")
        revision=number(tasks[0][0])
    }
    if e:=contracts.owner_live_admit(c,g,now,revision);e!=.None do return auth_fail(e)
    read:=method=="chain.read" || method=="task.read" || method=="receipt.read"
    if read {
        result:=read_result(s,c,payload,revision)
        if result.code!="ok" do return result
        if !exec(s.db,"COMMIT") do return fail("storage_error")
        committed=true
        return result
    }
    if now<number(state[0][1]) do return fail("clock_uncertain")
    quota,quota_ok:=query(s.db,"SELECT (SELECT COUNT(*) FROM command_receipts),(SELECT COUNT(*) FROM local_changes)")
    if !quota_ok || number(quota[0][0])>=MAX_RECORDS || number(quota[0][1])>=1000000 do return fail("retention_capacity")
    p,_:=contracts.owner_parse(payload,contracts.owner_payload_kind(method))
    title,body,description:string
    for name in ([3]string{"title_cipher","body_cipher","description_cipher"}) {
        cipher:=field(p,name)
        if cipher=="" do continue
        plain,opened:=vault.open(cipher,kr,context.temp_allocator)
        if opened!=.Ok || len(plain)>MAX_BODY do return fail("invalid_content")
        encoded_field:=encode(plain)
        if encoded_field=="" || len(encoded_field)>MAX_ENCODED_FIELD do return fail("invalid_content")
        switch name { case "title_cipher": title=plain
        case "body_cipher": body=plain
        case "description_cipher": description=plain }
    }
    seq:=number(state[0][0])+1
    next:=revision+1
    wrote:=false
    switch method {
    case "chain.create":
        _,wrote=query(s.db,"INSERT INTO task_chains VALUES(?,?,?,?,?,1)",chain,principal,key.key_id,title,description)
        if wrote { _,wrote=query(s.db,"INSERT INTO chain_genesis VALUES(?,?,?,?)",chain,op,field(p,"genesis_digest"),genesis_raw) }
        if wrote { _,wrote=query(s.db,"INSERT INTO local_grants VALUES(?,?,?,1,9223372036854775807,1,1,0)",chain,principal,key.key_id) }
    case "task.create":
        next=1
        _,wrote=query(s.db,"INSERT INTO tasks VALUES(?,?,?,?,1)",chain,task,title,body)
    case "task.comment":
        _,wrote=query(s.db,"INSERT INTO task_comments VALUES(?,?,?,?,?,?)",chain,task,op,principal,body,fmt.tprintf("%d",seq))
        if wrote { _,wrote=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task) }
    }
    if !wrote do return fail("operation_conflict")
    if !creating { if _,ok=query(s.db,"UPDATE task_chains SET revision=revision+1 WHERE chain_id=?",chain);!ok do return fail("storage_error") }
    result:=encode(map[string]string{"chain_id"=chain,"task_id"=task,"operation_id"=op,"revision"=fmt.tprintf("%d",next)})
    if _,ok=query(s.db,"INSERT INTO command_receipts VALUES(?,?,?,?,?,?,?,?,?,?)",principal,op,chain,task,method,digest,key.key_id,field(c,"request_expires_ms"),result,fmt.tprintf("%d",seq));!ok do return fail("storage_error")
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,method,task,fmt.tprintf("%d",next),op);!ok do return fail("storage_error")
    if method=="chain.create" || method=="task.create" {
        genesis_rows,found:=query(s.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id=?",chain)
        if !found || len(genesis_rows)!=1 do return fail("storage_error")
        registry:=doc(map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=chain,"owner_bridge_id"=s.owner,"key_id"=s.owner_key,"genesis_digest"=genesis_rows[0][0],"metadata_revision"=fmt.tprintf("%d",seq),"task_id"=task,
          "chain_title_cipher"="","chain_description_cipher"="","task_title_cipher"="","deleted"="0","signature"=strings.repeat("0",128,context.temp_allocator)})
        if creating { registry["chain_title_cipher"]=p["title_cipher"]; registry["chain_description_cipher"]=p["description_cipher"] } else { registry["task_title_cipher"]=p["title_cipher"] }
        if sign.sign==nil do return fail("storage_error")
        signature,signed:=sign.sign(sign.ctx,"registry",registry)
        if !signed do return fail("storage_error")
        registry["signature"]=json.String(signature)
        if _,ok=query(s.db,"INSERT INTO runtime_intents(intent_id,chain_id,commit_seq,payload_json) VALUES(?,?,?,?)",op,chain,fmt.tprintf("%d",seq),encode(registry));!ok do return fail("storage_error")
    }
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=?,directory_version=?,directory_hash=? WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now),fmt.tprintf("%d",directory_version),directory_hash);!ok do return fail("storage_error")
    if !exec(s.db,"COMMIT") do return fail("storage_error")
    committed=true
    return Result{code="ok",body=result,seq=seq}
}
