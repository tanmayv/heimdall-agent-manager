#+feature dynamic-literals
package http

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"
import taskchain_service "odin_test:hub/service/taskchain"
import vault "odin_test:lib/vault"

migration_http_doc :: proc(values:map[string]string)->json.Object {
    o:=make(json.Object,context.temp_allocator)
    for k,v in values do o[k]=json.String(v)
    return o
}
migration_http_sign :: proc(priv:^ecdsa.Private_Key,kind:string,o:^json.Object,field:string) {
    canonical,_:=contracts.owner_canonical(kind,o^)
    sig,_:=vault.sign_p256(priv,transmute([]byte)canonical)
    o^[field]=json.String(vault.hex_encode_lower(sig.sig[:],context.temp_allocator))
}
migration_http_key :: proc(priv:^ecdsa.Private_Key,principal,key_id,kind:string)->contracts.Owner_Verified_Key {
    pub:[65]byte
    ecdsa.private_key_public_bytes(priv,pub[:])
    return {"account",principal,key_id,vault.hex_encode_lower(pub[:],context.temp_allocator),kind,true,false}
}

// The Hub cuts over only on a receipt the selected owner signed for the exact
// manifest and genesis; route registration and `imported` commit together.
@(test)
owner_migration_cutover_verifies_receipt_then_commits_route_and_import_once :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    conn,opened,_:=sqlite.open(":memory:")
    if !testing.expect(t,opened) do return
    defer sqlite.close(&conn)
    migrated,_:=sqlite.run_migrations(&conn)
    if !testing.expect(t,migrated) do return
    impl:sqlite.Taskchain_Repo_SQLite
    repo:=sqlite.new_taskchain_repository(&impl,&conn)
    tasks:=taskchain_service.Taskchain_Service{repo=&repo}
    h:=Bridge_Handlers{taskchains=&tasks}
    testing.expect(t,sqlite.exec(&conn,`INSERT INTO task_chains(chain_id,owner_user_id,title,kind,created_at,updated_at) VALUES('chain','account','t','mixed_work','c','u')`))
    device_priv,owner_priv:ecdsa.Private_Key
    testing.expect(t,vault.p256_private_key_generate(&device_priv) && vault.p256_private_key_generate(&owner_priv))
    defer {ecdsa.private_key_clear(&device_priv);ecdsa.private_key_clear(&owner_priv)}
    device:=migration_http_key(&device_priv,"device","device","device")
    owner:=migration_http_key(&owner_priv,"bridge","bridge_key","bridge")
    zeros:=strings.repeat("0",128)
    selection:=migration_http_doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","migration_id"="mig","owner_bridge_id"="bridge","owner_key_id"="bridge_key",
        "principal_id"="device","key_id"="device","expected_work_revision"="0","request_expires_ms"="1","signature"=zeros})
    migration_http_sign(&device_priv,"migration_selection",&selection,"signature")
    genesis:=migration_http_doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","creation_op"="mig","owner_bridge_id"="bridge","owner_key_id"="bridge_key",
        "creator_id"="device","creator_key_id"="device","schema_version"="1","creator_signature"=zeros,"owner_signature"=zeros})
    migration_http_sign(&device_priv,"genesis",&genesis,"creator_signature")
    submitted:=migration_http_doc(map[string]string{});for k,v in genesis do submitted[k]=v
    migration_http_sign(&owner_priv,"genesis",&genesis,"owner_signature")
    selection_digest,_:=contracts.owner_digest("migration_selection",selection)
    genesis_digest,_:=contracts.owner_digest("genesis",genesis)
    manifest:=strings.repeat("1",64)
    receipt:=migration_http_doc(map[string]string{"protocol_version"="1","account_id"="account","chain_id"="chain","migration_id"="mig","owner_bridge_id"="bridge","key_id"="bridge_key",
        "selection_digest"=selection_digest,"manifest_digest"=manifest,"genesis_digest"=genesis_digest,"database_id"="db","import_seq"="4","schema_version"="1","signature"=zeros})
    migration_http_sign(&owner_priv,"migration_import_receipt",&receipt,"signature")
    reply:=Owner_Migration_Import_Reply{"command_result","cmd","ok",owner_json(receipt),owner_json(genesis)}
    s:=domain.Legacy_Migration_Selection{"account","chain","mig","bridge","bridge_key",selection_digest,0}
    rows,_:=sqlite.legacy_metadata(&conn,"SELECT work_revision FROM task_chains WHERE chain_id='chain'",1)
    for b in rows[0][0] do s.expected_work_revision=s.expected_work_revision*10+i64(b-'0')
    fence,blockers,err:=repo.legacy_migration_freeze_now(repo.ctx,s)
    if !testing.expect(t,err.code==.None && len(blockers)==0 && fence.state=="frozen") do return
    // A receipt for another manifest is rejected; nothing is registered.
    _,_,cerr:=owner_migration_cutover(&h,"account","chain","mig",strings.repeat("2",64),selection,submitted,reply,owner)
    testing.expect_value(t,cerr.code,domain.Error_Code.Conflict)
    // A receipt signed by another key is rejected.
    forged:=reply
    other:=receipt;other_priv:ecdsa.Private_Key
    testing.expect(t,vault.p256_private_key_generate(&other_priv));defer ecdsa.private_key_clear(&other_priv)
    copy_receipt:=migration_http_doc(map[string]string{});for k,v in other do copy_receipt[k]=v
    migration_http_sign(&other_priv,"migration_import_receipt",&copy_receipt,"signature")
    forged.receipt=owner_json(copy_receipt)
    _,_,cerr=owner_migration_cutover(&h,"account","chain","mig",manifest,selection,submitted,forged,owner)
    testing.expect_value(t,cerr.code,domain.Error_Code.Conflict)
    // The owner cannot substitute the genesis the device signed.
    swapped:=reply
    altered:=migration_http_doc(map[string]string{});for k,v in genesis do altered[k]=v
    altered["schema_version"]=json.String("2")
    swapped.genesis=owner_json(altered)
    _,_,cerr=owner_migration_cutover(&h,"account","chain","mig",manifest,selection,submitted,swapped,owner)
    testing.expect_value(t,cerr.code,domain.Error_Code.Conflict)
    f,_,_:=repo.legacy_source_get(repo.ctx,"account","chain")
    routes,_:=sqlite.legacy_metadata(&conn,"SELECT 1 FROM owner_local_chains",1)
    testing.expect(t,f.state=="frozen" && len(routes)==0,"rejected evidence leaves the chain frozen with no route")
    digest,replayed,ok_err:=owner_migration_cutover(&h,"account","chain","mig",manifest,selection,submitted,reply,owner)
    testing.expect(t,ok_err.code==.None && !replayed && digest==contracts.owner_payload_digest(reply.receipt))
    f,_,_=repo.legacy_source_get(repo.ctx,"account","chain")
    routes,_=sqlite.legacy_metadata(&conn,"SELECT genesis_json FROM owner_local_chains WHERE chain_id='chain'",1)
    testing.expect(t,f.state=="imported" && f.manifest_digest==manifest && len(routes)==1 && routes[0][0]==reply.genesis)
    testing.expect(t,!sqlite.exec(&conn,"UPDATE task_chains SET title='legacy write' WHERE chain_id='chain'"),"legacy writer disabled before any local activation")
    _,replayed,ok_err=owner_migration_cutover(&h,"account","chain","mig",manifest,selection,submitted,reply,owner)
    testing.expect(t,ok_err.code==.None && replayed)
}
