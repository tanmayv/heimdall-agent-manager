#+feature dynamic-literals
package main

import "core:fmt"
import "core:crypto"
import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"
import socket "odin_test:lib/local_socket"
import vault "odin_test:lib/vault"

// Called only by the explicit native CLI. OS-account access to the protected
// keystore is the existing operator boundary, not an agent credential or an
// assertion that a same-account process is human. Never register a signing RPC.
bridge_executor_operator_sign_record :: proc(kind,raw:string)->(string,string) {
    if kind!="policy" && kind!="directory" do return "","malformed"
    o,valid:=contracts.executor_parse(raw,kind)
    if !valid do return "","malformed"
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    key_id,identified:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    get:=contracts.owner_string
    if !identified || account=="" || get(o,"account_id")!=account || get(o,"executor_bridge_id")!=bridge_cfg().daemon_id || get(o,"key_id")!=key_id do return "","invalid_scope"
    if kind=="directory" && get(o,"enabled")=="1" {
        if _,canonical:=bridge_executor_canonical_directory(get(o,"directory_path"));!canonical do return "","invalid_resources"
    }
    identity:Bridge_Identity_Record
    if keystore_read_identity(bridge_cfg().daemon_id,&identity)!=.Found do return "","operator_key_unavailable"
    defer crypto.zero_explicit(&identity,size_of(identity))
    private:ecdsa.Private_Key
    if !ecdsa.private_key_set_bytes(&private,.SECP256R1,identity.scalar[:]) do return "","operator_key_unavailable"
    defer ecdsa.private_key_clear(&private)
    canonical,ready:=contracts.executor_canonical(kind,o)
    if !ready do return "","malformed"
    signature,signed:=vault.sign_p256(&private,transmute([]byte)canonical)
    if !signed do return "","signing_failed"
    o["signature"]=json.String(vault.hex_encode_lower(signature.sig[:],context.temp_allocator))
    return executor.encode(o),"ok"
}

// This route has no signer and never treats an agent/Hub token as operator
// authority. Only the pinned Bridge identity's policy/directory signature may
// install or read back configuration. It is absent from Hub relay dispatch.
bridge_executor_operator_handle :: proc(id,method,params:string)->string {
    context.allocator=context.temp_allocator
    request,parsed:=contracts.executor_parse(params,"operator_import")
    if !parsed do return bridge_local_response_error(id,"malformed","signed policy or directory record required")
    kind,raw:=contracts.owner_string(request,"kind"),contracts.owner_string(request,"document")
    if kind!="policy" && kind!="directory" do return bridge_local_response_error(id,"malformed","unsupported operator record")
    generation:=bridge_task_chain_search_generation()
    public:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
    key_id,identified:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    if !identified || account=="" do return bridge_local_response_error(id,"invalid_scope","paired host operator identity required")
    key:=contracts.Owner_Verified_Key{account,bridge_cfg().daemon_id,key_id,public,"bridge",true,false}
    doc,valid:=contracts.executor_parse(raw,kind)
    if !valid || !contracts.executor_verify(kind,doc,key) do return bridge_local_response_error(id,"invalid_scope","pinned host operator signature required")
    sync.mutex_lock(&bridge_executor_mutex);defer sync.mutex_unlock(&bridge_executor_mutex)
    sync.mutex_lock(&bridge_startup_io_mutex);defer sync.mutex_unlock(&bridge_startup_io_mutex)
    if !bridge_executor_authority_begin(generation) do return bridge_local_response_error(id,"vault_locked","unlock the execution device")
    defer bridge_executor_authority_end()
    kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
    if !unlocked || !bridge_executor_open(account,key_id) do return bridge_local_response_error(id,"storage_unavailable","unlocked journal required")
    s:=&bridge_executor_store
    sync.rw_mutex_shared_lock(&bridge_launch_configuration_mutex);defer sync.rw_mutex_shared_unlock(&bridge_launch_configuration_mutex)
    if method=="executor.operator.install" {
        result:=executor.Result{}
        if kind=="policy" {result=executor.install_policy(s,raw,key,bridge_executor_physical_clock(nil))}
        else {result=bridge_executor_install_directory(s,raw,key,bridge_executor_physical_clock(nil))}
        if result.code!="ok" do return bridge_local_response_error(id,result.code,"operator installation rejected")
    } else if method!="executor.operator.inspect" {
        return bridge_local_response_error(id,"forbidden","operator method not allowed")
    }
    result:=executor.operator_read(s,kind,raw,key)
    if result.code!="ok" do return bridge_local_response_error(id,result.code,"configuration unavailable")
    return bridge_local_response_data(id,result.body)
}

