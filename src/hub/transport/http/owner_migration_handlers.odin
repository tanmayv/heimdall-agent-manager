package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"
import vd "odin_test:hub/service/vault_directory"
import vault "odin_test:lib/vault"

// R3 one-shot legacy import (Hub side).
//   GET  /api/v1/owner-local/migrations/preflight?chain_id=  (user)   blockers + work revision
//   POST /api/v1/owner-local/migrations                     (user)   select+freeze, relay import, cutover
//   GET  /api/v1/owner-local/migrations/export?migration_id=&part=  (owner Bridge) manifest (part=manifest) or document N
//   GET  /api/v1/owner-local/migrations/state?migration_id= (owner Bridge) state for activation
// The Hub never activates the owner: after its cutover commits it only nudges
// the Bridge, which re-derives activation from /state on every restart.
OWNER_MIGRATION_IMPORT_TIMEOUT_MS :: 120_000

// External effects of the migrate POST, injectable for handler tests.
Owner_Migration_Env :: struct {
    keys:proc(h:^Bridge_Handlers,account:string,selection:json.Object)->(contracts.Owner_Verified_Key,contracts.Owner_Verified_Key,vault.Directory_Verification_Input,bool),
    bridge_owned:proc(h:^Bridge_Handlers,auth:contracts.Auth_Context,bridge_id:string)->(bool,domain.Domain_Error),
    bridge_live:proc(h:^Bridge_Handlers,bridge_id:string)->bool,
    relay:proc(h:^Bridge_Handlers,bridge_id,command_id,body:string)->(string,bool,domain.Domain_Error),
    nudge:proc(h:^Bridge_Handlers,account,bridge_id,migration,chain_id,manifest_digest:string)->bool,
}
owner_migration_default_env :: proc()->Owner_Migration_Env {
    return {
        keys=owner_migration_keys,
        bridge_owned=proc(h:^Bridge_Handlers,auth:contracts.Auth_Context,bridge_id:string)->(bool,domain.Domain_Error) {
            _,owned,err:=bridge_service.get_bridge(h.bridges,auth,bridge_id)
            return owned,err
        },
        bridge_live=proc(h:^Bridge_Handlers,bridge_id:string)->bool { return project_service.bridge_runtime_registry_has_live(h.bridge_runtime_registry,bridge_id) },
        relay=proc(h:^Bridge_Handlers,bridge_id,command_id,body:string)->(string,bool,domain.Domain_Error) {
            raw,received,err:=bridge_runtime.send_runtime_command_wait(h.bridge_runtime_registry,project_service.Runtime_Command{bridge_id=bridge_id,command_id=command_id,body_json=body},OWNER_MIGRATION_IMPORT_TIMEOUT_MS)
            if !received do return "",false,err
            out:=strings.clone(raw,context.temp_allocator)
            delete(raw,runtime.default_allocator())
            return out,true,{}
        },
        nudge=owner_migration_activate_nudge,
    }
}
Owner_Migration_Request :: struct { selection,genesis:string }
Owner_Migration_Abort_Request :: struct { chain_id,migration_id:string }
Owner_Migration_Preflight :: struct {
    chain_id,state,migration_id,owner_bridge_id:string,
    work_revision:i64,
    blockers:[]domain.Legacy_Migration_Blocker,
}
Owner_Migration_Result :: struct {
    state,migration_id,chain_id,manifest_digest,receipt_digest:string,
    replayed,activation_sent:bool,
}
Owner_Migration_Import_Command :: struct {
    type,command_id,account_id,migration_id,chain_id,selection,genesis,manifest_digest:string,
    directory:vault.Directory_Verification_Input,
}
Owner_Migration_Activate_Command :: struct {
    type,command_id,account_id,migration_id,chain_id,manifest_digest:string,
}
Owner_Migration_Import_Reply :: struct { type,command_id,code,receipt,genesis:string }
Owner_Migration_Part :: struct { migration_id,manifest_digest,part,body:string }
Owner_Migration_State :: struct { migration_id,chain_id,state,manifest_digest,owner_bridge_id:string }

