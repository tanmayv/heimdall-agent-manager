#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:encoding/json"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// Owner-Bridge consent (option b): with no operator mapping, this executor
// installs its first policy and a per-chain scratch directory with its own
// key, and returns the selectors it chose.
@(test)
test_executor_auto_issuance_resolves_without_operator_mapping :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    sync.mutex_lock(&keystore_test_mutex);defer sync.mutex_unlock(&keystore_test_mutex)
    id,_:=keystore_test_bridge_ids()
    prior_id:=keystore_test_set_daemon_id(id);defer {bridge_cfg().daemon_id=prior_id}
    keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()
    unseal_nonce_cache_clear(&g_unseal_nonce_cache);bridge_unseal_init()
    if !testing.expect(t,test_provision_identity(id)) do return
    defer {keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()}
    kr:=test_keyring_from_hex(TEST_VAULT_KEY_HEX);defer vault.keyring_wipe(&kr)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    payload:=test_create_unseal_v2_payload(id,&kr,now,"issuance_auto_pair")
    unsealed,_:=bridge_unseal_decrypt_and_verify(payload,id,now)
    if !testing.expect(t,unsealed) do return
    public:=bridge_identity_public_key_hex(id);key_id,_:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    self:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,id,key_id,public,"bridge",true,false}
    if !testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id)) do return
    executor_root,_:=bridge_executor_root(TEST_VAULT_USER_ID)
    defer {executor.close(&bridge_executor_store);_=os.remove_all(executor_root)}
    // As in production (file root $HOME): the executor's private root is
    // inside the Bridge's file root.
    prior_root:=bridge_fs_root;root:=bridge_fs_canonicalize_existing(executor_root);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=prior_root}
    s:=&bridge_executor_store
    auto:=contracts.EXECUTOR_AUTO_SELECTOR
    requested:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","seed",auto,auto,"1",auto})
    consent:=make(json.Object);consent["chain_id"]=json.String("chain_auto")
    resources:=bridge_executor_resolve_auto_issuance(s,consent,requested,self)
    if !testing.expect(t,resources.resolved,"resolved with no operator policy or directory") do return
    chosen,chosen_ok:=contracts.executor_parse(resources.selection,"issuance_selection")
    if !testing.expect(t,chosen_ok) do return
    get:=contracts.owner_string
    testing.expect(t,get(chosen,"provider")=="claude" && get(chosen,"model")=="seed" && get(chosen,"provider_profile")=="claude")
    testing.expect_value(t,get(chosen,"policy_revision"),"1")
    testing.expect_value(t,get(chosen,"slot_id"),"auto_claude")
    testing.expect(t,strings.has_prefix(get(chosen,"directory_id"),"scratch_"))
    testing.expect(t,strings.has_prefix(resources.directory_path,fmt.tprintf("%s/scratch/",executor_root)),"scratch lives in the executor's private root")
    testing.expect(t,os.is_dir(resources.directory_path))
    testing.expect_value(t,resources.selection_digest,contracts.owner_payload_digest(requested))
    // Idempotent per chain: same directory, no new mapping or policy revision.
    again:=bridge_executor_resolve_auto_issuance(s,consent,requested,self)
    testing.expect(t,again.resolved && again.directory_path==resources.directory_path && again.selection==resources.selection)
    revision,_:=executor.directory_latest_revision(s,get(chosen,"directory_id"))
    testing.expect_value(t,revision,i64(1))
    // Another chain gets its own scratch directory.
    other:=make(json.Object);other["chain_id"]=json.String("chain_other")
    separate:=bridge_executor_resolve_auto_issuance(s,other,requested,self)
    testing.expect(t,separate.resolved && separate.directory_path!=resources.directory_path)
    // task_18e70e69aca835a7: a model this Bridge never observed (its claude
    // reports aliases only) but the account catalog lists as active is placed;
    // an inactive or unknown one is still refused.
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-old",state="retired"}}}}
    defer bridge_provider_catalog_default_hook=nil
    catalog_only:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","claude-sonnet-5-5",auto,auto,"1",auto})
    placed:=bridge_executor_resolve_auto_issuance(s,consent,catalog_only,self)
    testing.expect(t,placed.resolved,"an active catalog model the Bridge has not observed is placed")
    // No directory on the chain: it runs in this executor's default (per-chain
    // scratch) path, and the remote child's TASK.md names it as the Workdir.
    testing.expect(t,strings.has_prefix(placed.directory_path,fmt.tprintf("%s/scratch/",executor_root)),"placed in the per-chain scratch dir")
    testing.expect_value(t,placed.directory_path,resources.directory_path)
    testing.expect_value(t,bridge_executor_scratch_workdir(TEST_VAULT_USER_ID,"chain_auto"),placed.directory_path)
    testing.expect_value(t,bridge_executor_scratch_workdir(TEST_VAULT_USER_ID,"chain_never_placed"),"")
    {
        cmd:=json.Object{"chain_id"=json.String("chain_auto"),"task_id"=json.String("task_remote"),"lease_id"=json.String("lease_remote"),"instance_id"=json.String("inst_remote"),"workdir"=json.String(placed.directory_path),"branch"=json.String("")}
        body:=executor.encode(struct{requirements_revision,acknowledged,brief,chain_summary,context_provenance:string}{"1","0",`{"goal":"g","acceptance":["a"]}`,"s",`{"source_digest":"d"}`})
        md:=bridge_owner_render_context(cmd,body)
        testing.expectf(t,strings.contains(md,fmt.tprintf("Workdir: `%s` (this chain has no project directory",placed.directory_path)),"remote TASK.md names the scratch Workdir: %s",md)
    }
    for bad in ([2]string{"claude-old","claude-nope"}) {
        refused:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude",bad,auto,auto,"1",auto})
        testing.expectf(t,!bridge_executor_resolve_auto_issuance(s,consent,refused,self).resolved,"%s is refused",bad)
    }
    // Git tickets (user 15:30Z): the Hub's hint names this Bridge's checkout
    // of the chain's project, so the work runs there.
    checkout:=fmt.tprintf("%s/checkout",root)
    if !testing.expect(t,os.make_directory(checkout)==nil) do return
    hinted:=bridge_executor_resolve_auto_issuance(s,consent,requested,self,checkout)
    if !testing.expect(t,hinted.resolved,"a valid project hint resolves") do return
    testing.expect_value(t,hinted.directory_path,checkout)
    hinted_selection,_:=contracts.executor_parse(hinted.selection,"issuance_selection")
    testing.expect(t,strings.has_prefix(get(hinted_selection,"directory_id"),"project_"),"the checkout is mapped as a project directory")
    hinted_mapping,hinted_mapped:=executor.directory_mapping(s,get(hinted_selection,"directory_id"))
    testing.expect(t,hinted_mapped && hinted_mapping.path==checkout,"self-mapped with the executor's own key")
    // A missing, outside-root or non-directory hint falls back to the
    // chain's scratch directory: never a refusal.
    for bad in ([3]string{fmt.tprintf("%s/missing",root),"/",fmt.tprintf("%s/runtime.sqlite",executor_root)}) {
        fallback:=bridge_executor_resolve_auto_issuance(s,consent,requested,self,bad)
        testing.expectf(t,fallback.resolved && fallback.directory_path==resources.directory_path,"hint %s falls back to scratch",bad)
    }
    // Refusals: an explicit selection, an unknown model, another key.
    explicit:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","seed","claude","dir","1","slot1"})
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,explicit,self).resolved,"explicit selections use the operator resolver")
    unknown:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","not-in-catalog",auto,auto,"1",auto})
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,unknown,self).resolved,"an unknown model is refused")
    stranger:=self;stranger.key_id="other_key"
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,requested,stranger).resolved,"only this executor's own key provisions")
}