// Native local CLI import/readback. The selected Bridge keeps the single live
// journal writer; no restart, separate Store.open, or agent credential is used.
bridge_executor_operator_command :: proc(args:[]string)->bool {
    if len(args)<3 || (args[2]!="identity" && args[2]!="sign" && args[2]!="import" && args[2]!="inspect") {
        fmt.eprintln("usage: ham-bridge executor identity|sign|import|inspect --config FILE [--kind policy|directory --file RECORD --output SIGNED_RECORD]")
        return false
    }
    config_path:=option_value(args,"--config","")
    if config_path=="" || !os.exists(config_path) {fmt.eprintln("explicit existing --config file required");return false}
    cfg:=bridge_config_from_args(args)
    if args[2]=="identity" {
        if !bridge_keystore_set_hub(cfg.daemon_url) do return false
        public:=bridge_identity_public_key_hex(cfg.daemon_id)
        key,identified:=vault.device_id_from_sign_pub(public,context.temp_allocator)
        account:=bridge_enrolled_owner_user_id(cfg.daemon_id)
        if !identified || account=="" {fmt.eprintln("paired operator identity unavailable");return false}
        fmt.println(executor.encode(struct{account_id,executor_bridge_id,key_id,public_key:string}{account,cfg.daemon_id,key,public}))
        return true
    }
    kind:=option_value(args,"--kind","")
    file:=option_value(args,"--file","")
    info,stat_error:=os.stat(file,context.temp_allocator)
    if stat_error!=nil || info.type!=.Regular || info.size>contracts.EXECUTOR_DOCUMENT_MAX {
        fmt.eprintln("bounded regular policy/directory input file required");return false
    }
    bytes,err:=os.read_entire_file(file,context.temp_allocator)
    if err!=nil || len(bytes)>contracts.EXECUTOR_DOCUMENT_MAX || (kind!="policy" && kind!="directory") {
        fmt.eprintln("bounded signed policy/directory --file and explicit --kind required");return false
    }
    if args[2]=="sign" {
        output:=option_value(args,"--output","")
        if output=="" || os.exists(output) {fmt.eprintln("explicit new --output file required; existing files are never overwritten");return false}
        prior:=bridge_cfg()^;bridge_cfg()^=cfg;defer {bridge_cfg()^=prior}
        if !bridge_keystore_set_hub(cfg.daemon_url) {fmt.eprintln("operator keystore scope unavailable");return false}
        bridge_fs_init(cfg.fs_root,cfg.fs_read_page_bytes)
        signed,code:=bridge_executor_operator_sign_record(kind,string(bytes))
        if code!="ok" {fmt.eprintln("operator signing rejected:",code);return false}
        if os.write_entire_file(output,signed,{.Read_User,.Write_User})!=nil {fmt.eprintln("cannot write signed record");return false}
        fmt.println("signed explicit",kind,"record:",output)
        return true
    }
    if option_value(args,"--local-run-dir","")=="" {fmt.eprintln("explicit selected Bridge --local-run-dir required for import/inspect");return false}
    config:=bridge_local_endpoint_config_default(cfg.local_endpoint_run_dir,cfg.local_endpoint_port)
    fd,connected:=socket.dial(config.unix_socket_path)
    if !connected {fmt.eprintln("selected Bridge local socket unavailable; start the configured Bridge first");return false}
    defer socket.close(fd)
    socket.set_recv_timeout(fd,10*time.Second)
    method:="executor.operator.install" if args[2]=="import" else "executor.operator.inspect"
    params:=struct{kind,document:string}{kind,string(bytes)}
    request:=executor.encode(struct{v:int,id,method:string,params:type_of(params)}{1,"operator",method,params})
    line:=strings.concatenate({request,"\n"},context.temp_allocator)
    sent:=0
    for sent<len(line) {
        n:=socket.send(fd,transmute([]byte)line[sent:])
        if n<=0 {fmt.eprintln("operator request failed");return false}
        sent+=n
    }
    response:=make([dynamic]byte,context.temp_allocator)
    buffer:[4096]byte
    for len(response)<2*contracts.EXECUTOR_DOCUMENT_MAX {
        n:=socket.recv(fd,buffer[:])
        if n<=0 {fmt.eprintln("operator response unavailable; retry exact signed record");return false}
        append(&response,..buffer[:n])
        if strings.index_byte(string(response[:]),'\n')>=0 {
            text:=strings.trim_space(string(response[:]))
            fmt.println(text)
            value,parsed:=contracts.owner_content_document(text)
            o,object:=value.(json.Object)
            ok,is_bool:=o["ok"].(json.Boolean)
            return parsed && object && is_bool && bool(ok)
        }
    }
    fmt.eprintln("operator response exceeds bound")
    return false
}