owner_migration_blocked :: proc(blockers:[]domain.Legacy_Migration_Blocker,request_id:string)->Response {
    detail:=owner_json(struct{code:string,blockers:[]domain.Legacy_Migration_Blocker}{"migration_blocked",blockers})
    return respond_error(domain.domain_error(.Conflict,"chain has live work; settle it before migrating",detail),request_id)
}

owner_migration_preflight_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    // The device signatures carry consent; an instance token only transports
    // a browser-signed request (ham-ctl), exactly like the owner relay.
    auth,ok,resp:=require_auth_any(h.auth,req)
    if !ok do return resp
    if !contracts.is_user_auth(auth) && auth.kind!=.Instance_Token do return respond_error(domain.domain_error(.Forbidden,"user authentication required"),req.request_id)
    chain_id:=query_value(req.query,"chain_id")
    chain,exists,err:=h.chains.get_chain(h.chains.ctx,domain.Task_Chain_ID(chain_id))
    if err.code!=.None do return respond_error(err,req.request_id)
    if !exists || string(chain.owner_user_id)!=auth.user_id do return respond_error(domain.domain_error(.Not_Found,"task chain not found"),req.request_id)
    out:=Owner_Migration_Preflight{chain_id=chain_id,state="none",work_revision=chain.work_revision}
    if f,found,ferr:=h.chains.legacy_source_get(h.chains.ctx,auth.user_id,chain_id);ferr.code!=.None {
        return respond_error(ferr,req.request_id)
    } else if found {
        out.state=f.state;out.migration_id=f.selection.migration_id;out.owner_bridge_id=f.selection.owner_bridge_id
    }
    blockers,berr:=h.chains.legacy_migration_blockers(h.chains.ctx,chain_id)
    if berr.code!=.None do return respond_error(berr,req.request_id)
    out.blockers=blockers
    return respond_success(owner_json(out),req.request_id,auth_ctx_server_time(req))
}

// Verified device (selection signer) and owner Bridge from the current
// enrolled directory, never from request fields.
owner_migration_keys :: proc(h:^Bridge_Handlers,account:string,selection:json.Object)->(device,owner:contracts.Owner_Verified_Key,directory:vault.Directory_Verification_Input,ok:bool) {
    d,available:=owner_directory(h,account)
    if !available do return
    dir,verified:=vault.directory_verify(d)
    if !verified do return
    signer,trusted:=dir.trusted[contracts.owner_string(selection,"key_id")]
    bridge,enrolled:=dir.trusted[contracts.owner_string(selection,"owner_key_id")]
    if !trusted || !enrolled || bridge.kind!="bridge" do return
    snapshot,serr:=vd.get_directory(h.vault,account)
    bound:=false
    for dev in snapshot.devices { if dev.bridge_id==contracts.owner_string(selection,"owner_bridge_id") && dev.device_id==bridge.id && dev.sign_public_key==bridge.sign_public_key && dev.status==.Approved do bound=true }
    if serr.code!=.None || !bound do return
    device=contracts.Owner_Verified_Key{account,signer.id,signer.id,signer.sign_public_key,"device",signer.kind=="browser",false}
    owner=contracts.Owner_Verified_Key{account,contracts.owner_string(selection,"owner_bridge_id"),bridge.id,bridge.sign_public_key,"bridge",true,false}
    return device,owner,d,true
}