// F5 (REQ-EXEC-NEVER-BLOCK, local REQ-E2E-1 B): Bridge B observed no models
// at all and its file root ($HOME before HOME was isolated) did not contain
// its executor root, so the scratch directory failed the fs_root check and
// every placement was a silent invalid_resources. The Bridge's own scratch is
// not a user path: it resolves whatever fs_root is. An operator policy
// without a slot for the profile gains the auto slot (a new revision that
// keeps its slots), and each refusal names its component.
@(test)
test_executor_auto_issuance_never_blocks_on_unobserved_model_root_or_slot :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    sync.mutex_lock(&keystore_test_mutex);defer sync.mutex_unlock(&keystore_test_mutex)
    id,_:=keystore_test_bridge_ids()
    prior_id:=keystore_test_set_daemon_id(id);defer {bridge_cfg().daemon_id=prior_id}
    keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()
    unseal_nonce_cache_clear(&g_unseal_nonce_cache);bridge_unseal_init()
    if !testing.expect(t,test_provision_identity(id)) do return
    defer {keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()}
    kr:=test_keyring_from_hex(TEST_VAULT_KEY_HEX);defer vault.keyring_wipe(&kr)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    payload:=test_create_unseal_v2_payload(id,&kr,now,"issuance_never_block_pair")
    unsealed,_:=bridge_unseal_decrypt_and_verify(payload,id,now)
    if !testing.expect(t,unsealed) do return
    public:=bridge_identity_public_key_hex(id);key_id,_:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    self:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,id,key_id,public,"bridge",true,false}
    if !testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id)) do return
    executor_root,_:=bridge_executor_root(TEST_VAULT_USER_ID)
    defer {executor.close(&bridge_executor_store);_=os.remove_all(executor_root)}
    // The file root is a projects dir that does not contain the executor root.
    projects:=fmt.tprintf("%s/projects",st.dir)
    if !testing.expect(t,os.make_directory(projects)==nil) do return
    prior_root:=bridge_fs_root;root:=bridge_fs_canonicalize_existing(projects);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=prior_root}
    s:=&bridge_executor_store
    // An operator policy (revision 1) whose only slot serves another profile.
    operator:=executor.encode(struct{protocol_version,account_id,executor_bridge_id,policy_revision,device_capacity,slots_json,key_id,signature:string}{
        "1",s.account,s.executor,"1","2",executor.encode([1]Bridge_Executor_Slot{{"operator_slot","other_profile","1"}}),s.operator_key,strings.repeat("0",128)})
    signed,code:=bridge_executor_operator_sign_record("policy",operator)
    if !testing.expect_value(t,code,"ok") do return
    if !testing.expect_value(t,executor.install_policy(s,signed,self,bridge_executor_physical_clock(nil)).code,"ok") do return
    // Nothing observed: the active catalog model is the only source.
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"}}}}
    defer bridge_provider_catalog_default_hook=nil
    testing.expect(t,!bridge_provider_catalog_has_model("claude","claude-sonnet-5-5"),"the Bridge observed no claude-sonnet-5-5")
    auto:=contracts.EXECUTOR_AUTO_SELECTOR
    requested:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","claude-sonnet-5-5",auto,auto,"1",auto})
    consent:=make(json.Object);consent["chain_id"]=json.String("chain_no_directory")
    why:=""
    placed:=bridge_executor_resolve_auto_issuance(s,consent,requested,self,"",&why)
    if !testing.expectf(t,placed.resolved,"placed with no observed model, no directory and scratch outside fs_root (refused: %s)",why) do return
    testing.expect(t,strings.has_prefix(placed.directory_path,fmt.tprintf("%s/scratch/",executor_root)),"runs in the per-chain scratch dir")
    chosen,_:=contracts.executor_parse(placed.selection,"issuance_selection")
    get:=contracts.owner_string
    testing.expect_value(t,get(chosen,"slot_id"),"auto_claude")
    testing.expect_value(t,get(chosen,"policy_revision"),"2")
    kept,_,_:=executor.auto_slot(s,"other_profile")
    testing.expect_value(t,kept,i64(2))
    _,operator_slot,operator_kept:=executor.auto_slot(s,"other_profile")
    testing.expect(t,operator_kept && operator_slot=="operator_slot","the operator's slot is kept")
    // The issued selection re-resolves at prepare (scratch outside fs_root).
    prepared:=bridge_executor_resolve_issuance(s,placed.selection,&why)
    testing.expectf(t,prepared.resolved && prepared.directory_path==placed.directory_path,"prepare re-resolves the scratch selection (refused: %s)",why)
    testing.expect_value(t,bridge_executor_scratch_workdir(TEST_VAULT_USER_ID,"chain_no_directory"),placed.directory_path)
    // Refusals name the failing component.
    unknown:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","not-in-catalog",auto,auto,"1",auto})
    why=""
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,unknown,self,"",&why).resolved)
    testing.expectf(t,strings.has_prefix(why,"model: claude/not-in-catalog"),"model refusal: %s",why)
    unmapped:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","claude-sonnet-5-5","claude","dir_unmapped","2","auto_claude"})
    why=""
    testing.expect(t,!bridge_executor_resolve_issuance(s,unmapped,&why).resolved)
    testing.expectf(t,strings.has_prefix(why,"directory: dir_unmapped is not mapped"),"directory refusal: %s",why)
    bad_profile:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","claude-sonnet-5-5","unknown-profile",get(chosen,"directory_id"),"2","auto_claude"})
    why=""
    testing.expect(t,!bridge_executor_resolve_issuance(s,bad_profile,&why).resolved)
    testing.expectf(t,strings.has_prefix(why,"profile: claude/unknown-profile"),"explicit profile refusal: %s",why)
    stranger:=self;stranger.key_id="other_key"
    why=""
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,requested,stranger,"",&why).resolved)
    testing.expectf(t,strings.has_prefix(why,"selection: only this executor's own key"),"selection refusal: %s",why)
    // A directory outside both fs_root and the Bridge's own dirs stays refused.
    _,outside:=bridge_executor_canonical_directory(st.dir)
    testing.expect(t,!outside,"a path outside fs_root and the Bridge's own dirs is refused")
}