owner_migration_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    return owner_migration_post((^Bridge_Handlers)(ctx),req,owner_migration_default_env())
}
owner_migration_post :: proc(h:^Bridge_Handlers,req:Request,env:Owner_Migration_Env)->Response {
    // The device signatures carry consent; an instance token only transports
    // a browser-signed request (ham-ctl), exactly like the owner relay.
    auth,ok,resp:=require_auth_any(h.auth,req)
    if !ok do return resp
    if !contracts.is_user_auth(auth) && auth.kind!=.Instance_Token do return respond_error(domain.domain_error(.Forbidden,"user authentication required"),req.request_id)
    body:Owner_Migration_Request
    if json.unmarshal_string(req.body,&body,.JSON,context.temp_allocator)!=nil do return respond_error(domain.domain_error(.Validation_Failed,"invalid migration request"),req.request_id)
    selection,sel_ok:=contracts.owner_parse(body.selection,"migration_selection")
    genesis,gen_ok:=contracts.owner_parse(body.genesis,"genesis")
    if !sel_ok || !gen_ok do return respond_error(domain.domain_error(.Validation_Failed,"invalid signed migration selection or genesis"),req.request_id)
    get:=contracts.owner_string
    account,chain_id,migration,bridge_id:=get(selection,"account_id"),get(selection,"chain_id"),get(selection,"migration_id"),get(selection,"owner_bridge_id")
    if account!=auth.user_id do return respond_error(domain.domain_error(.Forbidden,"selection account mismatch"),req.request_id)
    device,owner,directory,keys_ok:=env.keys(h,account,selection)
    if !keys_ok do return respond_error(domain.domain_error(.Forbidden,"selection signer or owner Bridge is not currently enrolled"),req.request_id)
    if e:=contracts.owner_verify_migration_selection(selection,account,chain_id,device,owner);e!=.None do return respond_error(domain.domain_error(.Forbidden,fmt.tprintf("migration selection rejected: %s",contracts.owner_auth_error_code(e))),req.request_id)
    // The device also signs the destination genesis: creation_op is the migration.
    if get(genesis,"account_id")!=account || get(genesis,"chain_id")!=chain_id || get(genesis,"creation_op")!=migration || get(genesis,"owner_bridge_id")!=bridge_id ||
       get(genesis,"owner_key_id")!=owner.key_id || get(genesis,"creator_id")!=device.principal_id || get(genesis,"creator_key_id")!=device.key_id ||
       !contracts.owner_verify_signature("genesis",genesis,"creator_signature",device) {
        return respond_error(domain.domain_error(.Forbidden,"migration genesis is not bound to this selection"),req.request_id)
    }
    chain,exists,cerr:=h.chains.get_chain(h.chains.ctx,domain.Task_Chain_ID(chain_id))
    if cerr.code!=.None do return respond_error(cerr,req.request_id)
    if !exists || string(chain.owner_user_id)!=account do return respond_error(domain.domain_error(.Not_Found,"task chain not found"),req.request_id)
    if owned,berr:=env.bridge_owned(h,auth,bridge_id);!owned do return respond_error(berr,req.request_id)
    selection_digest,_:=contracts.owner_digest("migration_selection",selection)
    expected,_:=strconv.parse_i64(get(selection,"expected_work_revision"))
    s:=domain.Legacy_Migration_Selection{account,chain_id,migration,bridge_id,owner.key_id,selection_digest,expected}
    // Freshness and CAS gate only a new selection; an exact retry continues
    // the same frozen migration after the request expiry.
    _,selected,serr:=h.chains.legacy_source_get(h.chains.ctx,account,chain_id)
    if serr.code!=.None do return respond_error(serr,req.request_id)
    if !selected {
        now:=time.to_unix_nanoseconds(time.now())/1000000
        if e:=contracts.owner_migration_admit("migration_selection",selection,now,chain.work_revision);e!=.None do return respond_error(domain.domain_error(.Conflict,fmt.tprintf("migration selection not admitted: %s",contracts.owner_auth_error_code(e))),req.request_id)
    }
    fence,blockers,ferr:=h.chains.legacy_migration_freeze_now(h.chains.ctx,s)
    if ferr.code!=.None do return respond_error(ferr,req.request_id)
    if len(blockers)>0 do return owner_migration_blocked(blockers,req.request_id)
    export,eerr:=owner_migration_export_cached(h,account,chain_id,migration)
    if eerr.code!=.None do return respond_error(eerr,req.request_id)
    result:=Owner_Migration_Result{state=fence.state,migration_id=migration,chain_id=chain_id,manifest_digest=export.manifest_digest}
    if fence.state=="imported" {
        // Exact retry after cutover: nudge activation again; the Bridge also
        // re-derives it from Hub state on its own.
        result.receipt_digest=fence.receipt_digest;result.replayed=true
        result.activation_sent=env.nudge(h,account,bridge_id,migration,chain_id,export.manifest_digest)
        return respond_success(owner_json(result),req.request_id,auth_ctx_server_time(req))
    }
    if !env.bridge_live(h,bridge_id) {
        return respond_error(domain.domain_error(.Bridge_Offline,"owner Bridge is offline; the chain stays frozen until the import is retried",`{"code":"owner_unavailable","state":"frozen"}`),req.request_id)
    }
    id:=fmt.tprintf("cmd_owner_migration_%d",time.to_unix_nanoseconds(time.now()))
    command:=Owner_Migration_Import_Command{"owner_migration_import",id,account,migration,chain_id,body.selection,body.genesis,export.manifest_digest,directory}
    reply_text,received,rerr:=env.relay(h,bridge_id,id,owner_json(command))
    if !received do return respond_error(rerr,req.request_id)
    reply:Owner_Migration_Import_Reply
    if json.unmarshal_string(reply_text,&reply,.JSON,context.temp_allocator)!=nil do return respond_error(domain.domain_error(.Internal_Error,"invalid owner import reply"),req.request_id)
    if reply.code!="ok" do return respond_error(domain.domain_error(.Conflict,fmt.tprintf("owner import failed: %s",reply.code),owner_json(struct{code,state:string}{reply.code,"frozen"})),req.request_id)
    receipt_digest,cut,cut_err:=owner_migration_cutover(h,account,chain_id,migration,export.manifest_digest,selection,genesis,reply,owner)
    if cut_err.code!=.None do return respond_error(cut_err,req.request_id)
    result.state="imported";result.receipt_digest=receipt_digest;result.replayed=cut
    result.activation_sent=env.nudge(h,account,bridge_id,migration,chain_id,export.manifest_digest)
    return respond_success(owner_json(result),req.request_id,auth_ctx_server_time(req))
}

// Verifies the owner-signed receipt and owner-signed genesis, then commits the
// Hub cutover (route + imported) in one transaction.
owner_migration_cutover :: proc(h:^Bridge_Handlers,account,chain_id,migration,manifest_digest:string,selection,submitted_genesis:json.Object,reply:Owner_Migration_Import_Reply,owner:contracts.Owner_Verified_Key)->(string,bool,domain.Domain_Error) {
    receipt,r_ok:=contracts.owner_parse(reply.receipt,"migration_import_receipt")
    genesis,g_ok:=contracts.owner_parse(reply.genesis,"genesis")
    if !r_ok || !g_ok do return "",false,domain.domain_error(.Conflict,"owner import receipt is malformed")
    // The returned genesis must be the submitted one plus the owner signature.
    for name in ([10]string{"protocol_version","account_id","chain_id","creation_op","owner_bridge_id","owner_key_id","creator_id","creator_key_id","schema_version","creator_signature"}) {
        if contracts.owner_string(genesis,name)!=contracts.owner_string(submitted_genesis,name) do return "",false,domain.domain_error(.Conflict,"owner genesis differs from the signed selection genesis")
    }
    if e:=contracts.owner_verify_migration_import(receipt,selection,genesis,manifest_digest,owner);e!=.None do return "",false,domain.domain_error(.Conflict,fmt.tprintf("owner import receipt rejected: %s",contracts.owner_auth_error_code(e)))
    genesis_digest,_:=contracts.owner_digest("genesis",genesis)
    route:=domain.Owner_Registry_Record{account_id=account,chain_id=chain_id,owner_bridge_id=owner.principal_id,owner_key_id=owner.key_id,creator_id=contracts.owner_string(genesis,"creator_id"),genesis_digest=genesis_digest,genesis_json=reply.genesis}
    receipt_digest:=contracts.owner_payload_digest(reply.receipt)
    replayed,err:=h.chains.legacy_migration_cutover(h.chains.ctx,account,chain_id,migration,manifest_digest,receipt_digest,route)
    return receipt_digest,replayed,err
}

owner_migration_activate_nudge :: proc(h:^Bridge_Handlers,account,bridge_id,migration,chain_id,manifest_digest:string)->bool {
    id:=fmt.tprintf("cmd_owner_migration_activate_%d",time.to_unix_nanoseconds(time.now()))
    sent,_:=bridge_runtime.send_runtime_command(h.bridge_runtime_registry,project_service.Runtime_Command{bridge_id=bridge_id,command_id=id,
        body_json=owner_json(Owner_Migration_Activate_Command{"owner_migration_activate",id,account,migration,chain_id,manifest_digest})})
    return sent
}

// The owner Bridge fetches the frozen export one document at a time.
owner_migration_export_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_or_bridge_token(h.auth,req)
    if !ok do return resp
    if auth.kind!=.Bridge_Token do return respond_error(domain.domain_error(.Forbidden,"owner Bridge authentication required"),req.request_id)
    migration:=query_value(req.query,"migration_id")
    f,found,err:=h.chains.legacy_migration_get(h.chains.ctx,auth.user_id,migration)
    if err.code!=.None do return respond_error(err,req.request_id)
    if !found || f.selection.owner_bridge_id!=auth.bridge_id do return respond_error(domain.domain_error(.Forbidden,"selected owner Bridge required"),req.request_id)
    export,eerr:=owner_migration_export_cached(h,auth.user_id,f.selection.chain_id,migration)
    if eerr.code!=.None do return respond_error(eerr,req.request_id)
    part:=query_value(req.query,"part")
    out:=Owner_Migration_Part{migration,export.manifest_digest,part,""}
    if part=="manifest" {
        out.body=export.manifest
    } else {
        index,valid:=strconv.parse_int(part)
        if !valid || index<0 || index>=len(export.documents) do return respond_error(domain.domain_error(.Validation_Failed,"unknown export part"),req.request_id)
        out.body=export.documents[index]
    }
    return respond_success(owner_json(out),req.request_id,auth_ctx_server_time(req))
}

owner_migration_state_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_or_bridge_token(h.auth,req)
    if !ok do return resp
    if auth.kind!=.Bridge_Token do return respond_error(domain.domain_error(.Forbidden,"owner Bridge authentication required"),req.request_id)
    migration:=query_value(req.query,"migration_id")
    f,found,err:=h.chains.legacy_migration_get(h.chains.ctx,auth.user_id,migration)
    if err.code!=.None do return respond_error(err,req.request_id)
    if !found {
        // Only an explicit abort record says "aborted"; an unknown migration
        // stays 404, which the owner treats as retryable, never as abort.
        chain,owner_bridge,aborted,aerr:=h.chains.legacy_migration_aborted(h.chains.ctx,auth.user_id,migration)
        if aerr.code!=.None do return respond_error(aerr,req.request_id)
        if aborted && owner_bridge==auth.bridge_id do return respond_success(owner_json(Owner_Migration_State{migration,chain,"aborted","",owner_bridge}),req.request_id,auth_ctx_server_time(req))
        return respond_error(domain.domain_error(.Not_Found,"migration not found"),req.request_id)
    }
    if f.selection.owner_bridge_id!=auth.bridge_id do return respond_error(domain.domain_error(.Not_Found,"migration not found"),req.request_id)
    return respond_success(owner_json(Owner_Migration_State{migration,f.selection.chain_id,f.state,f.manifest_digest,f.selection.owner_bridge_id}),req.request_id,auth_ctx_server_time(req))
}

// Frozen rows are immutable, so one export serves every part request of a
// migration. A small heap cache keyed by migration id; abort evicts it.
Owner_Migration_Cached_Export :: struct { account,migration,manifest,manifest_digest:string, documents:[]string }
owner_migration_export_cache:[2]Owner_Migration_Cached_Export
owner_migration_export_cache_next:int
owner_migration_export_cache_mutex:sync.Mutex

owner_migration_cache_free :: proc(e:^Owner_Migration_Cached_Export) {
    a:=runtime.default_allocator()
    delete(e.account,a);delete(e.migration,a);delete(e.manifest,a);delete(e.manifest_digest,a)
    for d in e.documents do delete(d,a)
    delete(e.documents,a)
    e^={}
}
owner_migration_export_evict :: proc(account,migration:string) {
    sync.mutex_lock(&owner_migration_export_cache_mutex);defer sync.mutex_unlock(&owner_migration_export_cache_mutex)
    for &e in owner_migration_export_cache do if e.account==account && e.migration==migration do owner_migration_cache_free(&e)
}
// Callers have already authorized the account and checked the fence state.
owner_migration_export_cached :: proc(h:^Bridge_Handlers,account,chain,migration:string)->(domain.Legacy_Migration_Export,domain.Domain_Error) {
    sync.mutex_lock(&owner_migration_export_cache_mutex)
    for e in owner_migration_export_cache {
        if e.migration!="" && e.account==account && e.migration==migration {
            docs:=make([]string,len(e.documents),context.temp_allocator)
            for d,i in e.documents do docs[i]=strings.clone(d,context.temp_allocator)
            out:=domain.Legacy_Migration_Export{strings.clone(e.manifest,context.temp_allocator),strings.clone(e.manifest_digest,context.temp_allocator),docs}
            sync.mutex_unlock(&owner_migration_export_cache_mutex)
            return out,{}
        }
    }
    sync.mutex_unlock(&owner_migration_export_cache_mutex)
    export,err:=h.chains.legacy_migration_export(h.chains.ctx,account,chain,migration)
    if err.code!=.None do return export,err
    a:=runtime.default_allocator()
    entry:=Owner_Migration_Cached_Export{strings.clone(account,a),strings.clone(migration,a),strings.clone(export.manifest,a),strings.clone(export.manifest_digest,a),make([]string,len(export.documents),a)}
    for d,i in export.documents do entry.documents[i]=strings.clone(d,a)
    sync.mutex_lock(&owner_migration_export_cache_mutex);defer sync.mutex_unlock(&owner_migration_export_cache_mutex)
    slot:=&owner_migration_export_cache[owner_migration_export_cache_next]
    owner_migration_export_cache_next=(owner_migration_export_cache_next+1)%len(owner_migration_export_cache)
    owner_migration_cache_free(slot)
    slot^=entry
    return export,{}
}

// Abort returns a frozen chain to the legacy writer and abandons any owner-side
// import: a human decision. Agent instance tokens (any agent of the account)
// are refused; only the user's own authenticated session may abort.
owner_migration_abort_authorized :: proc(auth:contracts.Auth_Context)->bool {
    return contracts.is_user_auth(auth) && auth.kind!=.Instance_Token
}
// POST /api/v1/owner-local/migrations/abort {chain_id,migration_id}: the
// account owner returns a selected or frozen chain to its legacy writer. A
// quarantined owner-side import of it is never activated: the Hub never
// reports it imported again.
owner_migration_abort_handler :: proc(ctx:rawptr,req:Request)->Response {
    context.allocator=context.temp_allocator
    h:=(^Bridge_Handlers)(ctx)
    auth,ok,resp:=require_auth_any(h.auth,req)
    if !ok do return resp
    if !owner_migration_abort_authorized(auth) do return respond_error(domain.domain_error(.Forbidden,"aborting a migration needs the account owner's browser session; agent tokens cannot abort"),req.request_id)
    body:Owner_Migration_Abort_Request
    if json.unmarshal_string(req.body,&body,.JSON,context.temp_allocator)!=nil || body.chain_id=="" || body.migration_id=="" do return respond_error(domain.domain_error(.Validation_Failed,"chain_id and migration_id are required"),req.request_id)
    chain,exists,cerr:=h.chains.get_chain(h.chains.ctx,domain.Task_Chain_ID(body.chain_id))
    if cerr.code!=.None do return respond_error(cerr,req.request_id)
    if !exists || string(chain.owner_user_id)!=auth.user_id do return respond_error(domain.domain_error(.Not_Found,"task chain not found"),req.request_id)
    fence,selected,_:=h.chains.legacy_source_get(h.chains.ctx,auth.user_id,body.chain_id)
    replayed,err:=h.chains.legacy_migration_abort(h.chains.ctx,auth.user_id,body.chain_id,body.migration_id)
    if err.code!=.None do return respond_error(err,req.request_id)
    owner_migration_export_evict(auth.user_id,body.migration_id)
    // Lets the owner abandon a quarantined import now; it also does so on its
    // own reconcile, since the Hub no longer reports this migration.
    if selected && fence.selection.migration_id==body.migration_id && h.bridge_runtime_registry!=nil do _=owner_migration_activate_nudge(h,auth.user_id,fence.selection.owner_bridge_id,body.migration_id,body.chain_id,"")
    return respond_success(owner_json(struct{state,migration_id,chain_id:string,replayed:bool}{"aborted",body.migration_id,body.chain_id,replayed}),req.request_id,auth_ctx_server_time(req))
}
